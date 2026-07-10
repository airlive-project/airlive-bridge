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

    // Resolved on first successful load; safe stubs until then.  Written once under
    // `lock`, then read-only (uses happen only after `loadIfNeeded()` returned true).
    private(set) var available = false
    private(set) var createSocket: srt_create_socket_t = { -1 }
    private(set) var connect: srt_connect_t = { _, _, _ in -1 }
    private(set) var send: srt_send_t = { _, _, _ in -1 }
    private(set) var close: srt_close_t = { _ in -1 }

    private var didStartup = false
    private let lock = NSLock()

    private init() {}   // NO eager load — the dlopen lives in loadIfNeeded (retryable).

    /// (Re)attempt to dlopen libsrt + resolve symbols if not already loaded.  A cheap
    /// no-op once loaded.  RETRYABLE (load is here, not in `init`) so "brew install
    /// srt, THEN toggle SRT on" works WITHOUT restarting the app.
    @discardableResult
    func loadIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if available { return true }
        guard let handle = SRTRuntime.open(),
              let startup = dlsym(handle, "srt_startup").map({ unsafeBitCast($0, to: srt_startup_t.self) }),
              let create  = dlsym(handle, "srt_create_socket").map({ unsafeBitCast($0, to: srt_create_socket_t.self) }),
              let conn    = dlsym(handle, "srt_connect").map({ unsafeBitCast($0, to: srt_connect_t.self) }),
              let snd     = dlsym(handle, "srt_send").map({ unsafeBitCast($0, to: srt_send_t.self) }),
              let cls     = dlsym(handle, "srt_close").map({ unsafeBitCast($0, to: srt_close_t.self) })
        else {
            print("""
            [SRTOutput] libsrt not found — SRT output disabled. Install it with \
            `brew install srt` (or set AIRLIVE_LIBSRT to the dylib path).
            """)
            return false
        }
        if !didStartup { _ = startup(); didStartup = true }   // srt_startup once per process
        createSocket = create; connect = conn; send = snd; close = cls
        available = true
        return true
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
    /// Lock-backed: renamed on main (BridgeModel.renameOutput) while `queue` reads it for log lines —
    /// a plain `var label: String` races the String's CoW buffer across threads.  Shares `liveLock`
    /// with `isLive`/`isConnected` (same trivial-contention pattern).
    var label: String {
        get { liveLock.lock(); defer { liveLock.unlock() }; return _label }
        set { liveLock.lock(); _label = newValue; liveLock.unlock() }
    }
    private var _label: String
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

    /// Card-visible failure (see VideoOutput.lastError).  Main-confined; reuses
    /// `onConnectionChanged` as the re-render nudge so no extra plumbing is needed.
    private(set) var lastError: String?
    private func reportError(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastError != message else { return }
            self.lastError = message
            self.onConnectionChanged?()
        }
    }

    func clearError() { reportError(nil) }

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

    init(label: String) { self._label = label }

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

    /// Bounded-backlog guard for `relaySample`.  We set NO socket options (only startup/create/
    /// connect/send/close are resolved), so libsrt defaults hold: `srt_send` is BLOCKING
    /// (SRTO_SNDSYN), but live-mode's sender-side too-late drop (SRTO_TLPKTDROP, ~1 s floor)
    /// time-caps the send buffer, so a single-digit-Mbps wire should never fill the ~8192-packet
    /// SNDBUF and block chronically.  "Should" is libsrt's promise, not ours — and the blocking
    /// srt_connect (~3 s) / dead-peer (~5 s SRTO_PEERIDLETIMEO) windows DO stall `queue`
    /// transiently while samples keep arriving, each enqueue retaining a full payload.  So:
    /// count enqueued samples (shares `liveLock`, the file's trivial-contention pattern) and
    /// DROP the newest past ~2 s at 30 fps — one-shot log per episode, not per sample.  Dropped
    /// access units corrupt decode only until the next keyframe, the same self-heal as the
    /// awaitingFormat / forced-IDR machinery after a CUT.
    private var pendingSamples = 0
    private var backlogDropping = false
    private static let maxPendingSamples = 60   // ~2 s of samples at 30 fps

    func relaySample(_ payload: Data, timestampMicros: Int64) {
        liveLock.lock()
        if pendingSamples >= Self.maxPendingSamples {
            let firstDrop = !backlogDropping
            backlogDropping = true
            liveLock.unlock()   // `label` takes liveLock — must not print while holding it
            if firstDrop {
                print("[SRTOutput \(label)] ⚠️ send backlog > \(Self.maxPendingSamples) samples — dropping newest until it drains")
            }
            return
        }
        pendingSamples += 1
        liveLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.drainPendingSample()
            guard !self.awaitingFormat, self.isLive, self.sock != SRT_INVALID_SOCK else { return }
            let nals = H264NAL.nalUnits(fromAVCC: payload)
            guard !nals.isEmpty else { return }
            let keyframe = nals.contains { H264NAL.type(of: $0) == 5 }
            let ts = self.muxer.mux(nals: nals,
                                    pts90k: H264NAL.ts90kHz(microseconds: timestampMicros),
                                    isKeyframe: keyframe)
            self.transmit(ts)
        }
    }

    /// Queue-side half of the backlog guard: decrement as each enqueued sample starts, and emit
    /// the matching one-shot "recovered" line once the backlog drains below half the threshold.
    private func drainPendingSample() {
        liveLock.lock()
        pendingSamples -= 1
        let recovered = backlogDropping && pendingSamples < Self.maxPendingSamples / 2
        if recovered { backlogDropping = false }
        liveLock.unlock()
        if recovered { print("[SRTOutput \(label)] ✅ send backlog drained — resuming samples") }
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
        guard SRTRuntime.shared.loadIfNeeded() else {   // RETRIES the dlopen — picks up libsrt installed since launch
            reportError("SRT runtime isn't available — install it with `brew install srt`")
            isLive = false; return
        }
        guard let (host, port) = Self.parse(dest) else {
            if lastInvalidDestLogged != dest {   // once per distinct value, not per retry
                lastInvalidDestLogged = dest
                print("[SRTOutput \(label)] ❌ invalid destination '\(dest)' — expected srt://host:port")
            }
            reportError("Invalid destination — expected srt://host:port")
            isLive = false; return
        }
        lastInvalidDestLogged = nil
        let s = SRTRuntime.shared.createSocket()
        guard s != SRT_INVALID_SOCK else {
            print("[SRTOutput \(label)] ❌ create_socket failed")
            reportError("SRT socket creation failed")
            isLive = false; return
        }

        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else {
            print("[SRTOutput \(label)] ❌ can't resolve \(host)")
            reportError("Can't resolve “\(host)”")
            _ = SRTRuntime.shared.close(s); isLive = false; return
        }
        defer { freeaddrinfo(res) }

        let rc = SRTRuntime.shared.connect(s, info.pointee.ai_addr, Int32(info.pointee.ai_addrlen))
        guard rc != -1 else {
            print("[SRTOutput \(label)] ❌ connect to \(host):\(port) failed")
            reportError("\(host):\(port) isn't answering")
            _ = SRTRuntime.shared.close(s); isLive = false; return
        }
        sock = s
        isLive = true
        setConnected(true)
        reportError(nil)   // connected — clear any stale failure
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
