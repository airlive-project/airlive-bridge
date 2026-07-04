// AirliveRelayOutput.swift — PROGRAM → OBS, passthrough (no transcode).
//
// The cheap path the operator asked for: instead of decoding + re-encoding the
// program, this FORWARDS the program camera's already-encoded H.264 (ARLV) to the
// OBS plugin.  Zero decode, zero encode — just re-frames the same bytes onto a
// TCP connection.  The plugin receives it exactly like an iPhone stream.
//
// Direction: the OBS "Airlive Bridge" source is a SERVER listening on 127.0.0.1:47788.
// OBS and the Bridge run on the SAME Mac, so the link is plain loopback — no Bonjour,
// no LAN, no discovery.  This relay is the CLIENT: it connects straight there (retrying
// until OBS is up) and sends.  On a program switch the new camera's formatDescription
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

    /// True ONLY while actually connected to OBS (not merely "on" / retrying).
    /// Written on main (from the connection state) so the model can read it on main
    /// to gate the force-keyframe — no keyframe is requested when nobody's receiving.
    private(set) var isConnected: Bool = false

    /// Fires on MAIN whenever `isConnected` flips — the model forwards it to
    /// `objectWillChange` so the OBS card's Connected/Waiting status is live.
    var onConnectionChanged: (() -> Void)?
    private func setConnected(_ value: Bool) {   // main thread
        guard isConnected != value else { return }
        isConnected = value
        onConnectionChanged?()
    }

    private let queue = DispatchQueue(label: "studio.airlive.bridge.relay", qos: .userInitiated)
    private var connection: NWConnection?
    private var ready = false

    /// Same-machine loopback target for the OBS "Airlive Bridge" source.  The DEFAULT port MUST
    /// match kBridgeLocalPort in obs-airlive-source/src/airlive-connection.cpp; it's injectable
    /// ONLY so the verification harness can run against a fake listener while the real app is up.
    private static let obsHost = NWEndpoint.Host("127.0.0.1")
    private let obsPort: NWEndpoint.Port

    /// Queue-confined "we should be connected" flag.  Gates the reconnect loop so a retry
    /// scheduled just before stop() becomes a no-op.  `connectGeneration` invalidates a stale
    /// pending retry when a newer connect attempt (or stop) supersedes it.
    private var wantConnection = false
    private var connectGeneration = 0
    /// Consecutive refused attempts — after a burst we back off (1 s → 5 s) so an OBS that's
    /// simply not running doesn't fill the console with a refused-connect line every second.
    private var failedAttempts = 0
    /// Latest SPS/PPS — (re)sent the moment a connection becomes ready so OBS can
    /// start decoding without waiting for us to have caught a keyframe.
    private var lastFormat: Data?

    /// True between a program-source CUT and the new source's first format: drop samples until
    /// the new SPS/PPS arrives, so OBS never gets the new camera's H.264 against the old format
    /// (a ~300 ms decode gap / green-screen artefacts).  Cleared in `relayFormat` (#20).
    private var awaitingFormat = false
    private var awaitToken = 0   // invalidates a stale await-timeout when a newer await/format lands

    init(label: String, port: UInt16 = 47788) {
        self.label = label
        self.obsPort = NWEndpoint.Port(rawValue: port)!
    }

    func start() {
        guard !isLive else { return }
        isLive = true
        queue.async { [weak self] in
            guard let self else { return }
            self.wantConnection = true
            self.connect()
        }
    }

    func stop() {
        guard isLive else { return }
        isLive = false
        setConnected(false)   // main thread (called from removeProgramOutput)
        queue.async { [weak self] in
            guard let self else { return }
            self.wantConnection = false
            self.connectGeneration &+= 1   // invalidate any pending reconnect
            self.connection?.cancel(); self.connection = nil
            self.ready = false
            self.lastFormat = nil
            self.awaitingFormat = false   // don't inherit a stale CUT gate across a stop/start
        }
    }

    // VideoOutput requires this, but the relay is passthrough — decoded frames are
    // not used (we forward the original H.264 via the relay hooks below).
    func send(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {}

    func relayFormat(_ payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastFormat = payload
            self.awaitingFormat = false   // new source's format is here — samples may flow (#20)
            self.write(type: .formatDescription, payload: payload, timestampMicros: 0)
        }
    }

    func relaySample(_ payload: Data, timestampMicros: Int64) {
        queue.async { [weak self] in
            guard let self, !self.awaitingFormat else { return }   // drop samples until the new format (#20)
            self.write(type: .sample, payload: payload, timestampMicros: timestampMicros)
        }
    }

    /// Forget the cached SPS/PPS so a future OBS (re)connect does NOT replay a stale format
    /// header.  Called when the program switches to a source that emits no raw H.264 (AirPlay /
    /// combined): otherwise OBS would get the previous camera's format + zero samples and stall.
    func clearLastFormat() {
        queue.async { [weak self] in self?.lastFormat = nil }
    }

    /// Gate samples until the next format arrives — called on a program-source CUT so the new
    /// camera's H.264 isn't decoded against the previous camera's SPS/PPS (#20).  Armed with a 1.5 s
    /// SAFETY TIMEOUT: if the new format never arrives (a forceKeyframe swallowed by the camera's
    /// 0.25 s rate-limit, or a dropped packet), samples resume anyway rather than leaving OBS frozen
    /// until the next long-GOP keyframe.  A brief decode against the old SPS/PPS self-heals on the
    /// next keyframe.  `relayFormat` clears the flag first when the format does arrive.
    func awaitFormat() {
        queue.async { [weak self] in
            guard let self else { return }
            self.awaitingFormat = true
            self.awaitToken &+= 1
            let token = self.awaitToken
            self.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.awaitToken == token, self.awaitingFormat else { return }
                self.awaitingFormat = false
            }
        }
    }

    // MARK: - Loopback connection (queue-confined)

    private func connect() {
        guard wantConnection, connection == nil else { return }
        connectGeneration &+= 1
        let gen = connectGeneration
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let conn = NWConnection(host: Self.obsHost, port: self.obsPort,
                                using: NWParameters(tls: nil, tcp: tcp))
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
                self.failedAttempts = 0   // fresh backoff for the next outage
                print("[Relay \(self.label)] ✅ connected to OBS (127.0.0.1:\(self.obsPort.rawValue))")
                self.drainForEOF(conn)   // detect OBS quitting even when no samples are flowing
                if let fmt = self.lastFormat { self.write(type: .formatDescription, payload: fmt, timestampMicros: 0) }
                // Publish "connected" on main BEFORE asking for the keyframe, so the
                // model's gate (reads isConnected on main) sees true.
                DispatchQueue.main.async { self.setConnected(true); self.onReady?() }
            case .waiting:
                // Loopback "connection refused" (OBS not up / source not added) lands HERE — not in
                // .failed — and a .waiting connection retries only on a network-path change, which a
                // loopback listener appearing does NOT generate.  Left alone it hangs in .waiting
                // FOREVER ("works every other time": only an OBS already listening at start() ever
                // connected).  Treat it as a failure: cancel → .cancelled → normal 1 s reconnect.
                conn.cancel()
            case .failed, .cancelled:
                self.ready = false
                DispatchQueue.main.async { self.setConnected(false) }
                if case .failed = state { conn.cancel() }   // .failed does NOT release the fd — leaks a CLOSED socket per retry
                if self.connection === conn { self.connection = nil }
                self.scheduleReconnect(afterGeneration: gen)
            default:
                break
            }
        }
        connection = conn
        conn.start(queue: queue)
    }

    /// The OBS source is a loopback server that may not be up yet (OBS not launched, or the
    /// "Airlive Bridge" source not added) — and can drop when OBS quits.  Retry until it accepts
    /// us: 1 s while the outage is fresh (snappy reconnect after an OBS relaunch), backing off to
    /// 5 s after ~10 refusals so a long-idle OBS doesn't spam a refused-connect log every second.
    /// Gated by `wantConnection` + generation so `stop()` (which bumps the generation) cancels the
    /// loop and a superseded retry never fires.
    private func scheduleReconnect(afterGeneration gen: Int) {
        guard wantConnection else { return }
        failedAttempts += 1
        let delay: TimeInterval = failedAttempts <= 10 ? 1.0 : 5.0
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantConnection,
                  self.connectGeneration == gen, self.connection == nil else { return }
            self.connect()
        }
    }

    /// Keep a pending read on the socket so a peer close is detected IMMEDIATELY.  Without it a
    /// FIN from OBS (quit / source removed) never transitions the send-only NWConnection out of
    /// `.ready` — the relay sits "connected" on a corpse until the next write bounces off the RST.
    /// The plugin sends the bridge peer nothing, so any bytes are drained and ignored.
    private func drainForEOF(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak conn] _, _, isDone, error in
            guard let self, let conn, self.connection === conn else { return }
            if isDone || error != nil {
                conn.cancel()   // → .cancelled → setConnected(false) + scheduleReconnect
                return
            }
            self.drainForEOF(conn)
        }
    }

    /// Frame one ARLV packet and send it.  Queue-confined.
    private func write(type: AirlivePacket.PacketType, payload: Data, timestampMicros: Int64) {
        guard ready, let conn = connection else { return }
        let data = AirlivePacket(type: type, timestampMicros: timestampMicros, payload: payload).encode()
        conn.send(content: data, completion: .idempotent)
    }
}
