// AirliveRelayOutput.swift — PROGRAM → OBS, passthrough (no transcode).
//
// The cheap path the operator asked for: instead of decoding + re-encoding the
// program, this FORWARDS the program camera's already-encoded H.264 (ARLV) to the
// OBS plugin.  Zero decode, zero encode — just re-frames the same bytes onto a
// TCP connection.  The plugin receives it exactly like an iPhone stream.
//
// Direction: the OBS plugin is a SERVER (advertises `_airlive._tcp`); this relay
// is the CLIENT — it browses Bonjour for an OBS receiver (TXT role = "obs"),
// connects, and sends.  On a program switch the new camera's formatDescription
// (SPS/PPS, resent each keyframe) flows through and OBS resyncs on the next IDR.
//
// It conforms to VideoOutput so it lives in the model's program-output list like
// NDI, but it consumes the RAW packet taps (`relayFormat`/`relaySample`), not the
// decoded-frame `send(_:)` (which is a no-op here).

import Foundation
import Network
import CoreVideo

final class AirliveRelayOutput: VideoOutput {
    let id = UUID()
    var label: String
    let kind: OutputKind = .obs

    /// "On" state (mirrors NDI's start/stop semantics for the toggle); the actual
    /// TCP connection is established asynchronously in the background.
    private(set) var isLive: Bool = false

    /// Called when the OBS connection becomes ready — the model uses it to ask the
    /// on-air camera for a keyframe so OBS starts decoding fast (instead of waiting
    /// for the next natural keyframe).
    var onReady: (() -> Void)?

    private let queue = DispatchQueue(label: "studio.airlive.bridge.relay", qos: .userInitiated)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var ready = false
    /// Latest SPS/PPS — (re)sent the moment a connection becomes ready so OBS can
    /// start decoding without waiting for us to have caught a keyframe.
    private var lastFormat: Data?

    init(label: String) { self.label = label }

    func start() {
        guard !isLive else { return }
        isLive = true
        queue.async { [weak self] in self?.startBrowsing() }
    }

    func stop() {
        guard isLive else { return }
        isLive = false
        queue.async { [weak self] in
            guard let self else { return }
            self.browser?.cancel(); self.browser = nil
            self.connection?.cancel(); self.connection = nil
            self.ready = false
            self.lastFormat = nil
        }
    }

    // VideoOutput requires this, but the relay is passthrough — decoded frames are
    // not used (we forward the original H.264 via the relay hooks below).
    func send(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {}

    func relayFormat(_ payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastFormat = payload
            self.write(type: .formatDescription, payload: payload, timestampMicros: 0)
        }
    }

    func relaySample(_ payload: Data, timestampMicros: Int64) {
        queue.async { [weak self] in
            self?.write(type: .sample, payload: payload, timestampMicros: timestampMicros)
        }
    }

    // MARK: - Bonjour discovery + connection (queue-confined)

    private func startBrowsing() {
        let params = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: "_airlive._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil else { return }
            // Connect to the first "OBS Airlive Bridge" source (TXT role
            // "obs-bridge") — NOT the direct iPhone source ("obs").
            for result in results {
                if case let .bonjour(txt) = result.metadata, txt["role"] == "obs-bridge" {
                    self.connect(to: result.endpoint)
                    break
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func connect(to endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let conn = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
                print("[Relay \(self.label)] ✅ connected to OBS")
                if let fmt = self.lastFormat { self.write(type: .formatDescription, payload: fmt, timestampMicros: 0) }
                self.onReady?()   // ask the model to request a keyframe → fast OBS sync
            case .failed, .cancelled:
                self.ready = false
                if self.connection === conn { self.connection = nil }   // browser will reconnect
            default:
                break
            }
        }
        connection = conn
        conn.start(queue: queue)
    }

    /// Frame one ARLV packet and send it.  Queue-confined.
    private func write(type: AirlivePacket.PacketType, payload: Data, timestampMicros: Int64) {
        guard ready, let conn = connection else { return }
        let data = AirlivePacket(type: type, timestampMicros: timestampMicros, payload: payload).encode()
        conn.send(content: data, completion: .idempotent)
    }
}
