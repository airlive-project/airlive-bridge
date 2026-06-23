// BridgeChannelReceiver.swift — Bridge's concrete channel receiver.
//
// Conforms to the `ChannelReceiver` seam declared in Model/ChannelReceiver.swift.
// Ported from AirliveStudioApp/Sources/CamSlotReceiver.swift (the frozen Studio
// app) and adapted to the Bridge model:
//
//   • One TCP listener on an EPHEMERAL port + one Bonjour `_airlive._tcp`
//     advertisement per channel.  Accepts ONE iPhone; keeps listening for
//     reconnect.  busy=0|1 flips on connect/disconnect.
//   • Bytes → PacketParser → VTDecompressionSession → CVPixelBuffer, with the
//     jitter / playout-delay buffer (lower-envelope minimum-delay skew tracking)
//     ported verbatim so frames present on a stable, operator-chosen delay.
//   • Per presented frame: enqueue the decoded buffer (wrapped in a
//     `CMSampleBuffer`) into the channel's `AVSampleBufferDisplayLayer`
//     (`channel.displayLayer`, when `previewEnabled`) AND forward it to every
//     `VideoOutput`.  Per-frame pixels NEVER go through a `@Published` property
//     (that froze the preview on one frame and risked publish-during-update
//     warnings); only the low-frequency `latestFrame` gate / `isConnected` /
//     `remote` are published, on the main queue.  We enqueue for IMMEDIATE
//     display (the jitter ring below already gated playout latency), so the
//     display layer just paints what we hand it when we hand it over.
//   • Control channel (`.control` packets) is full-duplex on the SAME socket:
//     inbound `state` snapshots update `channel.remote`; outbound `set...` /
//     tally `setCue` commands are framed and written back.
//
// DROPPED from the Studio port (Bridge is receive + control + outputs only):
// switcher / compositor / program / multiview-mirror / audio / recorder /
// YouTube / HaishinKit, and Studio's separate UDP tally fast-path (Bridge sends
// tally over the same TCP control channel via `ControlMessage.setCue`).
//
// Threading: all network + decode work runs on `queue` (`.userInteractive`); the
// decode callback runs on a VideoToolbox queue and hops through `pixelBufferLock`;
// every mutation of the owning channel's `@Published` properties is dispatched to
// `DispatchQueue.main`.  `weak var channel` breaks the channel↔receiver cycle.

import Foundation
import Network
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo
import QuartzCore

/// One channel's network receiver — listener, Bonjour advertisement, H.264
/// decoder, jitter buffer, and control duplex.  Owned by its `BridgeChannel`;
/// enqueues decoded frames into the channel's `AVSampleBufferDisplayLayer`
/// (clearing it via `onClear` on disconnect), publishes only the low-frequency
/// state / connection status onto the channel's `@Published` properties on the
/// main queue, and fans every decoded frame out to the channel's `VideoOutput`s.
final class BridgeChannelReceiver: ChannelReceiver {

    // ── Identity ──────────────────────────────────────────────────────────
    /// The owning channel.  Weak — the channel retains the receiver, so the
    /// receiver must NOT retain the channel (would leak both).  All published
    /// updates go `channel?.…` on the main queue.
    private weak var channel: BridgeChannel?

    /// Stable routing id (the channel's id) — used as the Bonjour `sid` so an
    /// iPhone reconnects to the same source even after a rename.
    private let channelID: UUID
    /// Device-level identity (`did` + `dev`) shared across all of this Bridge's
    /// channels.
    private let identity: BridgeIdentity

    /// Bonjour `sid` — stable per-source id (the channel's UUID string).
    private let sid: String
    /// Bonjour instance NAME — kept stable so a re-advertise (rename / dev
    /// change) never churns the service registration.  Display/identity is
    /// `did`+`sid`+`src`, not this.
    private let instanceName: String
    /// Source display name advertised as TXT `src`.  Mutated only on `queue`.
    private var src: String
    /// Order index advertised as TXT `ord` — the channel's position in the
    /// operator's Bridge list, so the iPhone can sort by it instead of by the
    /// (renameable) name.  Mutated only on `queue`.
    private var order: Int = 0

    // ── Network ───────────────────────────────────────────────────────────
    private var listener: NWListener?
    private var connection: NWConnection?
    /// Dual-stack in-flight candidates (IPv6 + IPv4) racing to `.ready`; the
    /// first to connect wins, the rest are cancelled.  Queue-confined.
    private var pendingConnections: [NWConnection] = []
    /// Last busy state advertised — so a name-only re-advertise keeps the flag.
    private var advertisedBusy = false

    private let parser = PacketParser()
    private var formatDescription: CMVideoFormatDescription?

    /// Serial work queue — listener, accept, receive, parse, decode-submit, and
    /// jitter-ring scheduling all run here.  `.userInteractive` because late
    /// video is worse than a busy core (this is a live monitor).
    private let queue: DispatchQueue

    // ── Jitter buffer (operator-chosen playout delay) ─────────────────────
    // Ported verbatim from CamSlotReceiver: lower-envelope minimum-delay skew
    // tracking keeps the playout deadline pinned at `bufferSeconds` despite
    // iPhone↔Mac crystal drift over a long show.  See CamSlotReceiver for the
    // full prose; the math below is unchanged.

