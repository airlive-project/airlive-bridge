// RTSPOutput.swift — PROGRAM → RTSP server, passthrough (no transcode).
//
// A minimal RTSP/1.0 server that re-publishes the program camera's ORIGINAL H.264
// over RTP (RFC 6184).  Like the OBS relay it consumes the raw H.264 taps
// (`relayFormat` = SPS/PPS, `relaySample` = AVCC access units) — zero decode, zero
// encode — and packetizes the NAL units into RTP.  Clients (VLC, ffmpeg, vMix,
// Resolume…) connect to `rtsp://<mac-ip>:<port>/program`.
//
// Transport: RTP **interleaved over the RTSP TCP connection** ($-framed, RFC 2326
// §10.12).  TCP interleaving is the robust LAN choice — lossless, one socket, no
// UDP-port/NAT negotiation.  (UDP unicast can be added later if a tool needs it.)
//
// Scope note: this is a single-stream (video-only) server.  It MUST be validated
// against a real client (VLC / `ffplay rtsp://… -rtsp_transport tcp`) — protocol
// behaviour can't be exercised from a unit build.

import Foundation
import Network
import CoreVideo

final class RTSPOutput: VideoOutput {
    let id = UUID()
    var label: String
    let kind: OutputKind = .rtsp

    /// Live flag — written from main (start/stop) AND from `queue` (startListener's
    /// failure path), read from main (BridgeModel.feedProgram).  Lock-backed so a
    /// main read can't observe a torn write (NDIOutput pattern); existing
    /// `isLive = …` assignments go through the locked setter unchanged.
    var isLive: Bool {
        get { liveLock.lock(); defer { liveLock.unlock() }; return _isLive }
        set { liveLock.lock(); _isLive = newValue; liveLock.unlock() }
    }
    private var _isLive = false
    private let liveLock = NSLock()

    /// True while ≥1 RTSP client is actually PLAYING (not merely: server started).  Read on main by
    /// BridgeModel to decide whether a program CUT needs a forced IDR — `isLive` alone (server up, no
    /// client) would poke the phone for nobody (CLAUDE.md "no work for nobody").  Maintained on `queue`
    /// (refreshPlayState) from the queue-confined client play/close transitions; read under liveLock.
    private var _hasPlayingClient = false
    var hasPlayingClient: Bool { liveLock.lock(); defer { liveLock.unlock() }; return _hasPlayingClient }

    /// Fires on MAIN when a client starts PLAYING — the model forces one IDR so the new viewer
    /// decodes immediately instead of waiting out the camera's 6–10 s GOP.
    var onPlay: (() -> Void)?
    /// Card-visible failure (see VideoOutput.lastError).  Main-confined.
    private(set) var lastError: String?
    /// Fires on MAIN when `lastError` changes — the model nudges objectWillChange
    /// so the card re-renders (VideoOutput isn't observable).
    var onStateChanged: (() -> Void)?
    let port: UInt16

    private let queue = DispatchQueue(label: "studio.airlive.bridge.rtsp", qos: .userInitiated)
    private var listener: NWListener?
    private var clients: [RTSPClient] = []

    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var seq: UInt16 = 0
    private let ssrc: UInt32 = 0x4152_4C56   // "ARLV"
    /// Passthrough-CUT gating (mirrors AirliveRelayOutput): drop forwarded samples until the new
    /// source's SPS/PPS arrives after a program CUT, so RTP/RTSP clients don't packetize the new
    /// camera's NALs against the previous camera's sprop-parameter-sets (#20). awaitToken
    /// invalidates a stale safety-timeout when a newer await/format lands.
    private var awaitingFormat = false
    private var awaitToken = 0

    /// Max RTP payload before FU-A fragmentation.  ~1400 keeps packets comfortably
    /// under a typical MTU even though TCP wouldn't strictly require it.
    private let maxRTPPayload = 1400

    init(label: String, port: UInt16 = 8554) {
        self.label = label
        self.port = port
    }

