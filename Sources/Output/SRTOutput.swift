// SRTOutput.swift — PROGRAM → SRT (caller), passthrough (no transcode).
//
// Pushes the program camera's ORIGINAL H.264, wrapped in MPEG-TS (MPEGTSMuxer),
// to a remote SRT ingest entered as the output's destination (`srt://host:port`).
// SRT is the "stream over the internet reliably" transport — caller mode connects
// out to a media server / cloud ingest.  Zero decode, zero encode.
//
// libsrt is loaded at RUNTIME (dlopen), exactly like libndi: the app ships without
// it and degrades gracefully (not live + a one-line "brew install srt" hint) when
// it's absent, so no build/link dependency and no crash on a machine without SRT.
//
// MUST be validated against a real SRT receiver (e.g. `ffmpeg -i 'srt://…?mode=
// listener'` or an SRT server) once libsrt is installed — the wire can't be
// exercised from a unit build.

import Foundation
import Darwin
import CoreVideo

// libsrt C entry points we resolve (subset for a live caller).
private typealias srt_startup_t       = @convention(c) () -> Int32
private typealias srt_create_socket_t = @convention(c) () -> Int32
private typealias srt_connect_t       = @convention(c) (Int32, UnsafePointer<sockaddr>?, Int32) -> Int32
private typealias srt_send_t          = @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32
private typealias srt_close_t         = @convention(c) (Int32) -> Int32

/// Loads libsrt once per process and vends the resolved symbols.
private final class SRTRuntime {
    static let shared = SRTRuntime()

    let available: Bool
    let createSocket: srt_create_socket_t
    let connect: srt_connect_t
    let send: srt_send_t
    let close: srt_close_t

    private init() {
        guard let handle = SRTRuntime.open(),
              let startup = dlsym(handle, "srt_startup").map({ unsafeBitCast($0, to: srt_startup_t.self) }),
              let create  = dlsym(handle, "srt_create_socket").map({ unsafeBitCast($0, to: srt_create_socket_t.self) }),
              let conn    = dlsym(handle, "srt_connect").map({ unsafeBitCast($0, to: srt_connect_t.self) }),
              let snd     = dlsym(handle, "srt_send").map({ unsafeBitCast($0, to: srt_send_t.self) }),
              let cls     = dlsym(handle, "srt_close").map({ unsafeBitCast($0, to: srt_close_t.self) })
        else {
            available = false
            createSocket = { -1 }; connect = { _, _, _ in -1 }
            send = { _, _, _ in -1 }; close = { _ in -1 }
            print("""
            [SRTOutput] libsrt not found — SRT output disabled. Install it with \
            `brew install srt` (or set AIRLIVE_LIBSRT to the dylib path).
            """)
            return
        }
        _ = startup()
        available = true
        createSocket = create; connect = conn; send = snd; close = cls
    }

    private static func open() -> UnsafeMutableRawPointer? {
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["AIRLIVE_LIBSRT"] { paths.append(env) }
        paths += [
            "/opt/homebrew/lib/libsrt.dylib", "/opt/homebrew/lib/libsrt.1.dylib",
            "/usr/local/lib/libsrt.dylib", "/usr/local/lib/libsrt.1.dylib",
            "libsrt.dylib", "libsrt.1.dylib",
        ]
        for p in paths { if let h = dlopen(p, RTLD_NOW | RTLD_LOCAL) { return h } }
        return nil
    }
}

private let SRT_INVALID_SOCK: Int32 = -1
/// MPEG-TS-over-SRT live payload: 7 TS packets (7×188 = 1316), the SRT default.
private let srtPayloadSize = 1316

final class SRTOutput: VideoOutput {
    let id = UUID()
    var label: String
    let kind: OutputKind = .srt
    var config: String = ""        // destination: srt://host:port

    /// Live flag — written from `queue` (connect / stop / dropConnection) AND from
    /// main (start's optimistic set), read from main (BridgeModel.feedProgram) and
    /// from `queue` (relaySample).  Lock-backed `_isLive` so a main read can never
    /// observe a torn write (the NDIOutput pattern); every existing `isLive = …`
    /// assignment goes through the locked setter unchanged.
    var isLive: Bool {
        get { liveLock.lock(); defer { liveLock.unlock() }; return _isLive }
        set { liveLock.lock(); _isLive = newValue; liveLock.unlock() }
    }
    private var _isLive = false
    private let liveLock = NSLock()

    /// Fires on MAIN when the caller actually connects — the model forces one IDR so the
    /// receiver decodes immediately instead of waiting out the camera's 6–10 s GOP.
    var onReady: (() -> Void)?

    /// True while the SRT socket is ACTUALLY connected (isLive is true already during the
    /// brief connect attempt) — drives the card's spinner→green power button.
    var isConnected: Bool { liveLock.lock(); defer { liveLock.unlock() }; return _isConnected }
    private var _isConnected = false
    /// Fires on MAIN whenever `isConnected` flips (model → objectWillChange → live card state).
    var onConnectionChanged: (() -> Void)?
    private func setConnected(_ value: Bool) {
        liveLock.lock()
        let changed = _isConnected != value
        _isConnected = value
        liveLock.unlock()
        if changed { DispatchQueue.main.async { [weak self] in self?.onConnectionChanged?() } }
    }

