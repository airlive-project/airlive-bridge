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

    // ── Program-source gate (H1) ──────────────────────────────────────────
    /// True when THIS channel is the program source (set by the model via
    /// `setProgramSource`, hopped onto `queue`).  Gates the per-frame program taps so a
    /// NON-program channel does ZERO per-frame `DispatchQueue.main.async` hops — the big
    /// win at 5-camera scale, where 4/5 of the hops were no-ops finding a nil closure.
    private var isProgramSource = false
    /// One main hop per (re)connect to flip the published "no signal" gate + log the
    /// first frame; after that a non-program channel never hops on the frame path.
    private var didFlipSignalGate = false

    // ── Link silence (signal lost / resumed) ──────────────────────────────
    /// How long the camera may say nothing before the link counts as silent (operator,
    /// 2026-10-16). A camera that loses its route sends nothing until it is back (camera 52d2c7b:
    /// encoder paused, state blocked); a Wi-Fi stall that keeps the route, or a camera pausing its
    /// encoder (a 4K record bump, a lens change), can be quiet that long too. Either way no
    /// picture is arriving, which is exactly what "No signal" says. 1.5 s, not 1.0 (operator +
    /// camera chat, 2026-11-03): a 5x lens switch keeps the camera quiet for up to ~1.0 s between
    /// packets and cannot be made faster, so 1.0 flashed "No signal" on a healthy switch.
    static let silenceThreshold: CFTimeInterval = 1.5
    /// One frame at the wire's 30 fps (CLAUDE.md: the live wire is always 30).
    private static let resumeSlack: Double = 1.0 / 30.0
    /// After a silence, how far the fastest arrival of one second may differ from the second
    /// before for the path to count as settled (two frames: Wi-Fi's clumps move single arrivals
    /// by ~100 ms, never the fastest one). A drain makes it fall by seconds, TCP restarting
    /// after the outage makes it rise; only a settled path that is still late is a slower path.
    private static let resumeSettleTolerance: Double = 2.0 / 30.0
    private static let resumeBucketSeconds: Double = 1.0
    /// How often the silence is checked while a camera is connected, so a lost signal shows
    /// within 1.5-1.75 s. Runs only while a connection is authorised.
    private static let silenceCheckInterval: DispatchTimeInterval = .milliseconds(250)
    /// When the committed connection last delivered bytes. On `queue`.
    private var lastInboundAt: CFTimeInterval = 0
    /// The link has been silent past the threshold and no byte has come since. On `queue`.
    private var linkSilent = false
    private var silenceTimer: DispatchSourceTimer?
    /// The camera's last word on whether it sends video (its state snapshot). A Control-only
    /// camera is quiet by nature, so its silence is neither logged nor shown. On `queue`.
    private var peerSendsVideo = true
    /// Just back from silence: what the phone's socket held when the route went is delivered
    /// first (old frames, up to ~140 KB), then a keyframe. The old frames are dropped until that
    /// keyframe, so neither the preview nor any output replays a moment that already passed.
    /// The keyframe is recognised by its own IDR slice: the camera sends its FORMAT only once per
    /// connection and again only when a receiver asks for a keyframe (camera CaptureEngine,
    /// `lastFormatDescSentAt`), so on a plain return no format packet comes at all. On `queue`.
    private var awaitingResumeKeyframe = false
    /// When the camera spoke again after a silence - for the "picture back after N ms" log line,
    /// which shows how long the wait for its keyframe took. On `queue`.
    private var resumedAt: CFTimeInterval = 0
    /// The camera's capture PTS of the last sample before a silence and of the first after it,
    /// printed with the silence lines so the camera side can match them against what its socket
    /// accepted (where a backlog sat: our queue or the kernel's). On `queue`.
    private var lastSamplePTSMicros: Int64 = -1
    private var logFirstSampleAfterSilence = false
    /// While the picture waits: the least late arrival of the current second, of the second
    /// before, and whether the last two completed seconds agreed (`resumeSettleTolerance`).
    /// On `queue`.
    private var resumeBucketStart: CFTimeInterval = 0
    private var resumeBucketFloor = Double.infinity
    private var resumePreviousFloor = Double.infinity
    private var resumePathSettled = false
    /// When the picture started waiting (the FIRST silence of a run: a link that drops again
    /// before the picture is back does not restart it), and the last keyframe this wait asked for.
    /// On `queue`.
    private var resumeWaitStartedAt: CFTimeInterval = 0
    private var lastResumeKeyframeRequestAt: CFTimeInterval = 0
    /// Keyframes asked for while the picture waits: at most one a second. A keyframe is the
    /// heaviest frame, and this is exactly when the link is weak - asking ~3 a second (the
    /// spacing the camera allows) loaded the shared Wi-Fi of every camera (reviews, 2026-11-03).
    private static let resumeKeyframeInterval: CFTimeInterval = 1.0
    /// After this long waiting, the next keyframe brings the picture back even if the path never
    /// settled (a weak link may never), on a new timeline, logged. Safe since the camera keeps at
    /// most ~1 s of backlog: no stale keyframe can still be draining this late.
    private static let resumeGiveUpSeconds: CFTimeInterval = 4.0

    // ── Remote-snapshot coalescer (H2) ────────────────────────────────────
    /// Coalesce the camera's `state` snapshots to ~1 Hz before touching the main-isolated
    /// @Published `remote` (don't trust the phone's own throttle; protect main if it ever
    /// sends faster).  Leading-edge immediate, then at most one push per window.  All three
    /// fields are queue-confined.
    private var pendingRemote: StateSnapshot?
    private var remoteFlushScheduled = false
    private let remoteCoalesceSeconds: Double = 1.0

    /// M2: a dual-stack candidate that never reaches `.ready` is dropped after this, so a
    /// half-open straggler can't sit in `pendingConnections` forever.
    private let candidateReadyTimeout: TimeInterval = 10

    private let parser = PacketParser()
    private var formatDescription: CMVideoFormatDescription?

    /// Serial work queue — listener, accept, receive, parse, decode-submit, and
    /// jitter-ring scheduling all run here.  `.userInteractive` because late
    /// video is worse than a busy core (this is a live monitor).
    private let queue: DispatchQueue

    // ── Jitter buffer (operator-chosen playout delay) ─────────────────────

    /// EFFECTIVE playout depth (seconds) = `basePresetSeconds` + `extraDelaySeconds`.
    /// 0 (Lowest, no extra) = promote on decode; >0 = hold frames in `frameRing` until
    /// their playout deadline.  Re-derived live on a preset OR extra-delay change.
    private var bufferSeconds: Double
    /// The `LatencyPreset`'s coarse base (set by `updateDelay`).
    private var basePresetSeconds: Double
    /// The operator's precise ADDITIONAL ms (channel gear → "Additional delay"), as
    /// seconds (set by `updateExtraDelay`).  Added on top of the preset base.
    private var extraDelaySeconds: Double = 0

    // ── Fixed playout delay (operator, 2026-11-02: a delay that can grow mid-show is why
    // Screen Mirroring was not enough) ─────────────────────────────────────────────────────
    // A frame plays at: its capture time on the phone + the fastest network path + `bufferSeconds`.
    // The fastest path is MEASURED once, in the first `calibrationSeconds` after (re)anchoring, and
    // then held: afterwards it may move only as fast as two crystals can drift apart
    // (`maxDriftRate`, in either direction), never with the network. So a slower Wi-Fi spell makes
    // frames late - they go out at once and the outputs repeat the last picture - but never
    // stretches the delay, and a faster one only makes frames wait longer in the ring (more margin)
    // instead of shrinking the delay with a jump (operator, 2026-11-03: the delay stays what it
    // locked at for the whole show). Every 20 ms the schedule drifts from the lock is logged.
    // Re-anchored only on a real break - a new stream, a delay-setting change, a picture that
    // comes back after silence on a slower path, or a path proven faster than the margin the ring
    // holds (`aheadReanchorThreshold`) - each one logged. A silence alone keeps the timeline: same
    // connection, same clocks.
    private var anchorMacTime: TimeInterval = 0       // arrival of the anchor frame
    private var anchorIphonePTS: TimeInterval = 0     // its capture time on the phone
    private var anchorSet = false
    /// Why the next anchor is taken: printed with it.
    private var anchorReason = "new stream"
    /// The fastest path, relative to the anchor frame's own trip (negative = faster than it).
    private var skewOffset: Double = 0
    private var calibratingUntil: TimeInterval = 0
    private var playoutLocked = false
    private var lastSkewUpdate: TimeInterval = 0
    /// The current spell of frames missing their slot (`noteTimeliness`): when it began (0 = none),
    /// the last late frame, and the worst lateness. On `queue`.
    private var lateSpellStart: TimeInterval = 0
    private var lateSpellLastLate: TimeInterval = 0
    private var lateSpellWorst: Double = 0
    private var lateSpellFrames = 0
    /// On-time frames for this long close a late spell: two of the once-a-second Wi-Fi pauses,
    /// so one spell is one pair of lines, not a pair per pause.
    private static let onTimeConfirmSeconds: TimeInterval = 2.0
    /// `skewOffset` at the lock, and where it was at the last "schedule moved" line.
    private var lockedSkew: Double = 0
    private var lastLoggedSkew: Double = 0
    /// The drift a "schedule moved" line is printed for: under one frame at 30 fps, and at most
    /// one line per 100 s even at the full `maxDriftRate`.
    private static let skewLogStep: Double = 0.020
    private var skewWindow: [(t: TimeInterval, delta: Double)] = []
    /// Long enough to see the fastest path through the once-a-second Wi-Fi pauses.
    private static let calibrationSeconds: Double = 2.0
    /// The window the drift follower looks at once locked.
    private static let driftWindowSeconds: Double = 10.0
    /// 200 ppm = 0.2 ms per second: several times any real phone-vs-Mac crystal drift (tens of
    /// ppm), far below any network change, so the delay cannot follow the network.
    private static let maxDriftRate: Double = 200e-6
    /// Once locked, a frame up to this much EARLIER than the schedule just waits longer in the
    /// ring. More than this and the calibration missed the real path (or the phone's clock moved):
    /// the frames would pile up past the ring, so the timeline is taken again, logged. Late frames
    /// need nothing: they play at once.
    private static let aheadReanchorThreshold: Double = 0.25

    /// PTS-ordered pending frames awaiting their playout deadline (ascending by
    /// `playout`).  Guarded by `pixelBufferLock`; bounded by `ringCapacity`.
    private var frameRing: [(buffer: CVPixelBuffer, playout: TimeInterval)] = []
    /// See `ringCapacity(for:)`. Guarded by `pixelBufferLock`: the VT callback reads it.
    private var ringCapacity = 2
    private let pixelBufferLock = NSLock()

    // ── Decode ────────────────────────────────────────────────────────────
    private var decompressionSession: VTDecompressionSession?
    private var decompressionFormat: CMVideoFormatDescription?
    private var lastDecodeErrorLog: TimeInterval = 0
    /// Decode failures not printed since `lastDecodeErrorLog` (rate limit). On `queue`.
    private var suppressedDecodeErrors = 0
    private static let decodeErrorLogInterval: TimeInterval = 1.0
    private var didLogFirstFrame = false // one-shot preview diagnostic
    private var didLogFirstState = false // one-shot control-state diagnostic (lens list arrival)

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
    /// The camera's one-shot `hello` (PROTOCOL-COMPAT-SPEC §2).  nil = legacy peer
    /// (`proto=1, caps=[]`) — a camera that predates the hello verb never sends one.
    /// Snapshotted ONCE per connection (same discipline as `wireIsLive`); cleared on
    /// disconnect.  Gate any NEW verb/packet type on `peerCaps(...)`, never on version
    /// compares — the ints exist only for the update-prompt UX.  Queue-confined.
    private var peerHello: HelloMessage?
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

    /// Control-side of a combined "Screen Mirroring + Remote Control" channel: this ARLV
    /// receiver carries ONLY control (the channel's video is its AirPlay side).  So it (a) tells
    /// the camera to go CONTROL-ONLY (video encoder off) on connect, and (b) publishes control
    /// state to `remote` / `controlConnected` WITHOUT touching the video state
    /// (`isConnected` / `latestFrame` / mirror) the AirPlay receiver owns.  The camera honours
    /// `setDeliveryMode` and remembers it across reconnects (sticky).
    private let controlSide: Bool

    // MARK: - Init / deinit

    init(channel: BridgeChannel, order: Int = 0, identity: BridgeIdentity = .shared,
         controlSide: Bool = false) {
        self.channel      = channel
        self.channelID    = channel.id
        self.controlSide  = controlSide
        self.identity     = identity
        self.sid          = channel.id.uuidString
        self.src          = channel.name
        self.order        = order   // so the FIRST Bonjour advert already has the right ord
        self.instanceName = "Airlive \(channel.id.uuidString.prefix(8))"
        self.basePresetSeconds = channel.delay.seconds
        self.extraDelaySeconds = Swift.max(0, Double(channel.extraDelayMs) / 1000.0)
        self.bufferSeconds = self.basePresetSeconds + self.extraDelaySeconds
        self.ringCapacity = Self.ringCapacity(for: self.bufferSeconds)
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
            self.silenceTimer?.cancel()
            self.silenceTimer = nil
            self.pendingConnections.forEach { $0.cancel() }
            self.pendingConnections.removeAll()
            self.teardownDecodeSession()
            self.pixelBufferLock.lock()
            self.frameRing.removeAll(keepingCapacity: false)
            self.pixelBufferLock.unlock()
            self.reanchor("new stream")
            self.formatDescription = nil
        }
    }

    /// Forward a control command to the connected iPhone (Mac → iPhone).  No-op
    /// when no ready connection exists.  Thread-safe — `NWConnection.send` is.
    func send(_ msg: ControlMessage) {
        queue.async { [weak self] in
            guard let self else { return }
            if msg.type == "forceKeyframe" { return self.requestKeyframe() }
            self.sendNow(msg)
        }
    }

    /// On `queue`.
    private func sendNow(_ msg: ControlMessage) {
        guard let conn = connection, conn.state == .ready else { return }
        conn.send(content: msg.encodeAsPacket().encode(), completion: .idempotent)
    }

    // ── Keyframe requests, spaced the way the camera accepts them ─────────────────
    /// The camera honours a `forceKeyframe` at most once per 0.25 s and silently IGNORES one that
    /// comes sooner (camera CaptureEngine `minForceKeyframeInterval`). Two parts of the Bridge can
    /// ask within that window - this receiver when a silent camera speaks again, and the program
    /// routing when the passthrough outputs switch back to that camera - and the ignored one was
    /// the one SRT / RTSP were waiting for (up to the camera's 15 s keyframe interval). So a
    /// request that would land inside the window is not sent and lost: it is sent once, at the
    /// first moment the camera will take it. A margin above 0.25 s covers network jitter.
    private static let keyframeRequestSpacing: CFTimeInterval = 0.35
    private var lastKeyframeRequestAt: CFTimeInterval = 0   // on `queue`
    private var keyframeRequestPending = false               // on `queue`

    /// While the picture waits after a silence: `requestKeyframe`, at most once per
    /// `resumeKeyframeInterval`. On `queue`.
    private func requestResumeKeyframe() {
        let now = CACurrentMediaTime()
        guard now - lastResumeKeyframeRequestAt >= Self.resumeKeyframeInterval else { return }
        lastResumeKeyframeRequestAt = now
        requestKeyframe()
    }

    /// On `queue`.
    private func requestKeyframe() {
        let wait = lastKeyframeRequestAt + Self.keyframeRequestSpacing - CACurrentMediaTime()
        guard wait > 0 else {
            lastKeyframeRequestAt = CACurrentMediaTime()
            return sendNow(.forceKeyframe())
        }
        guard !keyframeRequestPending else { return }   // one already waiting covers this one
        keyframeRequestPending = true
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.keyframeRequestPending = false
            self.lastKeyframeRequestAt = CACurrentMediaTime()
            self.sendNow(.forceKeyframe())
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
            self.basePresetSeconds = preset.seconds
            self.applyEffectiveBufferLocked()
        }
    }

    /// Precise ADDITIONAL delay (ms) on top of the preset (channel gear).  Re-derives the
    /// effective playout depth and re-anchors, exactly like a preset change.
    func updateExtraDelay(_ ms: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.extraDelaySeconds = Swift.max(0, Double(ms) / 1000.0)
            self.applyEffectiveBufferLocked()
        }
    }

    /// On `queue`: set `bufferSeconds = base + extra`; if it really changed, re-anchor and
    /// drop frames queued under the old depth (cleaner than re-timing them).
    ///
    /// The decoder is drained FIRST: a frame still decoding carries its old-delay playout time
    /// and would land at the front of the emptied ring, holding every new frame behind it - a
    /// 5 s -> 0.5 s change froze the picture for 4.5 s (swift review, 2026-11-03). Waiting here
    /// is safe: the decode callback never blocks on `queue` (it only takes `pixelBufferLock`).
    private func applyEffectiveBufferLocked() {
        let newValue = basePresetSeconds + extraDelaySeconds
        guard abs(newValue - bufferSeconds) > Self.delayChangeEpsilon else { return }
        bufferSeconds = newValue
        reanchor("delay setting changed")
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        pixelBufferLock.lock()
        frameRing.removeAll(keepingCapacity: true)
        ringCapacity = Self.ringCapacity(for: newValue)
        pixelBufferLock.unlock()
    }

    /// Half a millisecond: below the 1 ms step of the delay field, so only a real change counts.
    private static let delayChangeEpsilon: Double = 0.0005

    /// `bufferSeconds` plus the margin a faster-than-locked path may add (`aheadReanchorThreshold`),
    /// at 60 fps (the most a camera sends), plus one decode in flight and one being promoted.
    private static func ringCapacity(for bufferSeconds: Double) -> Int {
        Int(((bufferSeconds + aheadReanchorThreshold) * 60.0).rounded(.up)) + 2
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
            self.authBans.removeAll()   // password change ⇒ clean slate (matches Studio)
            guard disconnectNow, let conn = self.connection else { return }
            self.gracefulDrop(conn, reason: "auth config changed (revocation)")
        }
    }

    // MARK: - Listen (ephemeral port + Bonjour)

    private func startListening() {
        guard listener == nil else { return }   // idempotent

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Dead-peer detection: a phone POWERED OFF mid-stream (or walking out of Wi-Fi range) never
        // sends a FIN, so without probes the committed connection stays "alive" FOREVER - the slot
        // reads busy, the TXT advertises busy=1, and the returning phone can't reconnect to its own
        // channel.  Keepalive reaps it and `handleDisconnect` frees the slot + re-advertises busy=0.
        //
        // The numbers were 5 + 2×3 ≈ 11 s, and that was wrong twice over (field, 2026-09-19):
        //
        //   • 11 s of silence is not proof of death.  Real Wi-Fi hands you multi-second gaps for
        //     ordinary reasons - reassociation, a radio leaving power-save, an access point
        //     buffering for a sleeping client - and we were killing live connections over them.
        //   • OUR probes are what wake the PHONE's radio to answer.  The camera deliberately
        //     widened its own probes to 30 s because Energy Log showed each one as a periodic
        //     power spike; probing it every 2 s from here simply undid that work on someone
        //     else's battery, which is not ours to spend.
        //
        // 10 + 10×3 ≈ 40 s: still well inside a service, five times gentler on the phone's radio.
        // The cost is only the case nobody waits for - a phone carried away and never brought back
        // holds its channel ~40 s instead of ~11 s.  The case that matters, a phone that drops and
        // RETURNS, never waited on this timer at all: `accept`'s takeover evicts the stale
        // connection after 3 s and admits the newcomer immediately (auth off).
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10      // seconds of silence before the first probe
        tcp.keepaliveInterval = 10  // seconds between probes (was 2 - see above)
        tcp.keepaliveCount = 3      // unanswered probes → connection failed
        // Ceiling on unacknowledged data, which keepalive does NOT cover: a peer that stops ACKing
        // mid-send is dead just as surely as one that stops answering probes.  The camera has set
        // this for a while; we never had it, so that failure had no bound here at all.
        tcp.connectionDropTime = 30
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
            LocalNetworkAccess.shared.note(state)   // a refusal is said in the Mac connection row
            switch state {
            case .ready:
                let port = self.listener?.port?.rawValue ?? 0
                print("[BridgeReceiver \(self.src)] ✅ listening on ephemeral port \(port)")
            case .failed(let err):
                print("[BridgeReceiver \(self.src)] ❌ listener failed: \(err)")
            case .waiting(let err):
                print("[BridgeReceiver \(self.src)] ⏳ listener waiting: \(err)")
            case .cancelled:
                print("[BridgeReceiver \(self.src)] listener cancelled")
            default:
                break
            }
        }
        // A fresh listener has no connection, so it publishes free - and `advertisedBusy` is set
        // to match. Publishing one value while remembering another is exactly how a later
        // `readvertise` (a rename, a reorder) resurrected a stale `busy=1` on a free channel.
        advertisedBusy = false
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
        r["v"]    = "1"                                  // TXT-format version (txtvers) — stays 1
        r["role"] = "bridge"
        r["did"]  = identity.did
        r["dev"]  = identity.dev
        r["sid"]  = sid
        r["src"]  = src
        r["ord"]  = String(order)   // operator's Bridge order → iPhone sorts by this
        r["busy"] = occupied ? "1" : "0"
        r["pv"]   = String(AirliveProto.generation)      // protocol generation — the camera can
        r["mpv"]  = String(AirliveProto.minGeneration)   // annotate/grey this row BEFORE connecting
        return r
    }

    /// Make the advertised `busy` flag say what is actually true: is there a live connection.
    ///
    /// It used to be SET by the caller, and that is how it got stuck. `busy` is not a decision
    /// anyone makes, it is an observation - `connection != nil` - so the one place that publishes
    /// it derives it, and no caller can publish a flag that disagrees with reality. A channel
    /// advertising `busy=1` with nobody connected is invisible to every phone on the network, and
    /// nothing on the phone can cure it: the lie is on this side. Found in the field 2026-09-19,
    /// with the listener holding zero connections and the TXT still saying occupied.
    ///
    /// Republishes ONLY on a real change. Re-registering the Bonjour record under a connected
    /// iPhone churns its endpoint resolution and drops the socket (see `readvertise`), so a
    /// redundant republish is not merely wasteful, it is the "one frame then reconnect" bug.
    private func reconcileOccupancy() {
        let occupied = (connection != nil)
        guard occupied != advertisedBusy else { return }
        advertisedBusy = occupied
        print("[BridgeReceiver \(src)] 📡 advertising busy=\(occupied ? 1 : 0)")
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
    /// re-advertise: the `busy=0` reconcile at disconnect.  The busy-flip path (commit/disconnect) is the ONLY sanctioned
    /// mid-lifecycle service mutation and stays out of this guard.
    private func readvertise() {
        guard connection == nil else { return }
        // The guard above means there is no connection, so the channel is free BY DEFINITION.
        // This used to republish a remembered flag instead, which is what carried a stale
        // `busy=1` across a rename or a reorder and left the channel unreachable.
        advertisedBusy = false
        listener?.service = NWListener.Service(name: instanceName,
                                               type: "_airlive._tcp",
                                               txtRecord: txtRecord(occupied: false))
    }

    // MARK: - Connection (one iPhone per channel; keep listening for reconnect)

    private func accept(_ conn: NWConnection) {
        // Every incoming socket is logged with where it came from and how it ends, so a failed
        // connect shows which side dropped it (camera chat, 2026-10-07: one phone attempt opens an
        // IPv6 AND an IPv4 socket; this log tells whether we kept the one the phone kept).
        let slotNote = connection == nil ? "" : " (slot held)"
        let otherNote = pendingConnections.isEmpty ? "" : ", \(pendingConnections.count) other candidate(s) open"
        print("[BridgeReceiver \(src)] ⇢ incoming \(conn.endpoint)\(slotNote)\(otherNote)")
        // One iPhone per channel — but a NEW connect while the slot is held usually means the phone
        // died without a FIN (powered off / battery / Wi-Fi drop) and came back: the held connection
        // is a half-open corpse keepalive hasn't reaped yet.  TAKEOVER: evict the corpse, admit the
        // newcomer, so the returning phone reconnects INSTANTLY instead of waiting out the probes.
        // Guards:
        //  • age ≥ 3 s — a happy-eyeballs sibling of the JUST-committed connection (the losing
        //    IPv4/IPv6 socket arrives ms later) must not evict its own winner;
        //  • auth OFF only — with auth ON an unauthenticated stranger could kick a legit camera
        //    (DoS) without knowing the password; there the keepalive reap (~40 s) frees the slot.
        if let held = connection {
            let ageNs = DispatchTime.now().uptimeNanoseconds - committedAtNs
            let heldLongEnough = ageNs > 3_000_000_000
            guard heldLongEnough, !effectiveAuthRequired else {
                print("[BridgeReceiver \(src)] ✋ refused \(conn.endpoint): slot held \(ageNs / 1_000_000) ms\(effectiveAuthRequired ? ", password on (no takeover)" : " (sibling of the connection just taken)")")
                conn.cancel()
                return
            }
            print("[BridgeReceiver \(src)] 🔁 new connect while slot held \(ageNs / 1_000_000_000)s — assuming stale peer, taking over")
            held.stateUpdateHandler = nil            // its cancel must not re-enter dropConnection
            handleDisconnect(held, reason: "superseded by a new connection")
            held.cancel()
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
            case .failed(let error):
                print("[BridgeReceiver \(self.src)] ✖ \(conn.endpoint) failed: \(error)")
                self.dropConnection(conn)
            case .cancelled:
                self.dropConnection(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)

        // M2: a candidate that never reaches `.ready` (half-open straggler that also never
        // `.failed`s) would otherwise sit in `pendingConnections` forever.  Drop it after a
        // bound.  Guarded so we never touch the committed connection (it left `pending` the
        // moment it won) or a candidate that already resolved.
        queue.asyncAfter(deadline: .now() + candidateReadyTimeout) { [weak self, weak conn] in
            guard let self, let conn else { return }
            guard conn !== self.connection,
                  self.pendingConnections.contains(where: { $0 === conn }) else { return }
            print("[BridgeReceiver \(self.src)] ⌛ dropping candidate that never readied")
            conn.stateUpdateHandler = nil
            self.pendingConnections.removeAll { $0 === conn }
            conn.cancel()
        }
    }

    /// When the committed connection took the slot (uptime ns) — the takeover age guard in
    /// `accept` reads it to tell a genuine reconnect from a happy-eyeballs sibling.  On `queue`.
    private var committedAtNs: UInt64 = 0

    /// First candidate to `.ready` wins.  On `queue`.
    private func commitConnection(_ conn: NWConnection) {
        guard connection == nil else {
            if conn !== connection {
                print("[BridgeReceiver \(src)] ✋ closing \(conn.endpoint): became ready after the slot was taken")
                conn.cancel()
            }
            return
        }
        connection = conn
        committedAtNs = DispatchTime.now().uptimeNanoseconds
        reanchor("new stream")
        resetAuthState()                          // clean slate for this connection
        let siblings = pendingConnections.filter { $0 !== conn }
        print("[BridgeReceiver \(src)] ✔︎ took \(conn.endpoint) (first ready)\(siblings.isEmpty ? "" : ", closing \(siblings.map { "\($0.endpoint)" }.joined(separator: ", "))")")
        for other in siblings {
            other.stateUpdateHandler = nil
            other.cancel()
        }
        pendingConnections.removeAll()
        parser.reset()                            // fresh stream → drop any bytes a prior
                                                  // or superseded connection left buffered
                                                  // (desync guard; the parser is per-stream)
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
        guard connection === conn else {
            // A straggler died - it is NOT the live connection, so none of the channel's state
            // may be torn down here (that guard is why this early return exists). But the
            // advertisement is not state, it is a statement about reality, so reconcile it on
            // this path too. Returning without doing so is how the flag got stuck at 1.
            reconcileOccupancy()
            return
        }
        print("[BridgeReceiver \(src)] 🔌 disconnect \(conn.endpoint) (\(reason)) — clearing frame, busy=0")
        connection = nil
        stopSilenceWatch()
        resetAuthState()                          // drop any pending challenge/buffer
        reconcileOccupancy()
        teardownDecodeSession()
        pixelBufferLock.lock()
        frameRing.removeAll(keepingCapacity: true)
        pixelBufferLock.unlock()
        reanchor("new stream")
        formatDescription = nil
        didFlipSignalGate = false                 // re-flip the no-signal gate on reconnect (H1)
        pendingRemote = nil                        // drop any coalesced snapshot (H2) so a
        remoteFlushScheduled = false               // trailing flush can't resurrect stale state,
                                                   // and the next connect's leading-edge push fires
                                                   // immediately (no ~1 s blank on fast reconnect)
        publishConnected(false)
        publishSignalCleared()                    // UI returns to "no signal"
    }

    private func receive(from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self, weak conn] data, _, isDone, error in
            guard let self, let conn else { return }
            // Identity guard FIRST — before the shared, stateful PacketParser is ever
            // touched.  Only the COMMITTED connection may feed it: a stale dual-stack
            // loser or a superseded (taken-over) connection can have an in-flight
            // receive land AFTER a new connection committed; appending its bytes would
            // corrupt the new stream's framing.  (The identity check used to live only
            // in handle() — too late: parser.append had already eaten the bytes.)
            guard conn === self.connection else { return }
            if let data, !data.isEmpty {
                self.noteInbound()
                for packet in self.parser.append(data) { self.handle(packet, from: conn) }
            }
            if !isDone && error == nil {
                self.receive(from: conn)
            } else {
                let reason = error.map { "receive error \($0)" } ?? "peer closed (FIN)"
                self.handleDisconnect(conn, reason: reason)
                // Close our side too. Freeing the slot alone left the socket in CLOSE_WAIT, and its
                // keepalive kept probing the phone until the phone answered with a reset. Detached
                // first, as in the takeover: the cancel must not re-enter dropConnection.
                conn.stateUpdateHandler = nil
                conn.cancel()
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
            if logFirstSampleAfterSilence {
                logFirstSampleAfterSilence = false
                let jumpMs = lastSamplePTSMicros < 0 ? 0 : (packet.timestampMicros - lastSamplePTSMicros) / 1_000
                print("[BridgeReceiver \(src)] 📶 first frame after the silence: PTS \(Self.ptsText(packet.timestampMicros)) s (+\(jumpMs) ms after the last one before it)")
            }
            lastSamplePTSMicros = packet.timestampMicros
            if awaitingResumeKeyframe {
                // After a silence the network delivers what it held first: the pre-silence tail,
                // then a drain of frames that queued up - keyframes included. None of it can play
                // in its slot. The picture comes back at the first keyframe that CAN, on the SAME
                // timeline (same connection, same clocks), so the delay is what it was and nothing
                // is fast-forwarded (2026-11-02: re-anchoring on a keyframe still ~1 s late made the
                // drain play at arrival speed and overflow the ring). A fixed wait for the drain
                // failed too: a 10 s outage left ~8 s queued on the phone, still arriving after 3 s.
                // The camera now caps that backlog at ~1 s, so `resumeGiveUpSeconds` is only the
                // safety net for a link that never settles, not the rule.
                let late = lateness(iphonePTS: Double(packet.timestampMicros) / 1_000_000,
                                    at: CACurrentMediaTime())
                noteResumeArrival(lateness: late)
                guard H264NAL.containsIDR(avcc: packet.payload) else {
                    // Frames flow but no keyframe: the request may have landed inside the camera's
                    // spacing window and been ignored. Ask again, at most once a second.
                    return requestResumeKeyframe()
                }
                if late > bufferSeconds + Self.resumeSlack {
                    let waited = CACurrentMediaTime() - resumeWaitStartedAt
                    if resumePathSettled {
                        // The drain is over and frames still come this late: the path got slower.
                        reanchor("picture back on a slower path, +\(Int(late * 1000)) ms")
                    } else if waited >= Self.resumeGiveUpSeconds {
                        reanchor("picture back after \(Int(waited * 1000)) ms waiting, path never settled, +\(Int(late * 1000)) ms")
                    } else {
                        return requestResumeKeyframe()   // the one asked for queued behind the drain
                    }
                }
                awaitingResumeKeyframe = false
                publishSignalLost(false)
                print("[BridgeReceiver \(src)] 🎬 picture back \(Int((CACurrentMediaTime() - resumedAt) * 1000)) ms after the camera came back")
            }
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
        startSilenceWatch()
        // With a password the camera's connect keyframe arrived DURING the challenge and was
        // dropped (samples are refused until authorised; the camera forces that keyframe at
        // connect, before its own auth completes). Without asking again the picture would wait
        // for the next natural keyframe, up to 15 s. Not needed without a password: nothing was
        // dropped. Not on a control-only side: it sends no video.
        if effectiveAuthRequired && !controlSide { requestKeyframe() }
        reconcileOccupancy()
        publishConnected(true)
        // One-shot hello — FIRST control message of the connection (PROTOCOL-COMPAT-SPEC
        // §2: receiver sends hello immediately after accept/auth).  An old camera hits
        // `default: break` and ignores it — harmless.  caps = the protocol surface this
        // build actually implements; new verbs/types are gated on the PEER's caps.
        send(.hello(HelloMessage(
            app: "bridge",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            caps: ["auth", "deliveryMode", "rotation", "capabilities", "tally", "updateRequired"])))
        // Set the delivery mode EXPLICITLY on every ARLV connect, so the camera's sticky
        // `lastDeliveryControlOnly` can't leak across channels with different intent:
        //   • combined channel's control side → control-only (video comes via AirPlay);
        //   • a normal channel → video+control, which RESETS a camera that a previous
        //     control-only connection left with its encoder off (the "connected but fps=0 /
        //     only remote control" bug).
        // The camera's `setEncoderEnabled` is idempotent (it re-confirms but doesn't thrash),
        // so re-asserting the current mode is a free no-op.
        send(.setDeliveryMode(controlSide ? .controlOnly : .videoAndControl))
        if let fmt = pendingFormatPayload {
            pendingFormatPayload = nil
            buildFormatDescription(from: fmt)
            forwardProgramFormat(fmt)   // relay needs the buffered SPS/PPS too,
                                        // else OBS can't decode until the next IDR
        }
    }

    /// Forward a RAW program payload to the channel's relay taps, ON THIS QUEUE.
    ///
    /// These used to hop every packet through `DispatchQueue.main.async`, purely so the
    /// tap closures (written by `BridgeModel` on main) could be read without a data race.
    /// That put the outgoing video for OBS / RTSP / SRT into the same queue as SwiftUI's
    /// rendering of the multiview, previews and controls — so the stream inherited the UI
    /// thread's scheduling.  It showed up exactly as the operator described: perfectly
    /// smooth INSIDE the Bridge (its preview is paced off-main from the decoded ring), but
    /// juddering the moment it was relayed to OBS.  A "just a pointer handoff" comment does
    /// not make the main thread punctual.
    ///
    /// The race is now closed where it belongs — the taps themselves are lock-guarded on
    /// `BridgeChannel` — so these run straight from the network queue, and every relay
    /// output re-dispatches to its own queue anyway.  Nothing on this path touches UI state.
    private func forwardProgramFormat(_ payload: Data) {
        guard isProgramSource else { return }   // H1: no main hop for a non-program channel
        forwardDelayed { [weak self] in self?.channel?.onProgramFormat?(payload) }
    }
    private func forwardProgramSample(_ payload: Data, _ timestampMicros: Int64) {
        guard isProgramSource else { return }   // H1: no main hop for a non-program channel
        forwardDelayed { [weak self] in self?.channel?.onProgramSample?(payload, timestampMicros) }
    }
    /// Hand a passthrough payload (raw SPS/PPS or H.264) to the relay taps (RTSP / SRT / OBS)
    /// ON THIS QUEUE — never main — DELAYED by the SAME `bufferSeconds` the decoded jitter ring
    /// uses, counted from ARRIVAL: roughly in step with the preview, but the network's jitter
    /// passes through. The far end plays by the camera capture timestamps the samples carry.  bufferSeconds == 0 (the default "Lowest" preset with
    /// no extra ms) → immediate delivery, so default latency to OBS is unchanged.  Order
    /// is preserved (serial `queue`, constant delta); a mid-stream delay change can
    /// briefly reorder until the next IDR — the same tolerance the decoded ring has.
    private func forwardDelayed(_ body: @escaping () -> Void) {
        let d = bufferSeconds   // queue-confined; forward* callers run on `queue`
        if d <= 0 { body() } else { queue.asyncAfter(deadline: .now() + d, execute: body) }
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
        peerHello = nil          // next connection re-introduces itself (or is legacy)
        didLogFirstState = false // re-log the lens list on the next connection's first state
        // Clear the channel-surfaced caps too: the NEXT camera may be a different (older) build,
        // and stale flags would leave pickers visible for verbs it can't handle.
        DispatchQueue.main.async { [weak self] in self?.channel?.peerCaps = [] }
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
        pruneExpiredBans()   // bound the dict on a long / churny / hostile LAN
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

    /// Drop expired-ban entries so `authBans` can't grow without bound over a long
    /// show with DHCP churn / a probing prankster.  Keeps active bans and
    /// sub-threshold counters (banUntil == 0).
    private func pruneExpiredBans() {
        let now = CACurrentMediaTime()
        authBans = authBans.filter { $0.value.banUntil == 0 || $0.value.banUntil > now }
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
            if let snap = msg.state {
                if !didLogFirstState {
                    didLogFirstState = true
                    print("[BridgeReceiver \(src)] 📷 first state — lenses=\(snap.availableLenses) lens=\(snap.lens ?? "-") fps=\(snap.fps) codec=\(snap.codec)")
                }
                publishRemote(snap)
            }
        case "hello":
            // Camera's one-shot introduction (first control message, before the state
            // snapshot).  Snapshot ONCE; ignore mid-connection re-hellos (spec §3).
            guard peerHello == nil, let h = msg.hello else { break }
            peerHello = h
            // Surface the camera's caps on the channel (main-confined @Published) so the control
            // panel can GATE new-surface pickers ("lut" / "stabilization" / "colorSpace" / …) —
            // a legacy camera without the flag simply doesn't get that picker.
            DispatchQueue.main.async { [weak self] in self?.channel?.peerCaps = h.caps }
            print("[BridgeReceiver \(src)] 👋 hello: \(h.app) \(h.appVersion) proto=\(h.proto) minProto=\(h.minProto) caps=\(h.caps)")
            // Update-prompt detection (spec §6) — evaluated ONCE at hello, loud log only
            // for now (panel wired to Check-for-Updates later, per §7 rollout).
            if h.proto < AirliveProto.minGeneration {
                print("[BridgeReceiver \(src)] ⚠️ camera proto \(h.proto) < our minProto \(AirliveProto.minGeneration) — camera app needs an update")
            }
            if AirliveProto.generation < h.minProto {
                print("[BridgeReceiver \(src)] ⚠️ our proto \(AirliveProto.generation) < camera minProto \(h.minProto) — THIS Bridge needs an update (Check for Updates…)")
            }
        default:
            // Bridge is the COMMAND sender for set-verbs, not the receiver —
            // ignore unknown inbound control messages.
            break
        }
    }

    /// Extract SPS/PPS from the format-description payload and build a
    /// `CMVideoFormatDescription`.  Rebuild the decode session only on a REAL
    /// format change — the iPhone re-sends the same format on each new connection and whenever a
    /// receiver asks for a keyframe (it no longer does so on every keyframe: that woke its radio
    /// every 2 s for nothing), and wiping the session on a repeat strobes the picture.
    private func buildFormatDescription(from data: Data) {
        let params = parseParameterSets(from: data)
        guard params.count >= 2,
              let fmt = makeFormatDescription(sps: params[0], pps: params[1]) else { return }

        let changed: Bool = {
            guard let existing = formatDescription else { return false }
            return !CMFormatDescriptionEqual(fmt, otherFormatDescription: existing)
        }()
        // The timeline stays: the camera's capture clock does not change with the format.
        if changed {
            pixelBufferLock.lock(); frameRing.removeAll(keepingCapacity: true); pixelBufferLock.unlock()
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
        guard let fmt = formatDescription else {
            return logDecodeFailure("a frame arrived before any usable format description")
        }
        // A valid H.264 access unit is never empty, but a truncated/corrupt
        // packet can pass the parser's length guard with length 0 and then crash
        // on `baseAddress!` below (`Data.withUnsafeBytes` yields a nil base for
        // an empty buffer).  Drop the empty access unit instead.
        guard !payload.isEmpty else { return }

        // packetTimestamp = microseconds on the iPhone's clock (the capture time).  Its Mac-clock
        // playout deadline goes on the sample as its PTS; the ring holds the decoded frame until
        // then, so network jitter becomes queue depth, never on-screen lag.
        let arrival = CACurrentMediaTime()
        let scheduledMacTime = playoutTime(iphonePTS: TimeInterval(packetTimestamp) / 1_000_000.0,
                                           arrivedAt: arrival)
        noteTimeliness(spare: scheduledMacTime - arrival, at: arrival)

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

    /// The Mac-clock moment this frame plays: capture time + fastest path + `bufferSeconds`.
    /// See the "Fixed playout delay" block on the properties for the rules.  On `queue`.
    private func playoutTime(iphonePTS: TimeInterval, arrivedAt macNow: TimeInterval) -> TimeInterval {
        if !anchorSet {
            anchor(iphonePTS: iphonePTS, macNow: macNow)
        }
        var delta = tripDelta(iphonePTS: iphonePTS, at: macNow)
        if playoutLocked && delta - skewOffset < -Self.aheadReanchorThreshold {
            anchorReason = "path \(Int((skewOffset - delta) * 1000)) ms faster than the locked delay"
            anchor(iphonePTS: iphonePTS, macNow: macNow)
            pixelBufferLock.lock(); frameRing.removeAll(keepingCapacity: true); pixelBufferLock.unlock()
            delta = 0
        }

        if macNow < calibratingUntil {
            // Measuring: the fastest frame so far defines the path.  Only ever earlier.
            skewOffset = Swift.min(skewOffset, delta)
        } else {
            if !playoutLocked {
                playoutLocked = true
                lockedSkew = skewOffset
                lastLoggedSkew = skewOffset
                print("[BridgeReceiver \(src)] ⏱ delay locked: \(Int((bufferSeconds * 1000).rounded())) ms over the fastest path (\(Int((skewOffset * 1000).rounded())) ms vs the first frame)")
            }
            followClockDrift(delta: delta, at: macNow)
        }
        lastSkewUpdate = macNow
        return anchorMacTime + bufferSeconds + (iphonePTS - anchorIphonePTS) + skewOffset
    }

    /// Locked: move the schedule toward the fastest path of the last `driftWindowSeconds`, at most
    /// `maxDriftRate` either way - the speed two crystals drift apart, not a network change. A
    /// faster network leaves frames waiting longer (margin), a slower one leaves them late; neither
    /// moves the delay. Each `skewLogStep` of drift is logged, so a long show can be checked.
    private func followClockDrift(delta: Double, at macNow: TimeInterval) {
        skewWindow.append((macNow, delta))
        let cutoff = macNow - Self.driftWindowSeconds
        while let first = skewWindow.first, first.t < cutoff { skewWindow.removeFirst() }
        let target = skewWindow.min(by: { $0.delta < $1.delta })?.delta ?? delta
        let step = Self.maxDriftRate * Swift.max(0, macNow - lastSkewUpdate)
        skewOffset += Swift.min(Swift.max(target - skewOffset, -step), step)

        guard abs(skewOffset - lastLoggedSkew) >= Self.skewLogStep else { return }
        lastLoggedSkew = skewOffset
        let movedMs = Int(((skewOffset - lockedSkew) * 1000).rounded())
        print("[BridgeReceiver \(src)] ⏱ schedule \(movedMs >= 0 ? "+" : "")\(movedMs) ms since the delay locked (clock drift)")
    }

    /// How much longer than the anchor frame's own trip this frame took to arrive.
    private func tripDelta(iphonePTS: TimeInterval, at macNow: TimeInterval) -> Double {
        (macNow - anchorMacTime) - (iphonePTS - anchorIphonePTS)
    }

    /// How much longer than the fastest path this frame took. It can still play in its slot while
    /// this fits in the buffer, give or take a frame (`resumeSlack`, so Lowest's 0 ms buffer is
    /// not held to an exact match). No timeline yet: nothing to judge by, so 0.
    private func lateness(iphonePTS: TimeInterval, at macNow: TimeInterval) -> Double {
        guard anchorSet else { return 0 }
        return tripDelta(iphonePTS: iphonePTS, at: macNow) - skewOffset
    }

    /// Track the fastest arrival per second while the picture waits after a silence; the path is
    /// settled when two completed seconds agree. On `queue`.
    private func noteResumeArrival(lateness late: Double) {
        let now = CACurrentMediaTime()
        if resumeBucketStart == 0 { resumeBucketStart = now }
        if now - resumeBucketStart >= Self.resumeBucketSeconds {
            resumePathSettled = abs(resumeBucketFloor - resumePreviousFloor) <= Self.resumeSettleTolerance
            resumePreviousFloor = resumeBucketFloor
            resumeBucketFloor = .infinity
            resumeBucketStart = now
        }
        resumeBucketFloor = Swift.min(resumeBucketFloor, late)
    }

    /// A capture PTS (phone uptime, µs) as seconds with millisecond precision, as the camera logs it.
    private static func ptsText(_ micros: Int64) -> String {
        micros < 0 ? "-" : String(format: "%.3f", Double(micros) / 1_000_000)
    }

    /// Drop the timeline; the next frame starts a new one (logged with `reason`).
    private func reanchor(_ reason: String) {
        anchorSet = false
        anchorReason = reason
    }

    /// Frames that miss their slot play at once (late, uneven) and the delay stays what it locked
    /// at - so a network slower than the delay is never hidden by stretching it, and never silent
    /// either (operator + camera chat, 2026-11-03): one line when frames start missing their slot
    /// by more than a frame, one when they have been on time for `onTimeConfirmSeconds` again,
    /// with how long and how late. Whether to raise the delay is the operator's call. On `queue`.
    private func noteTimeliness(spare: Double, at now: TimeInterval) {
        if spare < -Self.resumeSlack {
            if lateSpellStart == 0 {
                lateSpellStart = now
                lateSpellWorst = 0
                lateSpellFrames = 0
                print("[BridgeReceiver \(src)] ⚠️ network slower than the delay: frames are missing their slot (\(Int(-spare * 1000)) ms late)")
            }
            lateSpellWorst = Swift.max(lateSpellWorst, -spare)
            lateSpellFrames += 1
            lateSpellLastLate = now
        } else if lateSpellStart != 0, now - lateSpellLastLate >= Self.onTimeConfirmSeconds {
            closeLateSpell("on time again")
        }
    }

    /// End an open late spell with its summary line. On `queue`.
    private func closeLateSpell(_ how: String) {
        guard lateSpellStart != 0 else { return }
        let lasted = String(format: "%.1f", lateSpellLastLate - lateSpellStart)
        print("[BridgeReceiver \(src)] ✅ frames \(how) - \(lateSpellFrames) missed their slot over \(lasted) s, up to \(Int(lateSpellWorst * 1000)) ms late")
        lateSpellStart = 0
    }

    /// Start a new timeline at this frame and measure the fastest path for `calibrationSeconds`.
    private func anchor(iphonePTS: TimeInterval, macNow: TimeInterval) {
        closeLateSpell("on a new timeline")
        anchorIphonePTS  = iphonePTS
        anchorMacTime    = macNow
        anchorSet        = true
        skewOffset       = 0
        skewWindow.removeAll(keepingCapacity: true)
        calibratingUntil = macNow + Self.calibrationSeconds
        playoutLocked    = false
        lastSkewUpdate   = macNow
        print("[BridgeReceiver \(src)] ⏱ delay re-anchored (\(anchorReason))")
        anchorReason = "new stream"
    }

    /// Decompress one sample buffer to a BGRA `CVPixelBuffer`.  BGRA + IOSurface
    /// is the cheapest handoff for downstream encoders (NDI / SRT / RTSP) and
    /// renders directly in the SwiftUI preview.  Session rebuilt on format change.
    private func decompress(sampleBuffer: CMSampleBuffer, format: CMVideoFormatDescription) {
        if decompressionFormat == nil ||
           !CMFormatDescriptionEqual(decompressionFormat, otherFormatDescription: format) {
            // CRITICAL: drain in-flight async frames BEFORE invalidating, or a
            // decode callback can fire into a half-torn-down session and touch
            // freed state (EXC_BAD_ACCESS).  A real mid-stream format change
            // (resolution/codec/orientation re-encode) is exactly when a frame is
            // most likely still in the old session — 5× more likely with 5 cameras
            // over a 4-hour show.  Matches teardownDecodeSession() / deinit.
            if let old = decompressionSession {
                VTDecompressionSessionWaitForAsynchronousFrames(old)
                VTDecompressionSessionInvalidate(old)
            }
            decompressionSession = nil

            // Decode to NV12 (raw YCbCr) — same output the AirPlay decoder uses, so
            // BOTH sources present through one identical display regime (NV12 +
            // sRGB tags + sRGB window pin; see ingestDecoded).  Also skips VT's
            // YUV→RGB conversion at decode (RGB output bakes a transfer curve into
            // the pixels; NV12 keeps the wire's raw values for the zero-copy
            // CALayer preview).  The pipeline already handles NV12 everywhere
            // (AirPlay produces it); NDI repacks on demand into an NV12 pool — it
            // was measured on 2026-08-30, and NDI now carries this buffer's own
            // format end to end rather than expanding it to RGB.  (The 2026-07-06 overcooked wire itself was a
            // CAMERA bake bug — receivers were innocent; see
            // airlive/docs/WIRE-COLOR-RECEIVER-DIAGNOSIS.md.)
            let outputAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var callback = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: { (refCon, _, status, _, imageBuffer, pts, _) in
                    guard let refCon else { return }
                    let receiver = Unmanaged<BridgeChannelReceiver>.fromOpaque(refCon).takeUnretainedValue()
                    guard status == noErr, let imageBuffer else {
                        // Hop to `queue` (never block it): the rate limit's state lives there.
                        // Weak, like `ingestDecoded`'s hop: deinit drains frames, and a strong
                        // capture of a receiver being freed would crash.
                        receiver.queue.async { [weak receiver] in
                            receiver?.logDecodeFailure(status == noErr ? "the decoder dropped a frame"
                                                                      : "a frame failed to decode: \(status)")
                        }
                        return
                    }
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
                // Retried on the next frame (a later keyframe may succeed); logged at most 1/s.
                return logDecodeFailure("VTDecompressionSessionCreate failed: \(status)")
            }
            decompressionSession = newSession
            decompressionFormat  = format

            // Low-latency scheduling hint — bias VideoToolbox toward prompt decode (the AirPlay
            // decoder sets this too; the direct-wire ARLV path was missing it). Thermally near-neutral
            // on the Mac (a scheduler hint, adds no work), most useful at 5-camera scale.
            VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        }

        guard let session = decompressionSession else { return }
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        // A non-noErr submit means a corrupt NAL or a wedged session; without the log the
        // operator just sees a frozen tile.
        if status != noErr {
            logDecodeFailure("VTDecompressionSessionDecodeFrame failed: \(status)")
        }
    }

    /// Every decode failure is logged, never dropped silently - but at most one line per second,
    /// carrying how many more happened since, so a broken stream cannot flood the log at 30-60
    /// lines a second. On `queue`.
    private func logDecodeFailure(_ what: String) {
        let now = CACurrentMediaTime()
        guard now - lastDecodeErrorLog >= Self.decodeErrorLogInterval else {
            suppressedDecodeErrors += 1
            return
        }
        let more = suppressedDecodeErrors > 0 ? " (+\(suppressedDecodeErrors) more since the last line)" : ""
        print("[BridgeReceiver \(src)] ⚠️ \(what)\(more)")
        lastDecodeErrorLog = now
        suppressedDecodeErrors = 0
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

    /// Enqueue a decoded frame and schedule its promotion at the playout
    /// deadline.  Lowest (0 ms) promotes inline (the fast baseline — no timer
    /// hop); buffered mode arms a one-shot.  Called on the VT decode-callback
    /// thread.
    private func ingestDecoded(_ buffer: CVPixelBuffer, playout: TimeInterval) {
        // WYSIWYS presentation tags: stamp the decoded frame with the SAME colour
        // regime the phone's monitor and the AirPlay path use — sRGB transfer,
        // 709 primaries/matrix, sRGB CGColorSpace — so Core Animation composites
        // the monitoring proxy AS-IS (paired with the sRGB window pin in
        // MirrorVideoView).  This is presentation hygiene, not a value transform:
        // the wire's VALUES are already exactly the operator's preview (the
        // 2026-07-06 "overcooked wire" was a CAMERA bake bug — identity-LUT
        // texel-center stretch — proven by a per-hop pixel probe; receivers were
        // innocent.  Post-mortem: airlive/docs/WIRE-COLOR-RECEIVER-DIAGNOSIS.md).
        // Zero per-pixel work — dictionary attachments only.  NDI is unaffected
        // (it converts/copies pixels, tag-agnostic).
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey,
                              CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        pixelBufferLock.lock()
        frameRing.append((buffer, playout))
        if frameRing.count > ringCapacity {
            frameRing.removeFirst(frameRing.count - ringCapacity)   // overrun drop
        }
        pixelBufferLock.unlock()

        let delay = playout - CACurrentMediaTime()
        // Only a frame that is ALREADY due takes the immediate hop. One still a fraction of a
        // millisecond early used to take it too, and `promoteDue` - which releases only what is
        // due - left it in the ring with nothing scheduled to come back for it: it went out with
        // the NEXT frame and one of the two was lost.
        if delay <= 0 {
            // Lowest (0 ms): promote AS SOON AS POSSIBLE — but still hop onto `queue`
            // (a zero-delay `async`, not the `asyncAfter` timer) instead of promoting
            // INLINE on this VT decode thread.  That keeps `promoteDue`/`present`
            // strictly queue-confined, so the per-frame gate state they read
            // (`isProgramSource`, `didFlipSignalGate`) needs no extra lock.  The hop is
            // a serial-queue enqueue (sub-ms), not a thread switch, so the low-latency
            // baseline is preserved.  `frameRing` stays guarded by `pixelBufferLock`.
            queue.async { [weak self] in self?.promoteDue() }
        } else {
            // Strict, not `asyncAfter`: its power-saving slack showed as repeated frames in OBS
            // (StrictTimer.swift).
            queue.strictAfter(delay) { [weak self] in self?.promoteDue() }
        }
    }

    /// Present the frame whose time has come; a frame whose time passed while a newer one also
    /// came due is skipped, never played late (operator + camera chat, 2026-11-02).
    ///
    /// The playout delay is fixed (`playoutTime`), so in steady state exactly one frame is due per
    /// tick. Several are due at once only after the network held them past the buffer: playing
    /// them back to back fast-forwarded the tiles and queued the virtual camera behind real time.
    /// Now the picture holds on its last frame through the hole and makes one clean step to the
    /// present, and the delay stays what it was locked at.
    private func promoteDue() {
        let now = CACurrentMediaTime()
        var newest: (buffer: CVPixelBuffer, playout: TimeInterval)?
        pixelBufferLock.lock()
        while let first = frameRing.first, first.playout <= now {
            newest = first
            frameRing.removeFirst()
        }
        pixelBufferLock.unlock()

        guard let frame = newest else { return }
        present(frame.buffer)
    }

    /// Single presentation point.  Two jobs:
    ///
    ///   1. MIRROR (per-frame pixels) — `channel.publishFrame(buffer)`, called
    ///      right here on the present thread (OFF main): it stores the latest
    ///      buffer and posts `newFrameNotification`, so every MirrorVideoView tile
    ///      points its own `CALayer.contents` at the SAME IOSurface-backed buffer.
    ///      One decode feeds any number of tiles (multiview + Program + Preview),
    ///      and a busy main thread can never freeze the preview.
    ///   2. OUTPUT fan-out — straight from this queue.  It used to hop to main, which
    ///      put NDI / HDMI / the virtual camera on the same thread as SwiftUI's rendering
    ///      of the multiview, previews and controls — the same defect that made the OBS
    ///      relay judder, left behind when that one was fixed because these outputs take a
    ///      decoded buffer rather than raw bytes.
    ///   3. The published "no signal" gate — genuinely main-isolated, and touched ONCE per
    ///      (re)connect, not per frame.
    private func present(_ buffer: CVPixelBuffer) {
        let timeNs = UInt64(CACurrentMediaTime() * 1_000_000_000.0)

        // 1. Mirror — off main.  ALWAYS (every tile that wants this channel repaints
        //    off the same IOSurface; a busy main thread can never freeze preview).
        channel?.publishFrame(buffer)

        // 2. Main-isolated work — but ONLY when there is any.  A non-program channel
        //    needs main exactly ONCE per (re)connect (flip the no-signal gate + log the
        //    first frame); the program source needs it every frame (the program tap).
        //    So after its first frame a non-program channel does ZERO per-frame main
        //    hops (H1) — the 5-cam win, where most hops found a nil `onProgramFrame`.
        let isPgm = isProgramSource                       // captured on `queue`
        let needGateFlip = !didFlipSignalGate
        if needGateFlip { didFlipSignalGate = true }
        guard isPgm || needGateFlip else { return }
        let srcName = src                                 // captured on `queue`; `src` is
                                                          // queue-confined — never read it
                                                          // from the main hop below (race)

        // Program tap: forward to the program output(s) while this is the source — on THIS
        // queue.  The tap is lock-guarded (Channel.swift) and the outputs are read from the
        // lock-guarded ProgramBus, so main is not needed and must not be used.
        if isPgm {
            channel?.onProgramFrame?(buffer, timeNs)
        }

        guard needGateFlip else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel else { return }
            if !self.didLogFirstFrame {
                self.didLogFirstFrame = true
                print("[BridgeReceiver \(srcName)] ✅ first frame presented")
            }
            // Flip the published "no signal" gate on the first frame only (guarded —
            // never a per-frame published write).
            if channel.latestFrame == nil { channel.latestFrame = buffer }
        }
    }

    // MARK: - Publish to the owning channel (main queue)

    // MARK: - Link silence

    /// A camera that loses its route goes completely quiet and, when the route returns, resumes
    /// on the SAME connection (camera 52d2c7b) - TCP never notices. So the only way to know is to
    /// listen: no bytes for `silenceThreshold` = the link is silent; the first bytes after it = the
    /// link is back. On a video connection silence is a lost picture, shown as "No signal" and
    /// taken off the program. The lamp is not this code's business: the camera sends its state
    /// when its route returns, and every state is answered with the current tally.
    /// On `queue`.
    private func startSilenceWatch() {
        lastInboundAt = CACurrentMediaTime()
        linkSilent = false
        awaitingResumeKeyframe = false
        lastSamplePTSMicros = -1
        logFirstSampleAfterSilence = false
        peerSendsVideo = true   // until this connection's first snapshot says otherwise
        guard silenceTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.silenceCheckInterval, repeating: Self.silenceCheckInterval)
        t.setEventHandler { [weak self] in self?.checkSilence() }
        t.resume()
        silenceTimer = t
    }

    /// On `queue`.
    /// The channel's "No signal" is cleared by `publishConnected(false)`, in the SAME main-thread
    /// step that marks it disconnected: cleared first on its own, the channel would read
    /// "connected and live" for an instant and the program would be routed back to a camera that
    /// is already gone.
    private func stopSilenceWatch() {
        silenceTimer?.cancel()
        silenceTimer = nil
        linkSilent = false
        awaitingResumeKeyframe = false
    }

    /// On `queue`.
    private func checkSilence() {
        guard !linkSilent, CACurrentMediaTime() - lastInboundAt > Self.silenceThreshold else { return }
        linkSilent = true
        guard carriesPicture else { return }
        print("[BridgeReceiver \(src)] 📵 nothing from the camera for \(Self.silenceThreshold) s - last frame PTS \(Self.ptsText(lastSamplePTSMicros)) s")
        publishSignalLost(true)
    }

    /// Bytes arrived on the committed connection. On `queue`.
    private func noteInbound() {
        lastInboundAt = CACurrentMediaTime()
        guard linkSilent else { return }
        linkSilent = false
        // The PICTURE is not back until the camera's keyframe, so "No signal" stays up until it
        // arrives (`.sample` below) - never a frozen frame passed off as live. Tally needs nothing
        // here: a camera whose route dropped sends its state when the route returns, and every
        // state is answered with the current cue (`pushRemoteToMain`).
        if carriesPicture {
            if !awaitingResumeKeyframe { resumeWaitStartedAt = CACurrentMediaTime() }
            awaitingResumeKeyframe = true
            resumedAt = CACurrentMediaTime()
            resumeBucketStart = 0
            resumeBucketFloor = .infinity
            resumePreviousFloor = .infinity
            resumePathSettled = false
            // ASK for the keyframe. The camera makes one by itself only when iOS reported its route
            // gone and back (camera `handleLinkViability`); a Wi-Fi stall that never lost the route
            // leaves it encoding P-frames, and the next natural keyframe is up to 15 s away (its
            // standard keyframe interval). The same request every cut makes; the camera answers
            // with an IDR and its format, rate-limited on its side.
            send(.forceKeyframe())
            lastResumeKeyframeRequestAt = CACurrentMediaTime()
            logFirstSampleAfterSilence = true
            print("[BridgeReceiver \(src)] 📶 camera back on the same connection - asked for a keyframe")
        } else {
            publishSignalLost(false)
        }
    }

    /// Whether silence on this connection means a lost picture: not on the control side of a
    /// combined channel (its video is the AirPlay side) and not from a Control-only camera.
    private var carriesPicture: Bool { !controlSide && peerSendsVideo }

    private func publishSignalLost(_ lost: Bool) {
        guard !controlSide else { return }
        DispatchQueue.main.async { [weak self] in
            guard let channel = self?.channel, channel.linkSilent != lost else { return }
            channel.linkSilent = lost
        }
    }

    private func publishConnected(_ connected: Bool) {
        // Control-side of a combined channel drives `controlConnected` (the ARLV side); the
        // video/`isConnected` flag belongs to the AirPlay receiver.  Everything else uses
        // `isConnected` as before.
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel else { return }
            if self.controlSide { channel.controlConnected = connected }
            else {
                channel.isConnected = connected
                // Disconnected: no longer "silent" either (see stopSilenceWatch) - after
                // isConnected, so the program is already routed away when this lands.
                if !connected, channel.linkSilent { channel.linkSilent = false }
            }
        }
    }

    /// Disconnect / format-change cleanup: clear the published `latestFrame` gate
    /// (returns the UI to "no signal") and blank every mirror tile to black.
    private func publishSignalCleared() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel else { return }
            // Control-side: only its control state is ours — leave the AirPlay video alone.
            if self.controlSide {
                channel.controlConnected = false
                channel.remote = nil
                return
            }
            channel.latestFrame = nil
            channel.publishFrame(nil)   // blank every mirror to black
            // Drop the last camera snapshot too (called ONLY on disconnect): otherwise a
            // Control-only channel keeps videoActive=false and the tile shows stale
            // "CONTROL ONLY" instead of the offline state.  nil → videoActive defaults true.
            channel.remote = nil
        }
    }

    /// H2: coalesce snapshots to ~1 Hz.  On `queue`.  Leading edge pushes the first
    /// immediately (so the control UI lights up at once on connect); within the window we
    /// only keep the latest and push it when the window closes — at most one main hop per
    /// `remoteCoalesceSeconds`, no matter how fast the phone sends.
    private func publishRemote(_ snapshot: StateSnapshot) {
        peerSendsVideo = snapshot.videoActive
        if remoteFlushScheduled {
            pendingRemote = snapshot               // within window — defer the latest
            return
        }
        remoteFlushScheduled = true
        pushRemoteToMain(snapshot)                 // leading edge — immediate
        queue.asyncAfter(deadline: .now() + remoteCoalesceSeconds) { [weak self] in
            guard let self else { return }
            self.remoteFlushScheduled = false
            if let latest = self.pendingRemote {   // something arrived during the window
                self.pendingRemote = nil
                self.publishRemote(latest)         // push it + re-arm the window
            }
        }
    }

    private func pushRemoteToMain(_ snapshot: StateSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel else { return }
            channel.remote = snapshot
            // Control-side of a combined channel: the VIDEO is the AirPlay side (already upright),
            // so the ARLV snapshot's rotation must NOT rotate it — leave outputRotation to the
            // video receiver.  Normal channels apply it as before.
            if !self.controlSide { channel.outputRotation = snapshot.outputRotation }  // mirrors read this off-main
            channel.onStateReceived?()
        }
    }

    // MARK: - Program-source gate (H1)

    /// Mark whether THIS channel currently feeds the program bus.  Called by the model on
    /// the main thread from `routeProgram`; hopped onto `queue` so the per-frame taps read
    /// it race-free.  When false, the frame/sample/format taps skip their main hop entirely.
    ///
    /// Across a CUT there's a benign one-packet window: `routeProgram` sets the closures on
    /// main, then this flag lands a moment later on `queue`.  Worst case a single sample is
    /// dropped (flag not yet true on the new source) or forwarded to an already-nilled
    /// closure (no-op) — never a crash, and the next frame self-corrects.
    func setProgramSource(_ isProgram: Bool) {
        queue.async { [weak self] in self?.isProgramSource = isProgram }
    }
}