    // MARK: - VideoOutput

    func start() {
        guard !isLive else { return }
        isLive = true
        queue.async { [weak self] in self?.startListener() }
    }

    func stop() {
        guard isLive else { return }
        isLive = false
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel(); self.listener = nil
            self.clients.forEach { $0.close() }; self.clients.removeAll()
            self.sps = nil; self.pps = nil
            self.awaitingFormat = false   // don't inherit a stale CUT gate across a stop/start
        }
    }

    func send(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {}   // passthrough — unused

    func relayFormat(_ payload: Data) {
        queue.async { [weak self] in
            guard let self, let ps = H264NAL.parameterSets(fromFormat: payload) else { return }
            self.sps = ps.sps; self.pps = ps.pps
            self.awaitingFormat = false   // new source's format is here — samples may flow (#20)
        }
    }

    /// Forget cached SPS/PPS when the program moves to a source with no raw H.264 (AirPlay/combined).
    func clearLastFormat() {
        queue.async { [weak self] in self?.sps = nil; self?.pps = nil }
    }

    /// Gate samples until the next format after a CUT; 1.5 s safety timeout so a swallowed/dropped
    /// keyframe doesn't strand RTSP clients frozen until the next long-GOP keyframe.
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

    func relaySample(_ payload: Data, timestampMicros: Int64) {
        queue.async { [weak self] in
            guard let self, !self.awaitingFormat else { return }   // drop until new format after a CUT (#20)
            let nals = H264NAL.nalUnits(fromAVCC: payload)
            guard !nals.isEmpty else { return }
            let ts = H264NAL.ts90kHz(microseconds: timestampMicros)
            let packets = self.packetize(nals: nals, timestamp: ts)
            for client in self.clients where client.isPlaying {
                client.sendInterleaved(packets)
            }
        }
    }

    // MARK: - Listener (queue-confined)

    /// Anonymous LAN clients get no auth by product design — so cap how many can
    /// hold sessions at once (bounds the RTP fan-out) instead.
    private static let maxClients = 16

    private func startListener() {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do {
            l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("[RTSP \(label)] ❌ listen on \(port) failed: \(error)")
            reportError("Port \(port) is busy — quit the app holding it, then toggle again")
            isLive = false
            return
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            guard self.clients.count < Self.maxClients else { conn.cancel(); return }
            let client = RTSPClient(connection: conn, queue: self.queue, owner: self)
            self.clients.append(client)
            client.start()
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                print("[RTSP \(self?.label ?? "")] ✅ rtsp://…:\(self?.port ?? 0)/program")
                self?.reportError(nil)   // bound successfully — clear any stale failure
            }
        }
        l.start(queue: queue)
        listener = l
    }

    /// Publish/clear the card-visible failure line (main-confined; `onStateChanged`
    /// nudges the model so the card re-renders).
    private func reportError(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastError != message else { return }
            self.lastError = message
            self.onStateChanged?()
        }
    }

    func clearError() { reportError(nil) }

    /// Remove a client that closed (called on `queue` by the client).
    fileprivate func remove(_ client: RTSPClient) {
        clients.removeAll { $0 === client }
        refreshPlayState()
    }

    /// Recompute the "any client playing" flag from the queue-confined `clients`.  MUST be called on
    /// `queue` (client add/remove + PLAY transitions all run there); publishes to the lock-backed flag.
    fileprivate func refreshPlayState() {
        let any = clients.contains { $0.isPlaying }
        liveLock.lock(); _hasPlayingClient = any; liveLock.unlock()
    }

    /// SDP describing the single H.264 video track (uses the live SPS/PPS if known).
    fileprivate func sdp(host: String) -> String {
        var fmtp = "a=fmtp:96 packetization-mode=1"
        if let sps, let pps {
            // profile-level-id = SPS bytes 1..3 (profile_idc, constraints, level_idc).
            if sps.count >= 4 {
                fmtp += String(format: ";profile-level-id=%02X%02X%02X", sps[1], sps[2], sps[3])
            }
            fmtp += ";sprop-parameter-sets=\(Data(sps).base64EncodedString()),\(Data(pps).base64EncodedString())"
        }
        return [
            "v=0",
            "o=- 0 0 IN IP4 \(host)",
            "s=Airlive Bridge",
            "c=IN IP4 \(host)",
            "t=0 0",
            "m=video 0 RTP/AVP 96",
            "a=rtpmap:96 H264/90000",
            fmtp,
            "a=control:streamid=0",
            "",
        ].joined(separator: "\r\n")
    }

    // MARK: - RTP packetization (RFC 6184)

    /// One access unit → RTP packets (single-NAL or FU-A), marker on the last.
    private func packetize(nals: [[UInt8]], timestamp: UInt32) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        for (idx, nal) in nals.enumerated() {
            let isLastNAL = (idx == nals.count - 1)
            if nal.count <= maxRTPPayload {
                packets.append(rtpPacket(payload: nal, marker: isLastNAL, timestamp: timestamp))
            } else {
                let header = nal[0]
                let nri = header & 0x60
                let type = header & 0x1F
                var offset = 1
                let chunkMax = maxRTPPayload - 2   // 2-byte FU indicator + header
                while offset < nal.count {
                    let chunk = min(chunkMax, nal.count - offset)
                    let isStart = (offset == 1)
                    let isEnd = (offset + chunk >= nal.count)
                    var fu: [UInt8] = [nri | 28,                                  // FU-A indicator
                                       (isStart ? 0x80 : 0) | (isEnd ? 0x40 : 0) | type]
                    fu.append(contentsOf: nal[offset ..< offset + chunk])
                    packets.append(rtpPacket(payload: fu, marker: isLastNAL && isEnd, timestamp: timestamp))
                    offset += chunk
                }
            }
        }
        return packets
    }

    private func rtpPacket(payload: [UInt8], marker: Bool, timestamp: UInt32) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 12)
        p[0] = 0x80                                  // V=2, no padding/ext/CSRC
        p[1] = (marker ? 0x80 : 0) | 96              // marker | PT=96 (dynamic H.264)
        p[2] = UInt8(seq >> 8); p[3] = UInt8(seq & 0xFF)
        seq = seq &+ 1
        p[4] = UInt8((timestamp >> 24) & 0xFF); p[5] = UInt8((timestamp >> 16) & 0xFF)
        p[6] = UInt8((timestamp >> 8) & 0xFF);  p[7] = UInt8(timestamp & 0xFF)
        p[8] = UInt8((ssrc >> 24) & 0xFF); p[9] = UInt8((ssrc >> 16) & 0xFF)
        p[10] = UInt8((ssrc >> 8) & 0xFF); p[11] = UInt8(ssrc & 0xFF)
        p.append(contentsOf: payload)
        return p
    }
}