    private let queue = DispatchQueue(label: "studio.airlive.bridge.srt", qos: .userInitiated)
    private var sock: Int32 = SRT_INVALID_SOCK
    private let muxer = MPEGTSMuxer()
    /// Last destination we logged as invalid — the toggle/retry path re-hits connect(), and
    /// re-printing the same complaint every attempt flooded the console (seen live).
    private var lastInvalidDestLogged: String?
    /// Passthrough-CUT gating (mirrors AirliveRelayOutput): drop forwarded samples until the new
    /// source's SPS/PPS arrives after a program CUT, so SRT/TS receivers don't decode the new
    /// camera's deltas against the previous camera's muxer parameter sets (#20).
    private var awaitingFormat = false
    private var awaitToken = 0

    init(label: String) { self.label = label }

    func start() {
        guard !isLive else { return }
        isLive = true                 // optimistic (matches NDI/relay); cleared if connect fails
        let dest = config
        queue.async { [weak self] in self?.connect(to: dest) }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.sock != SRT_INVALID_SOCK { _ = SRTRuntime.shared.close(self.sock); self.sock = SRT_INVALID_SOCK }
            self.isLive = false
            self.setConnected(false)
            self.awaitingFormat = false   // don't inherit a stale CUT gate across a stop/start
        }
    }

    func send(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {}   // passthrough — unused

    func relayFormat(_ payload: Data) {
        queue.async { [weak self] in
            guard let self, let ps = H264NAL.parameterSets(fromFormat: payload) else { return }
            self.muxer.sps = ps.sps; self.muxer.pps = ps.pps
            self.awaitingFormat = false   // new source's format is here — samples may flow (#20)
        }
    }

    /// Forget cached SPS/PPS when the program moves to a source with no raw H.264 (AirPlay/combined).
    func clearLastFormat() {
        queue.async { [weak self] in self?.muxer.sps = nil; self?.muxer.pps = nil }
    }

    /// Gate samples until the next format after a CUT; 1.5 s safety timeout so a swallowed/dropped
    /// keyframe doesn't strand SRT receivers frozen until the next long-GOP keyframe.
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
            guard let self, !self.awaitingFormat, self.isLive, self.sock != SRT_INVALID_SOCK else { return }
            let nals = H264NAL.nalUnits(fromAVCC: payload)
            guard !nals.isEmpty else { return }
            let keyframe = nals.contains { H264NAL.type(of: $0) == 5 }
            let ts = self.muxer.mux(nals: nals,
                                    pts90k: H264NAL.ts90kHz(microseconds: timestampMicros),
                                    isKeyframe: keyframe)
            self.transmit(ts)
        }
    }

    // MARK: - Queue-confined

    /// Send TS bytes in SRT payload-sized chunks (each a multiple of 188).
    private func transmit(_ data: Data) {
        let bytes = [UInt8](data)
        var offset = 0
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            while offset < bytes.count {
                let n = min(srtPayloadSize, bytes.count - offset)
                let sent = base.advanced(by: offset).withMemoryRebound(to: CChar.self, capacity: n) {
                    SRTRuntime.shared.send(sock, $0, Int32(n))
                }
                if sent < 0 { self.dropConnection(); return }   // peer gone — tear down
                offset += n
            }
        }
    }

    private func connect(to dest: String) {
        guard SRTRuntime.shared.available else { isLive = false; return }
        guard let (host, port) = Self.parse(dest) else {
            if lastInvalidDestLogged != dest {   // once per distinct value, not per retry
                lastInvalidDestLogged = dest
                print("[SRTOutput \(label)] ❌ invalid destination '\(dest)' — expected srt://host:port")
            }
            isLive = false; return
        }
        lastInvalidDestLogged = nil
        let s = SRTRuntime.shared.createSocket()
        guard s != SRT_INVALID_SOCK else {
            print("[SRTOutput \(label)] ❌ create_socket failed"); isLive = false; return
        }

        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else {
            print("[SRTOutput \(label)] ❌ can't resolve \(host)")
            _ = SRTRuntime.shared.close(s); isLive = false; return
        }
        defer { freeaddrinfo(res) }

        let rc = SRTRuntime.shared.connect(s, info.pointee.ai_addr, Int32(info.pointee.ai_addrlen))
        guard rc != -1 else {
            print("[SRTOutput \(label)] ❌ connect to \(host):\(port) failed")
            _ = SRTRuntime.shared.close(s); isLive = false; return
        }
        sock = s
        isLive = true
        setConnected(true)
        print("[SRTOutput \(label)] ✅ SRT caller connected to \(host):\(port)")
        DispatchQueue.main.async { [weak self] in self?.onReady?() }   // model forces one IDR
    }

    private func dropConnection() {
        if sock != SRT_INVALID_SOCK { _ = SRTRuntime.shared.close(sock); sock = SRT_INVALID_SOCK }
        isLive = false
        setConnected(false)
        print("[SRTOutput \(label)] 🔌 SRT peer gone — stopped")
    }

    /// Parse `srt://host:port` (scheme optional, query ignored for v1).
    private static func parse(_ s: String) -> (String, UInt16)? {
        var str = s.trimmingCharacters(in: .whitespaces)
        if let r = str.range(of: "://") { str = String(str[r.upperBound...]) }
        if let q = str.firstIndex(of: "?") { str = String(str[..<q]) }
        let parts = str.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]), !parts[0].isEmpty else { return nil }
        return (String(parts[0]), port)
    }
}