    /// Operator-chosen added delay (seconds), read from the channel's
    /// `LatencyPreset`.  0 (Lowest) = promote on decode; >0 = hold frames in
    /// `frameRing` until their playout deadline.  Re-read live on a preset change.
    private var bufferSeconds: Double

    private var anchorMacTime: TimeInterval = 0
    private var anchorIphonePTS: TimeInterval = 0
    private var anchorSet = false

    private var skewOffset: Double = 0
    private var skewWindow: [(t: TimeInterval, delta: Double)] = []
    private let skewWindowSeconds: Double = 3.0
    private let skewSlewGain: Double = 0.01
    private let skewJumpThreshold: Double = 2.0

    /// PTS-ordered pending frames awaiting their playout deadline (ascending by
    /// `playout`).  Guarded by `pixelBufferLock`; bounded by `maxRingFrames`.
    private var frameRing: [(buffer: CVPixelBuffer, playout: TimeInterval)] = []
    private let pixelBufferLock = NSLock()

    // ── Decode ────────────────────────────────────────────────────────────
    private var decompressionSession: VTDecompressionSession?
    private var decompressionFormat: CMVideoFormatDescription?
    private var lastDecodeErrorLog: TimeInterval = 0
    private var didLogFirstFrame = false // one-shot preview diagnostic

    // ── Receiver-password auth (challenge-response) ───────────────────────
    // Queue-confined (every field below is read/written only on `queue`).  See
    // docs/STREAM-AUTH-SPEC.md.  Config is snapshotted here via `updateAuth(…)`
    // so the verify path never touches the channel's main-isolated @Published
    // state.  `effectiveAuthRequired` gates a connection ONLY when enabled AND a
    // password is set — an enabled-but-blank toggle never locks anyone out.
    private var requireAuth = false
    private var authPassword = ""
    /// True once a connection is cleared to stream — set ONLY inside the
    /// successful-verify branch (or immediately when auth is off).  The "challenge
    /// sent, not yet verified" boolean of the spec is `challengeNonce != nil`.
    private var authorized = false
    /// The single outstanding challenge nonce; non-nil ⇒ awaiting `authResponse`.
    /// Consumed (niled) on verify so a nonce is strictly single-use.
    private var challengeNonce: Data?
    /// `formatDescription` payload buffered while PENDING-AUTH (samples are
    /// dropped); applied once the connection authorizes.
    private var pendingFormatPayload: Data?
    private var authStallWork: DispatchWorkItem?
    /// Per-source failed-attempt counter + ban deadline (anti-bruteforce).  Keyed
    /// by remote host.  Receiver-side only, per-connect — zero per-frame cost.
    private var authBans: [String: (failures: Int, banUntil: TimeInterval)] = [:]

    private let authStallTimeout: TimeInterval = 15   // STREAM-AUTH-SPEC §4 (pinned)
    private let authMaxFailures = 5
    private let authBanBase: TimeInterval = 30
    private let authBanMax: TimeInterval = 600

    private var effectiveAuthRequired: Bool { requireAuth && !authPassword.isEmpty }

    // MARK: - Init / deinit

    init(channel: BridgeChannel, order: Int = 0, identity: BridgeIdentity = .shared) {
        self.channel      = channel
        self.channelID    = channel.id
        self.identity     = identity
        self.sid          = channel.id.uuidString
        self.src          = channel.name
        self.order        = order   // so the FIRST Bonjour advert already has the right ord
        self.instanceName = "Airlive \(channel.id.uuidString.prefix(8))"
        self.bufferSeconds = channel.delay.seconds
        self.queue        = DispatchQueue(label: "studio.airlive.bridge.channel.\(channel.id.uuidString)",
                                          qos: .userInteractive)
    }