// MARK: - One RTSP client session

private final class RTSPClient {
    private(set) var isPlaying = false

    private let connection: NWConnection
    private let queue: DispatchQueue
    private weak var owner: RTSPOutput?
    private var requestBuffer = Data()
    private var session = "ARLV\(UInt32.random(in: 1000 ... 999_999))"
    /// Interleaved channel the client asked for RTP on (RTP-Info channel).
    private var rtpChannel: UInt8 = 0

    init(connection: NWConnection, queue: DispatchQueue, owner: RTSPOutput) {
        self.connection = connection
        self.queue = queue
        self.owner = owner
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.handleClosed()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() { connection.cancel() }

    private func handleClosed() {
        isPlaying = false
        owner?.remove(self)
    }

    /// Requests we serve are a few hundred bytes of headers; anything past this
    /// without a terminator is a garbage/hostile client — drop it instead of
    /// buffering its bytes forever (the RTSP port is open to the LAN by design).
    private static let maxRequestBytes = 8 * 1024

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isDone, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.requestBuffer.append(data)
                self.drainRequests()
                if self.requestBuffer.count > Self.maxRequestBytes {
                    print("[RTSP] request exceeded \(Self.maxRequestBytes) B without a terminator — dropping client")
                    self.close(); self.handleClosed(); return
                }
            }
            if isDone || error != nil { self.handleClosed(); return }
            self.receive()
        }
    }

    /// RTSP requests are text terminated by a blank line (CRLFCRLF).  No bodies in
    /// the methods we serve, so a header terminator fully delimits each request.
    private func drainRequests() {
        let terminator = Data("\r\n\r\n".utf8)
        while let range = requestBuffer.range(of: terminator) {
            let head = requestBuffer.subdata(in: requestBuffer.startIndex ..< range.lowerBound)
            requestBuffer.removeSubrange(requestBuffer.startIndex ..< range.upperBound)
            if let text = String(data: head, encoding: .utf8) { handleRequest(text) }
        }
    }

    private func handleRequest(_ text: String) {
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let cseq = headerValue("CSeq", in: lines) ?? "0"

        switch method {
        case "OPTIONS":
            respond(cseq: cseq, extra: "Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER")
        case "DESCRIBE":
            let host = localHost()
            let body = owner?.sdp(host: host) ?? ""
            let bytes = Data(body.utf8)
            respond(cseq: cseq,
                    extra: "Content-Type: application/sdp\r\nContent-Length: \(bytes.count)",
                    body: body)
        case "SETUP":
            // Honour the client's interleaved channels if given; default 0-1.
            if let transport = headerValue("Transport", in: lines),
               let r = transport.range(of: "interleaved="),
               let ch = Int(transport[r.upperBound...].prefix { $0.isNumber }) {
                rtpChannel = UInt8(ch)
            }
            respond(cseq: cseq,
                    extra: "Transport: RTP/AVP/TCP;unicast;interleaved=\(rtpChannel)-\(rtpChannel + 1)\r\nSession: \(session)")
        case "PLAY":
            isPlaying = true
            owner?.refreshPlayState()   // a client is now playing → RTSP is a live passthrough consumer
            // Force one IDR for the fresh viewer — a mid-GOP join would otherwise sit on garbage
            // until the camera's next natural keyframe (LAN GOP is 6–10 s).
            if let owner { DispatchQueue.main.async { owner.onPlay?() } }
            respond(cseq: cseq, extra: "Session: \(session)\r\nRTP-Info: url=stream")
        case "GET_PARAMETER":
            respond(cseq: cseq, extra: "Session: \(session)")   // keepalive
        case "TEARDOWN":
            respond(cseq: cseq, extra: "Session: \(session)")
            close()
        default:
            respond(cseq: cseq, status: "501 Not Implemented")
        }
    }

    private func headerValue(_ name: String, in lines: [String]) -> String? {
        let prefix = "\(name.lowercased()):"
        for line in lines where line.lowercased().hasPrefix(prefix) {
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func localHost() -> String {
        if case let .hostPort(host, _)? = connection.currentPath?.localEndpoint,
           case let .ipv4(addr) = host { return "\(addr)" }
        return "0.0.0.0"
    }

    private func respond(cseq: String, status: String = "200 OK", extra: String? = nil, body: String? = nil) {
        var msg = "RTSP/1.0 \(status)\r\nCSeq: \(cseq)\r\n"
        if let extra { msg += extra + "\r\n" }
        msg += "\r\n"
        if let body { msg += body }
        connection.send(content: Data(msg.utf8), completion: .idempotent)
    }

    /// Send RTP packets $-framed over the RTSP TCP connection (RFC 2326 §10.12).
    func sendInterleaved(_ packets: [[UInt8]]) {
        var out = Data()
        for pkt in packets {
            out.append(0x24)                 // '$'
            out.append(rtpChannel)           // interleaved channel
            out.append(UInt8(pkt.count >> 8))
            out.append(UInt8(pkt.count & 0xFF))
            out.append(contentsOf: pkt)
        }
        connection.send(content: out, completion: .idempotent)
    }
}