    deinit {
        // Safety net for the no-`stop()` path (e.g. a channel dropped in a test
        // without a lifecycle call).  The normal teardown is `stop()`, which
        // drains + invalidates the decode session SYNCHRONOUSLY on `queue`, so by
        // the time `deinit` runs after a real `stop()` this guard finds nil.  If
        // we DO reach here with a live session, nothing is running on `queue`
        // (no async teardown was scheduled), so draining in-flight VT frames and
        // invalidating here is race-free.
        if let s = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
            decompressionSession = nil
        }
    }

    // MARK: - ChannelReceiver lifecycle

    func start() {
        queue.async { [weak self] in self?.startListening() }
        identity.registerReadvertiser(channelID) { [weak self] in
            self?.queue.async { self?.readvertise() }
        }
    }

    func stop() {
        // Called from the main thread (`BridgeModel.removeChannel`).  Asserting
        // it makes the `queue.sync` below safe to reason about: main blocks on
        // `queue`, so NOTHING running on `queue` may ever block back on main, or
        // it deadlocks.
        dispatchPrecondition(condition: .onQueue(.main))
        identity.unregisterReadvertiser(channelID)
        // SYNCHRONOUS teardown — `BridgeModel.removeChannel` calls this and then
        // drops the last strong reference, so the receiver can deallocate the
        // instant `stop()` returns.  An ASYNC teardown would race `deinit`: both
        // touch `decompressionSession` (deinit on the caller thread, the queued
        // block on `queue`) → data race + a possible straggler decode callback on
        // freed memory.  `queue.sync` guarantees the decode session is drained,
        // invalidated, and niled on `queue` BEFORE we return and the object dies.
        //
        // DEADLOCK INVARIANT — do NOT break: this `queue.sync` blocks main while
        // `teardownDecodeSession()` calls `VTDecompressionSessionWaitForAsynchronousFrames`,
        // which blocks until in-flight decode callbacks return.  Those callbacks
        // (`ingestDecoded` → `promoteDue` → `present`) only ever `DispatchQueue.main.async`
        // (enqueue-without-blocking) — they MUST NOT be changed to synchronously
        // dispatch back to `queue` or `.main.sync`, or this teardown deadlocks.
        queue.sync {
            self.listener?.cancel()
            self.listener = nil
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
            self.pendingConnections.forEach { $0.cancel() }
            self.pendingConnections.removeAll()
            self.teardownDecodeSession()
            self.pixelBufferLock.lock()
            self.frameRing.removeAll(keepingCapacity: false)
            self.pixelBufferLock.unlock()
            self.anchorSet = false
            self.formatDescription = nil
        }
    }

    /// Forward a control command to the connected iPhone (Mac → iPhone).  No-op
    /// when no ready connection exists.  Thread-safe — `NWConnection.send` is.
    func send(_ msg: ControlMessage) {
        queue.async { [weak self] in
            guard let self, let conn = self.connection, conn.state == .ready else { return }
            let data = msg.encodeAsPacket().encode()
            conn.send(content: data, completion: .idempotent)
        }
    }

    /// Tally cue helper — frames a `setCue` control message ("none" / "preview"
    /// / "program") so the iPhone shows its leading-edge tally stripe.  Sent on
    /// the same TCP control channel as every other command.
    func setCue(_ cue: String) {
        send(.setCue(cue))
    }

    /// Rename the advertised source (`src`) without tearing the service down.
    /// Re-advertises live so browsing iPhones see the new name.
    func rename(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.src = trimmed
            self.readvertise()
        }
    }

    func updateOrder(_ index: Int) {
        queue.async { [weak self] in
            guard let self, self.order != index else { return }
            self.order = index
            self.readvertise()
        }
    }

    /// Re-read the operator's playout-delay preset and apply it live.  Called by
    /// `BridgeChannel` when `delay` changes.  Re-anchors and drops the frames
    /// queued under the old depth (cleaner than re-timing them).
    func updateDelay(_ preset: LatencyPreset) {
        queue.async { [weak self] in
            guard let self else { return }
            let newValue = preset.seconds
            guard abs(newValue - self.bufferSeconds) > 0.0005 else { return }
            self.bufferSeconds = newValue
            self.anchorSet = false
            self.pixelBufferLock.lock()
            self.frameRing.removeAll(keepingCapacity: true)
            self.pixelBufferLock.unlock()
        }
    }

    /// Apply the receiver-password auth config live.  Snapshots the toggle +
    /// password onto `queue` (the verify path is queue-confined, so it never reads
    /// the channel's main-isolated state).  `disconnectNow` drops a currently-
    /// connected camera so a password change forces an immediate re-auth
    /// (revocation) — the camera then reconnects manually and re-authenticates.
    func updateAuth(require: Bool, password: String, disconnectNow: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.requireAuth = require
            self.authPassword = password
            guard disconnectNow, let conn = self.connection else { return }
            self.gracefulDrop(conn, reason: "auth config changed (revocation)")
        }
    }

    // MARK: - Listen (ephemeral port + Bonjour)

    private func startListening() {
        guard listener == nil else { return }   // idempotent

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        // SO_REUSEADDR — a fresh launch re-binds cleanly past a TIME_WAIT socket.
        params.allowLocalEndpointReuse = true

        // EPHEMERAL port — no explicit `on:`, so the OS picks a free port and
        // NWListener publishes the real bound port in its Bonjour record.  The
        // iPhone resolves host+port from the service, so any number of Bridges +
        // Studios + OBS plugins coexist on one LAN with zero collisions.
        let l: NWListener
        do {
            l = try NWListener(using: params)
        } catch {
            print("[BridgeReceiver \(src)] ❌ NWListener init failed: \(error)")
            return
        }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = self.listener?.port?.rawValue ?? 0
                print("[BridgeReceiver \(self.src)] ✅ listening on ephemeral port \(port)")
            case .failed(let err):
                print("[BridgeReceiver \(self.src)] ❌ listener failed: \(err)")
            case .cancelled:
                print("[BridgeReceiver \(self.src)] listener cancelled")
            default:
                break
            }
        }
        l.service = NWListener.Service(name: instanceName,
                                       type: "_airlive._tcp",
                                       txtRecord: txtRecord(occupied: false))
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
    }

    /// Build the Bonjour TXT (docs/MULTI-DEVICE-CHANNELS-SPEC.md §4).  `role` is
    /// `bridge` so a channels-aware iPhone can tell Bridge sources apart from
    /// Studio/OBS ones; everything else groups + identifies exactly as Studio.
    private func txtRecord(occupied: Bool) -> NWTXTRecord {
        var r = NWTXTRecord()
        r["v"]    = "1"
        r["role"] = "bridge"
        r["did"]  = identity.did
        r["dev"]  = identity.dev
        r["sid"]  = sid
        r["src"]  = src
        r["ord"]  = String(order)   // operator's Bridge order → iPhone sorts by this
        r["busy"] = occupied ? "1" : "0"
        return r
    }

    /// Republish the service with a fresh TXT (busy flip / rename / dev change).
    /// Same listener instance — only the advertised metadata changes.  On `queue`.
    private func updateOccupancyAdvertisement(occupied: Bool) {
        advertisedBusy = occupied
        listener?.service = NWListener.Service(name: instanceName,
                                               type: "_airlive._tcp",
                                               txtRecord: txtRecord(occupied: occupied))
    }

    /// Re-publish with the current name + order + last busy state (rename / order /
    /// dev change).  On `queue`.
    ///
    /// CRITICAL: never re-set `listener.service` while a connection is live.
    /// Re-registering the Bonjour record under a connected (or mid-handshake) iPhone
    /// churns its endpoint resolution → it drops the socket → FIN → reconnect loop
    /// (the "one frame → reconnect" bug; Studio forbids this too — spec §7).  The
    /// updated `src` / `order` are stored, so they flush on the next legitimate
    /// re-advertise: the `busy=0` flip in `updateOccupancyAdvertisement` at
    /// disconnect.  The busy-flip path (commit/disconnect) is the ONLY sanctioned
    /// mid-lifecycle service mutation and stays out of this guard.
    private func readvertise() {
        guard connection == nil else { return }
        listener?.service = NWListener.Service(name: instanceName,
                                               type: "_airlive._tcp",
                                               txtRecord: txtRecord(occupied: advertisedBusy))
    }

    // MARK: - Connection (one iPhone per channel; keep listening for reconnect)

    private func accept(_ conn: NWConnection) {
        // One iPhone per channel: reject newcomers while a connection is committed.
        if connection != nil {
            conn.cancel()
            return
        }
        // Anti-bruteforce: a source that just burned through its auth attempts is
        // refused outright (no challenge, no slot) until its ban expires.
        if isBanned(conn) {
            print("[BridgeReceiver \(src)] 🚫 refused banned source \(sourceKey(for: conn))")
            conn.cancel()
            return
        }
        // Dual-stack happy-eyeballs: one iPhone NWConnection opens a socket per
        // resolved address (IPv6 + IPv4); the FIRST to reach `.ready` becomes THE
        // connection, the rest are cancelled.  Don't guess which the iPhone keeps.
        pendingConnections.append(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                self.commitConnection(conn)
            case .cancelled, .failed:
                self.dropConnection(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    /// First candidate to `.ready` wins.  On `queue`.
    private func commitConnection(_ conn: NWConnection) {
        guard connection == nil else {
            if conn !== connection { conn.cancel() }
            return
        }
        connection = conn
        anchorSet = false                         // fresh stream → re-anchor PTS
        resetAuthState()                          // clean slate for this connection
        for other in pendingConnections where other !== conn {
            other.stateUpdateHandler = nil
            other.cancel()
        }
        pendingConnections.removeAll()
        receive(from: conn)
        // Auth ON → challenge first; the slot is NOT marked busy and the channel
        // is NOT surfaced as connected until the camera authorizes (STREAM-AUTH
        // §4: don't reserve the slot for an unauthenticated peer).  Auth OFF →
        // authorize immediately, i.e. exactly today's behavior.
        if effectiveAuthRequired {
            beginAuth(conn)
        } else {
            markAuthorized(conn)
        }
    }

    /// A candidate (or the committed connection) hit a terminal state.  On `queue`.
    private func dropConnection(_ conn: NWConnection) {
        pendingConnections.removeAll { $0 === conn }
        if connection === conn {
            handleDisconnect(conn, reason: "terminal state")
        }
    }

    /// Tear the active stream down but KEEP the listener running — the channel
    /// stays advertised (busy=0) so the iPhone can reconnect.  On `queue`.
    private func handleDisconnect(_ conn: NWConnection, reason: String) {
        guard connection === conn else { return }
        print("[BridgeReceiver \(src)] 🔌 disconnect (\(reason)) — clearing frame, busy=0")
        connection = nil
        resetAuthState()                          // drop any pending challenge/buffer
        updateOccupancyAdvertisement(occupied: false)
        teardownDecodeSession()
        pixelBufferLock.lock()
        frameRing.removeAll(keepingCapacity: true)
        pixelBufferLock.unlock()
        anchorSet = false
        formatDescription = nil
        publishConnected(false)
        publishSignalCleared()                    // UI returns to "no signal"
    }

    private func receive(from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self, weak conn] data, _, isDone, error in
            guard let self else { return }
            if let data, let conn {
                for packet in self.parser.append(data) { self.handle(packet, from: conn) }
            }
            if !isDone && error == nil {
                if let conn { self.receive(from: conn) }
            } else {
                // Only trip disconnect if THIS receive belonged to the CURRENT
                // connection — a stale dual-stack loser's in-flight receive can
                // fire isDone=true after the winner went `.ready`, and without
                // the identity guard it would flush the live stream.
                guard let conn, conn === self.connection else { return }
                let reason = error.map { "receive error \($0)" } ?? "peer closed (FIN)"
                self.handleDisconnect(conn, reason: reason)
            }
        }
    }

    // MARK: - Packet handling

    private func handle(_ packet: AirlivePacket, from conn: NWConnection) {
        // Ignore straggler bytes that aren't from the committed connection.
        guard conn === connection else { return }

        switch packet.type {
        // Auth packets are receiver→camera (3, 5) — never legitimately INBOUND.
        // A peer sending one (e.g. a hostile camera forging authResult{ok:true}
        // to skip the challenge) is a protocol violation → drop. (STREAM-AUTH §3
        // direction invariant: authorize ONLY on our own verify of a type-4.)
        case .authChallenge, .authResult:
            protocolViolation(conn, "inbound \(packet.type)")

        case .authResponse:
            handleAuthResponse(packet.payload, from: conn)

        case .formatDescription:
            if authorized {
                buildFormatDescription(from: packet.payload)
                forwardProgramFormat(packet.payload)   // raw SPS/PPS → relay passthrough
            } else if effectiveAuthRequired {
                pendingFormatPayload = packet.payload   // buffer latest; apply on authorize
            }

        case .sample:
            if authorized {
                decodeFrame(payload: packet.payload, packetTimestamp: packet.timestampMicros)
                forwardProgramSample(packet.payload, packet.timestampMicros)   // raw H.264 → relay passthrough
            }
            // PENDING-AUTH: samples are dropped until authorized.

        case .control:
            if authorized {
                handleControl(payload: packet.payload)
            }
            // PENDING-AUTH: control is dropped too (process ONLY authResponse).
        }
    }

    // MARK: - Receiver-password auth handshake

    /// Send the one challenge for this connection and arm the stall timer.  The
    /// nonce is single-use; `challengeNonce != nil` is the "awaiting response"
    /// state.  Called once per connection (STREAM-AUTH §3 invariant: exactly one
    /// challenge).
    private func beginAuth(_ conn: NWConnection) {
        let nonce = AirliveAuth.makeNonce()
        challengeNonce = nonce
        sendRaw(.authChallenge, payload: nonce, on: conn)
        armAuthStallTimer(conn)
        print("[BridgeReceiver \(src)] 🔒 auth challenge sent — awaiting response")
    }

    /// Verify a camera's `authResponse`.  Authorizes ONLY on a successful
    /// constant-time verify of THIS connection's outstanding nonce.
    private func handleAuthResponse(_ payload: Data, from conn: NWConnection) {
        guard !authorized else { protocolViolation(conn, "authResponse after authorized"); return }
        guard effectiveAuthRequired, let nonce = challengeNonce else {
            protocolViolation(conn, "unexpected authResponse"); return
        }
        // Length-check BEFORE verify (hardening rule): a non-32-byte tag is a
        // failure outright; never let a wrong length reach a compare.
        guard payload.count == AirliveAuth.tagLength else {
            registerAuthFailure(for: conn)
            failAuth(conn, reason: .authFailed)
            return
        }
        if AirliveAuth.verify(tag: payload, password: authPassword, nonce: nonce) {
            challengeNonce = nil                  // consume — strictly single-use
            clearAuthFailures(for: conn)
            sendAuthResult(.success, on: conn)
            markAuthorized(conn)
            print("[BridgeReceiver \(src)] 🔓 authorized")
        } else {
            registerAuthFailure(for: conn)
            failAuth(conn, reason: .authFailed)
            print("[BridgeReceiver \(src)] ⛔ auth failed (wrong password)")
        }
    }

    /// Clear a connection to stream: flip `authorized`, mark the slot busy, surface
    /// it as connected, and apply any format buffered during PENDING-AUTH.  The
    /// ONLY place `authorized` is set true.
    private func markAuthorized(_ conn: NWConnection) {
        authorized = true
        challengeNonce = nil
        cancelAuthStallTimer()
        updateOccupancyAdvertisement(occupied: true)
        publishConnected(true)
        if let fmt = pendingFormatPayload {
            pendingFormatPayload = nil
            buildFormatDescription(from: fmt)
            forwardProgramFormat(fmt)   // relay needs the buffered SPS/PPS too,
                                        // else OBS can't decode until the next IDR
        }
    }

    /// Forward a RAW program payload to the channel's relay taps ON MAIN.  The taps
    /// (`onProgramFormat` / `onProgramSample`) are written by `BridgeModel` on the
    /// main thread, so they must be read there — mirrors the `onProgramFrame` hop in
    /// `present()`.  `handle()` runs on `queue` (background), so the direct call was
    /// a data race.  The relay re-dispatches to its own queue immediately, so the
    /// per-packet main hop is just a pointer handoff.
    private func forwardProgramFormat(_ payload: Data) {
        DispatchQueue.main.async { [weak self] in self?.channel?.onProgramFormat?(payload) }
    }
    private func forwardProgramSample(_ payload: Data, _ timestampMicros: Int64) {
        DispatchQueue.main.async { [weak self] in self?.channel?.onProgramSample?(payload, timestampMicros) }
    }

    /// Reject this connection: send the failure result, then close gracefully so
    /// the result actually flushes before the FIN.
    private func failAuth(_ conn: NWConnection, reason: AuthReason) {
        sendAuthResult(.failure(reason), on: conn)
        gracefulDrop(conn, reason: "auth \(reason.rawValue)")
    }

    /// A peer broke the protocol — close gracefully.  (We don't reward a forged
    /// packet with a slot; the connection is torn down.)
    private func protocolViolation(_ conn: NWConnection, _ what: String) {
        print("[BridgeReceiver \(src)] ⚠️ protocol violation: \(what) — dropping")
        gracefulDrop(conn, reason: "protocol violation")
    }

    /// Clean up channel state for `conn` and close it with a graceful FIN (so any
    /// queued `authResult` flushes first — `cancel()` waits for pending sends).
    private func gracefulDrop(_ conn: NWConnection, reason: String) {
        if connection === conn {
            handleDisconnect(conn, reason: reason)   // clears state, busy=0
        } else {
            pendingConnections.removeAll { $0 === conn }
        }
        conn.stateUpdateHandler = nil               // we've already cleaned up
        conn.cancel()
    }

    private func resetAuthState() {
        authorized = false
        challengeNonce = nil
        pendingFormatPayload = nil
        cancelAuthStallTimer()
    }

    // MARK: Auth — stall timer

    /// FIN a connection that never sends a valid response in `authStallTimeout`.
    private func armAuthStallTimer(_ conn: NWConnection) {
        cancelAuthStallTimer()
        let work = DispatchWorkItem { [weak self, weak conn] in
            guard let self, let conn, conn === self.connection, !self.authorized else { return }
            print("[BridgeReceiver \(self.src)] ⏱️ auth stall — no valid response in \(Int(self.authStallTimeout))s")
            self.failAuth(conn, reason: .authRequired)
        }
        authStallWork = work
        queue.asyncAfter(deadline: .now() + authStallTimeout, execute: work)
    }

    private func cancelAuthStallTimer() {
        authStallWork?.cancel()
        authStallWork = nil
    }

    // MARK: Auth — anti-bruteforce (per source)

    private func sourceKey(for conn: NWConnection) -> String {
        if case let .hostPort(host, _) = conn.endpoint { return "\(host)" }
        return "\(conn.endpoint)"
    }

    private func isBanned(_ conn: NWConnection) -> Bool {
        guard let entry = authBans[sourceKey(for: conn)] else { return false }
        return entry.banUntil > CACurrentMediaTime()
    }

    private func registerAuthFailure(for conn: NWConnection) {
        let key = sourceKey(for: conn)
        var entry = authBans[key] ?? (failures: 0, banUntil: 0)
        entry.failures += 1
        if entry.failures >= authMaxFailures {
            // Exponential backoff past the threshold: base × 2^over, capped.
            let over = Double(entry.failures - authMaxFailures)
            let ban = Swift.min(authBanMax, authBanBase * pow(2.0, over))
            entry.banUntil = CACurrentMediaTime() + ban
            print("[BridgeReceiver \(src)] 🚫 \(key) banned \(Int(ban))s after \(entry.failures) failed attempts")
        }
        authBans[key] = entry
    }

    private func clearAuthFailures(for conn: NWConnection) {
        authBans[sourceKey(for: conn)] = nil
    }

    // MARK: Auth — wire send helpers

    private func sendRaw(_ type: AirlivePacket.PacketType, payload: Data, on conn: NWConnection) {
        conn.send(content: AirlivePacket(type: type, payload: payload).encode(),
                  completion: .idempotent)
    }

    private func sendAuthResult(_ result: AuthResult, on conn: NWConnection) {
        sendRaw(.authResult, payload: result.encoded(), on: conn)
    }

    private func handleControl(payload: Data) {
        guard let msg = ControlMessage.decode(from: payload) else { return }
        switch msg.type {
        case "state":
            if let snap = msg.state { publishRemote(snap) }
        default:
            // Bridge is the COMMAND sender for set-verbs, not the receiver —
            // ignore unknown inbound control messages.
            break
        }
    }

    /// Extract SPS/PPS from the format-description payload and build a
    /// `CMVideoFormatDescription`.  Rebuild the decode session only on a REAL
    /// format change — the iPhone re-sends the format on every keyframe as a
    /// mid-stream-join safety net, and wiping on every GOP strobes the picture.
    private func buildFormatDescription(from data: Data) {
        let params = parseParameterSets(from: data)
        guard params.count >= 2,
              let fmt = makeFormatDescription(sps: params[0], pps: params[1]) else { return }

        let changed: Bool = {
            guard let existing = formatDescription else { return false }
            return !CMFormatDescriptionEqual(fmt, otherFormatDescription: existing)
        }()
        if changed {
            pixelBufferLock.lock(); frameRing.removeAll(keepingCapacity: true); pixelBufferLock.unlock()
            anchorSet = false
        }
        formatDescription = fmt
    }

    /// Split the format payload (a sequence of `[2-byte BE length][bytes]`
    /// parameter sets) into raw `[UInt8]` arrays.  Stops cleanly at the first
    /// truncated record so a partial buffer never reads past its end.
    private func parseParameterSets(from data: Data) -> [[UInt8]] {
        var params: [[UInt8]] = []
        var offset = 0
        while offset + 2 <= data.count {
            let hi = Int(data[data.index(data.startIndex, offsetBy: offset)])
            let lo = Int(data[data.index(data.startIndex, offsetBy: offset + 1)])
            let len = (hi << 8) | lo
            offset += 2
            guard offset + len <= data.count else { break }
            let s = data.index(data.startIndex, offsetBy: offset)
            let e = data.index(data.startIndex, offsetBy: offset + len)
            params.append([UInt8](data[s..<e]))
            offset += len
        }
        return params
    }

    /// Build a `CMVideoFormatDescription` from an SPS/PPS pair.  Each parameter
    /// set is held by ONE `withUnsafeBufferPointer` whose base pointer + count go
    /// straight into the parallel pointer/size arrays, so every raw pointer
    /// stays valid for the single `CMVideoFormatDescriptionCreateFromH264…` call
    /// nested inside both scopes — no pointer can outlive its backing array.
    private func makeFormatDescription(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var fmt: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { spsBuf in
            pps.withUnsafeBufferPointer { ppsBuf in
                guard let spsBase = spsBuf.baseAddress, let ppsBase = ppsBuf.baseAddress else { return }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                pointers.withUnsafeBufferPointer { ptrsBuf in
                    sizes.withUnsafeBufferPointer { sizesBuf in
                        _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: nil,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrsBuf.baseAddress!,
                            parameterSetSizes: sizesBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fmt
                        )
                    }
                }
            }
        }
        return fmt
    }

    // MARK: - Decode + anti-drift PTS anchoring

    private func decodeFrame(payload: Data, packetTimestamp: Int64) {
        guard let fmt = formatDescription else { return }
        // A valid H.264 access unit is never empty, but a truncated/corrupt
        // packet can pass the parser's length guard with length 0 and then crash
        // on `baseAddress!` below (`Data.withUnsafeBytes` yields a nil base for
        // an empty buffer).  Drop the empty access unit instead.
        guard !payload.isEmpty else { return }

        // packetTimestamp = microseconds on the iPhone's clock.  Translate to a
        // Mac-clock playout deadline (anchor + ΔPTS + bufferSeconds), stamp it
        // as the sample PTS, and let the jitter ring hold the decoded frame
        // until that time — so network jitter becomes queue depth, not on-screen
        // lag.  Skew tracking (lower-envelope minimum) corrects crystal drift.
        let iphonePTS = TimeInterval(packetTimestamp) / 1_000_000.0
        let macNow    = CACurrentMediaTime()
        let scheduledMacTime: TimeInterval
        if anchorSet {
            let iphoneElapsed = iphonePTS - anchorIphonePTS
            let macElapsed    = macNow - (anchorMacTime - bufferSeconds)
            let delta         = macElapsed - iphoneElapsed

            if abs(delta - skewOffset) > skewJumpThreshold {
                // Discontinuity (iPhone restart / clock jump) — re-anchor.  NOT
                // mere network lateness (the ring handles that without touching
                // the anchor; re-anchoring on late frames ratchets latency up).
                anchorIphonePTS = iphonePTS
                anchorMacTime   = macNow + bufferSeconds
                skewOffset      = 0
                skewWindow.removeAll(keepingCapacity: true)
                pixelBufferLock.lock(); frameRing.removeAll(keepingCapacity: true); pixelBufferLock.unlock()
                scheduledMacTime = anchorMacTime
            } else {
                skewWindow.append((macNow, delta))
                let cutoff = macNow - skewWindowSeconds
                while let first = skewWindow.first, first.t < cutoff {
                    skewWindow.removeFirst()
                }
                let windowMin = skewWindow.min(by: { $0.delta < $1.delta })?.delta ?? delta
                skewOffset += skewSlewGain * (windowMin - skewOffset)
                scheduledMacTime = anchorMacTime + iphoneElapsed + skewOffset
            }
        } else {
            anchorIphonePTS  = iphonePTS
            anchorMacTime    = macNow + bufferSeconds
            skewOffset       = 0
            skewWindow.removeAll(keepingCapacity: true)
            anchorSet        = true
            scheduledMacTime = anchorMacTime
        }

        // ── Build the compressed sample buffer (carries the playout PTS) ─────
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return }

        // `baseAddress` is guaranteed non-nil here (the `payload.isEmpty` guard
        // at the top of this method already dropped the only case that yields a
        // nil base), but bind it safely rather than force-unwrap so a future
        // edit can't reintroduce the empty-payload crash.
        let copied: Bool = payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0,
                                                 dataLength: payload.count) == noErr
        }
        guard copied else { return }

        var timing = CMSampleTimingInfo(
            duration:              CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: scheduledMacTime, preferredTimescale: 90_000),
            decodeTimeStamp:       .invalid
        )
        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: nil, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        decompress(sampleBuffer: sampleBuffer, format: fmt)
    }

    /// Decompress one sample buffer to a BGRA `CVPixelBuffer`.  BGRA + IOSurface
    /// is the cheapest handoff for downstream encoders (NDI / SRT / RTSP) and
    /// renders directly in the SwiftUI preview.  Session rebuilt on format change.
    private func decompress(sampleBuffer: CMSampleBuffer, format: CMVideoFormatDescription) {
        if decompressionFormat == nil ||
           !CMFormatDescriptionEqual(decompressionFormat, otherFormatDescription: format) {
            if let old = decompressionSession { VTDecompressionSessionInvalidate(old) }
            decompressionSession = nil

            let outputAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
            var callback = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: { (refCon, _, status, _, imageBuffer, pts, _) in
                    guard status == noErr, let imageBuffer, let refCon else { return }
                    let receiver = Unmanaged<BridgeChannelReceiver>.fromOpaque(refCon).takeUnretainedValue()
                    receiver.ingestDecoded(imageBuffer, playout: CMTimeGetSeconds(pts))
                },
                decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            var newSession: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: format,
                decoderSpecification: nil,
                imageBufferAttributes: outputAttrs as CFDictionary,
                outputCallback: &callback,
                decompressionSessionOut: &newSession
            )
            guard status == noErr, let newSession else {
                print("[BridgeReceiver \(src)] VTDecompressionSessionCreate failed: \(status)")
                return
            }
            decompressionSession = newSession
            decompressionFormat  = format
        }

        guard let session = decompressionSession else { return }
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        // Loud-fail (rate-limited) — a non-noErr submit means a corrupt NAL or a
        // wedged session; without the log the operator just sees a frozen tile.
        if status != noErr {
            let now = CACurrentMediaTime()
            if now - lastDecodeErrorLog > 1.0 {
                lastDecodeErrorLog = now
                print("[BridgeReceiver \(src)] ⚠️ VTDecompressionSessionDecodeFrame failed: \(status)")
            }
        }
    }

    private func teardownDecodeSession() {
        guard let s = decompressionSession else { return }
        // Drain in-flight async frames BEFORE invalidating, while self is alive,
        // or a straggler decode callback fires on freed memory.
        VTDecompressionSessionWaitForAsynchronousFrames(s)
        VTDecompressionSessionInvalidate(s)
        decompressionSession = nil
        decompressionFormat  = nil
    }

    // MARK: - Jitter ring (playout-deadline scheduling)

    /// Ring cap in frames — `bufferSeconds` worth at 60 fps plus a small margin,
    /// floored at 2 so even Lowest (0 ms) tolerates one decode in flight.
    private var maxRingFrames: Int {
        Swift.max(2, Int((bufferSeconds * 60.0).rounded(.up)) + 2)
    }

    /// Enqueue a decoded frame and schedule its promotion at the playout
    /// deadline.  Lowest (0 ms) promotes inline (the fast baseline — no timer
    /// hop); buffered mode arms a one-shot.  Called on the VT decode-callback
    /// thread.
    private func ingestDecoded(_ buffer: CVPixelBuffer, playout: TimeInterval) {
        pixelBufferLock.lock()
        frameRing.append((buffer, playout))
        if frameRing.count > maxRingFrames {
            frameRing.removeFirst(frameRing.count - maxRingFrames)   // overrun drop
        }
        pixelBufferLock.unlock()

        let delay = playout - CACurrentMediaTime()
        if delay <= 0.001 {
            // Lowest (0 ms) path: promote INLINE on the VT decode-callback
            // thread (no timer hop).  `promoteDue` therefore runs on TWO
            // threads — this VT thread (inline) and `queue` (the asyncAfter
            // timer).  Both touch `frameRing` only under `pixelBufferLock`, and
            // `present` hops to main for everything else, so this is race-free.
            // ⚠️ Any new `queue`-confined state read inside `promoteDue` MUST be
            // guarded the same way — it can be entered straight off the VT
            // thread here without a `queue` hop.
            promoteDue()
        } else {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.promoteDue() }
        }
    }

    /// Promote the freshest now-due frame: enqueue it into the channel's display
    /// layer (when `previewEnabled`) and forward it to every output.
    private func promoteDue() {
        let now = CACurrentMediaTime()
        var promoted: CVPixelBuffer?
        pixelBufferLock.lock()
        while let first = frameRing.first, first.playout <= now {
            promoted = first.buffer
            frameRing.removeFirst()
        }
        pixelBufferLock.unlock()

        guard let promoted else { return }
        present(promoted)
    }

    /// Single presentation point.  Two jobs:
    ///
    ///   1. MIRROR (per-frame pixels) — `channel.publishFrame(buffer)`, called
    ///      right here on the present thread (OFF main): it stores the latest
    ///      buffer and posts `newFrameNotification`, so every MirrorVideoView tile
    ///      points its own `CALayer.contents` at the SAME IOSurface-backed buffer.
    ///      One decode feeds any number of tiles (multiview + Program + Preview),
    ///      and a busy main thread can never freeze the preview.
    ///   2. OUTPUT fan-out + the published "no signal" gate — these touch
    ///      `@Published` / main-isolated state, so they hop to main.  The buffer is
    ///      IOSurface-backed, so handing it across threads is a retained-CF pass,
    ///      not a copy.
    private func present(_ buffer: CVPixelBuffer) {
        let timeNs = UInt64(CACurrentMediaTime() * 1_000_000_000.0)

        // 1. Mirror — off main.
        channel?.publishFrame(buffer)

        // 2. Outputs + gate — on main.
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel else { return }
            if !self.didLogFirstFrame {
                self.didLogFirstFrame = true
                print("[BridgeReceiver \(self.src)] ✅ first frame presented")
            }
            // Program tap: when this channel is the program source, the model's
            // closure forwards the frame to the program output(s).  nil otherwise.
            channel.onProgramFrame?(buffer, timeNs)
            // Once-per-session: flip the published "no signal" gate on the first
            // frame only (guarded — never a per-frame published write).
            if channel.latestFrame == nil { channel.latestFrame = buffer }
        }
    }

    // MARK: - Publish to the owning channel (main queue)

    private func publishConnected(_ connected: Bool) {
        DispatchQueue.main.async { [weak self] in self?.channel?.isConnected = connected }
    }

    /// Disconnect / format-change cleanup: clear the published `latestFrame` gate
    /// (returns the UI to "no signal") and blank every mirror tile to black.
    private func publishSignalCleared() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel else { return }
            channel.latestFrame = nil
            channel.publishFrame(nil)   // blank every mirror to black
        }
    }

    private func publishRemote(_ snapshot: StateSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel else { return }
            channel.remote = snapshot
            channel.outputRotation = snapshot.outputRotation   // mirrors read this off-main
        }
    }
}
