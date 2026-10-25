// VirtualCameraOutput.swift — PROGRAM → macOS Virtual Camera.
//
// Publishes the program feed as a system camera, so OBS and any other app that takes a camera
// can pick "Airlive Bridge Virtual Camera" from its normal camera list.  Unlike every
// other output there is no socket, no encode and — for a 1080p program — no conversion
// either: the decoder's own frame is pushed straight into the extension's SINK stream (see
// CMIOSinkConnection), which the extension, a separate process macOS launches on demand,
// pulls from.  Anything that is not already the camera's format and size is letterboxed
// into it once, by VideoToolbox - including the program itself when the operator picked a size
// above 1080p (VirtualCameraResolution).
//
// Frames go into the camera on the Bridge's OWN 30 fps clock, never at the moment they arrive
// (see "Pacing" below). That is the half of OBS's own virtual camera this file was missing: OBS
// feeds its camera from its renderer, which ticks at exactly the frame rate on the Mac's clock,
// and its extension simply relays. Ours relays the same way; the even feed is done here.
//
// Two things make this output unlike the others, and both are macOS rules, not ours:
//   • The extension can ONLY load when the Bridge runs from /Applications.
//   • The FIRST activation asks the operator to approve it in System Settings.
// Neither is an error state, so both are reported as plain guidance on the card.
//
// WHO DOES WHAT — the division that this file got wrong for three days:
//   • INSTALLING the camera is a property of the CARD EXISTING, and happens ONCE.
//     It used to happen on every toggle-on, as a `.replace` request, which tears the
//     extension down and relaunches it — so switching the card on made the device
//     briefly disappear, and the very lookup running alongside it lost the race.  The
//     operator saw "camera not found" for a camera the system was listing, and was told
//     to reboot and re-approve for something the app was doing to itself.
//   • The TOGGLE owns the sink stream and nothing else: on = push frames, off = stop.
//   • WHAT THE CARD SAYS is derived from the system, never remembered.  A latched string
//     survives the condition it described; that is what made the message stick.
//   • The device appearing is an EVENT, not something to poll for: CoreMediaIO tells us
//     when the camera list changes, and the card follows on its own.

import Foundation
import CoreVideo
import CoreMediaIO
import VideoToolbox
import QuartzCore   // CACurrentMediaTime - the gap clock for holding the last frame
import CoreMedia    // CMTime - the frame times on the pacing grid
import SystemExtensions
import os

/// The size the virtual camera's frames are sent at (Settings → Outputs). The program is 1080p; a
/// larger size is the program scaled up ONCE here, so an app whose canvas is 1440p or 4K does not
/// scale it again itself - visibly sharper in OBS on a 4K canvas (operator, 2026-10-05 test).
/// Never below 1080p: the source is 1080p, and smaller would only throw detail away.
///
/// Bridge-side only: the extension forwards each frame with the frame's OWN size, and consumers
/// size themselves from the frames - OBS switched to 4K live, without reopening the camera, when
/// a 4K build started sending (2026-10-05). The camera's declared format stays 1080p.
enum VirtualCameraResolution: String, CaseIterable, Identifiable {
    case hd1080, qhd1440, uhd4k

    /// Where the choice is stored (UserDefaults).
    static let storageKey = "bridge.vcamResolution"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hd1080:  return "1080p"
        case .qhd1440: return "1440p"
        case .uhd4k:   return "4K"
        }
    }

    var width: Int {
        switch self {
        case .hd1080:  return 1920
        case .qhd1440: return 2560
        case .uhd4k:   return 3840
        }
    }

    var height: Int { width * 9 / 16 }

    /// Parked at 1080p for now (operator, 2026-10-16): the choice is hidden in Settings and a
    /// value stored while it was offered is ignored. The live switch behind it stays as built
    /// and reviewed; turning this back on is the whole change.
    static let isSelectable = false

    /// The stored choice, 1080p when none was ever made - so nothing changes for anyone who does
    /// not choose.
    static var stored: VirtualCameraResolution {
        guard isSelectable else { return .hd1080 }
        return UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .hd1080
    }
}

/// Same subsystem the extension logs under — one `log show` shows both ends of the hop.
private let vcamOutLog = Logger(subsystem: "studio.airlive.vcam", category: "bridge")

// Size, cadence, pixel format, identity and the camera's name are declared ONCE, in
// Sources/Shared/VirtualCameraContract.swift — the extension compiles the same file, so the
// two ends of this hop cannot drift apart.

final class VirtualCameraOutput: NSObject, VideoOutput {

    let id: UUID
    var label: String
    let kind: OutputKind = .vcam
    var config: String = ""

    /// Where the camera actually is right now.  Every value is set by a real event —
    /// an activation callback, the camera list changing, the sink opening — so the card
    /// cannot show a state the machine has left.
    private enum Stage {
        case notSetUp                   // the card exists; nothing has been asked of macOS yet
        case installing                 // request submitted, nothing to say yet
        case awaitingApproval           // macOS is asking the operator
        case needsInstall(String)       // it cannot be installed, and why
        case starting                   // approved; the device has not appeared YET (transient)
        case cameraProcessMissing       // approved and staged, but macOS never launched it
        case ready                      // the device is published, the toggle is off
        case live                       // frames are going in
        case failed(String)             // a real transport failure

        /// Only states the operator can DO something about are worth red text.
        /// `starting` deliberately says nothing: it resolves by itself within a second,
        /// and calling it an error is what taught the operator to distrust this card.
        var message: String? {
            switch self {
            case .needsInstall(let why): return why
            case .failed(let why):       return why
            case .awaitingApproval:
                return "Approve “\(kVCamDeviceName)” in System Settings → General → Login Items & Extensions."
            case .cameraProcessMissing:
                // Cheapest remedy FIRST.  Measured 2026-08-30: the camera was published and
                // being served to another app while this one could not enumerate it at all — a fresh
                // process found it instantly with the identical lookup.  So the usual cause is
                // not that macOS failed to launch the extension; it is that THIS process built
                // its device list while the extension was being replaced and never refreshed.
                // Reopening the app costs seconds; logging out costs the operator their session.
                return "Quit and reopen Airlive Bridge — this copy can’t see the virtual camera. If it’s still missing, log out and back in."
            case .notSetUp, .installing, .starting, .ready, .live: return nil
            }
        }
    }

    private let lock = NSLock()
    private var _stage: Stage = .notSetUp
    /// The installer's last word while the camera is NOT in the device list: awaiting approval,
    /// or why it cannot be installed. Guarded by `lock`. It outranks the silent "starting" every
    /// other path falls back to, which used to erase it a moment after it was shown - the card
    /// stayed on with no message at all (a fresh install run from Downloads, for one).
    private var installVerdict: Stage?
    private var _isLive = false
    /// The size frames go to the camera at. Guarded by `lock`: read per frame on `paceQueue`,
    /// changed from Settings on main.
    private var _resolution = VirtualCameraResolution.stored

    /// macOS accepted a NEW extension but could not swap it in, because the old one is still
    /// running — something has the camera open.  It finishes at the next restart, and until
    /// then the camera on this Mac is the PREVIOUS version.
    ///
    /// Latched, and deliberately outside the stage machine: everything else here is re-derived
    /// from the system, and that is exactly what buried this message.  The old extension is
    /// alive, so its device is in the list and its sink opens perfectly — the card went `.live`
    /// a moment after saying "restart", and the operator was left running the old camera with
    /// nothing on screen to say so.  A pending swap is not a state of the camera; it is a fact
    /// about this app session, and only relaunching after a restart can clear it.
    private var pendingRestart = false

    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return _isLive }
    var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        if pendingRestart {
            return "Restart the Mac to finish updating the virtual camera — until then apps still get the previous version."
        }
        return _stage.message
    }

    /// Wired by BridgeModel.configureOutput, exactly like every other output's — without it
    /// nothing this class learns can reach the card, and every fix below would be invisible.
    var onStateChanged: (() -> Void)?

    private func setStage(_ stage: Stage) {
        lock.lock(); _stage = stage; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStateChanged?() }
    }

    /// Opening and closing the sink talks to CoreMediaIO and can block; frames do NOT
    /// come through here — see `send` and `deliverTick`.
    private let queue = DispatchQueue(label: "studio.airlive.bridge.vcam", qos: .userInitiated)
    /// Marks `queue` so a re-entrant call can tell "already there" from "arrived on main".
    private static let queueKey = DispatchSpecificKey<Void>()
    private var sink: CMIOSinkConnection?

    /// Conversion — built lazily the first time a frame arrives that is not already the
    /// camera's format and size (an AirPlay mirror, a capture card at 720p, the black "no
    /// program" filler, which is BGRA, and every frame when a size above 1080p is chosen).  At
    /// 1080p the normal path never touches it: the program decoder's buffers go across untouched.  VTPixelTransferSession rather than
    /// CoreImage — a fixed-function block instead of a filter graph.
    ///
    /// GUARDED BY `lock`: frames are converted on `paceQueue` and `stop` runs on this output's own
    /// queue, so an unguarded pair could invalidate the session while a frame was mid-transfer.
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    private let installer = SystemExtensionInstaller.shared

    /// Frames taken by the camera, and frames the camera had no room for since this output
    /// was switched on.  Touched only on `paceQueue`, one tick at a time.  A large, steadily growing `dropped` with `sent` frozen is not a fault — it is
    /// exactly what "the camera is on and no app has it open" looks like — and printing both
    /// once a second is what lets the log say which of the two is happening.
    private var framesSent: UInt64 = 0
    private var framesDropped: UInt64 = 0

    /// Whether an app is actually RECEIVING the program right now: the camera has taken frames
    /// out of the queue within `receivingWindow` (CMIOSinkConnection.framesTakenByCamera).
    /// "On" on the card only means the camera was found and its input opened; this is what
    /// tells "OBS shows black because it never opened the camera" from "OBS is getting frames".
    /// Logged on every change. Read and written on `paceQueue`; reset under `lock` when a sink
    /// opens. Unsynchronised like the counters above: the worst a race costs is one log line.
    private var appReceiving = false
    private var lastTaken: UInt64 = 0
    private var lastTakenAt: CFTimeInterval = 0
    /// Two seconds without the camera taking a frame = nobody is reading it.
    private static let receivingWindow: CFTimeInterval = 2

    // ── Pacing: the camera gets exactly 30.000 frames a second on the Mac's clock ─────────────
    // A camera's frames arrive at ITS phone's 30 fps - its own crystal, a few parts per million
    // off the Mac's. Pushed into the camera the moment they arrived (as this output used to), that
    // cadence reached OBS, which renders at exactly 30.000 on the Mac's clock: the two slowly
    // slide past each other, and while a camera's frames sit near OBS's tick, the smallest jitter
    // lands them on one tick or the next, so OBS repeats and drops frames for minutes at a time.
    // Which camera stutters depended only on where its phase happened to be (field, 2026-10-25:
    // Bridge's own window perfect, OBS stuttering on one camera, then the other).
    //
    // So arrivals go into a small first-in-first-out queue, and a strict timer on the host clock
    // takes ONE frame out per tick, stamped with the tick's own time. The queue is the hysteresis
    // every frame synchroniser needs: once a frame waits a tick, jitter around the tick no longer
    // decides anything. The phone's drift comes out as one repeated frame (a tick with nothing new
    // - the queue then holds one frame more, so the same jitter cannot do it again) or one dropped
    // frame (a surplus that PERSISTS, see `surplusPersistence` - one early frame is jitter, not
    // drift) every several minutes, instead of bursts. The cost is about one frame of extra delay
    // on THIS output only; the Bridge's own window and every other output keep their timing.
    //
    // The same tick holds the shot through a short gap: the extension puts up its "No Video"
    // picture a quarter-second after frames stop (AirliveDeviceSource.realFrameGrace), and the
    // Bridge only turns a silent camera into black after one second
    // (BridgeChannelReceiver.silenceThreshold) - in between, the last frame is simply repeated.

    /// Frames waiting for their tick (camera-ready or not yet converted), oldest first, and the
    /// last frame the camera was given (already camera-ready), for repeats. Guarded by `lock`.
    private var _waiting: [CVPixelBuffer] = []
    private var _lastFrame: CVPixelBuffer?
    /// When the last program frame ARRIVED. Guarded by `lock`.
    private var _lastArrival: CFTimeInterval = 0
    /// Beyond this many waiting frames the oldest is dropped on arrival. Only reached when the
    /// ticks stall; in steady state at most two wait (see `deliverTick`).
    private static let maxWaiting = 3
    /// Ticks in a row with a frame to spare before one is dropped: half a second. A frame that
    /// arrives early is gone from the surplus at the next tick; the phone gaining on the Mac
    /// keeps it there.
    private static let surplusPersistence = 15
    /// Past the Bridge's own switch to black (1.0-1.25 s) the program is flowing again as black;
    /// if nothing comes even then, the placeholder is the truth and is let through.
    private static let holdLimit: CFTimeInterval = 1.5
    /// The camera's declared rate (VirtualCameraContract), as an exact integer tick count.
    private static let ticksPerSecond = Int64(kVCamFrameRate)
    private static let nsPerSecond: Int64 = 1_000_000_000
    /// Its own queue, never behind a blocking sink open/close on `queue`.
    private let paceQueue = DispatchQueue(label: "studio.airlive.bridge.vcam.pace", qos: .userInteractive)
    private var paceTimer: DispatchSourceTimer?   // main (start/stop)
    /// The grid's origin and the last tick delivered, in host-clock nanoseconds / tick numbers.
    /// Touched only on `paceQueue`.
    private var gridOriginNs: UInt64 = 0
    private var lastTick: Int64 = -1
    /// What the pacing did since the output went on - logged once a second with the rest, so a
    /// long recording can be checked against it. Touched only on `paceQueue`.
    private var framesRepeated: UInt64 = 0
    private var framesSkipped: UInt64 = 0
    /// Consecutive ticks that left a frame to spare. Touched only on `paceQueue`.
    private var surplusTicks = 0

    init(id: UUID = UUID(), label: String = "Virtual Camera") {
        self.id = id
        self.label = label
        super.init()
        queue.setSpecific(key: Self.queueKey, value: ())
        watchDeviceList()
        // NOT install() - see `start()`. A camera already approved in an earlier session is found
        // right here and the card simply reads "ready"; nothing is asked of macOS.
        refreshFromDeviceList(fallback: .notSetUp)
    }

    deinit {
        stopWatchingDeviceList()
    }

    // MARK: - Installing the camera (ONCE, because the card exists)

    /// "Staged and enabled" is not the same as "running", and macOS will tell you the first
    /// while the second is false.
    ///
    /// Replacing a camera extension is a race inside the system's own service: it stops the
    /// outgoing process and, milliseconds later, submits the same launchd job for the incoming
    /// one — the job name comes from the bundle id, so both versions share it. If the old
    /// process has not been reaped yet, launchd answers "operation already in progress", the
    /// service reads that as "already running", and NOTHING EVER LAUNCHES THE NEW ONE. The
    /// activation request still completes successfully. Verified in the system log, and lost
    /// three times out of five in one afternoon.
    ///
    /// We cannot win that race — nor can any other app; the reference implementation ships
    /// with the same caveat. What we can do is stop reporting success and going quiet. If the
    /// device has not appeared shortly after activation completed, say so, and say the remedy:
    /// logging out and back in restarts that service, which re-launches what is already
    /// approved. A full restart is not required, and the operator spent a day believing it was.
    private func expectDeviceShortly() {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let stillWaiting = self.isStarting; self.lock.unlock()
            guard stillWaiting, !CMIOSinkConnection.deviceExists(uuid: kVCamDeviceUUID) else { return }
            // Two causes look the same from here, and the card's remedy covers both, cheapest
            // first: this app's device list never picked up the new camera (a fresh install: the
            // extension launched, a relaunched Bridge sees it at once - field test 2026-10-20),
            // or macOS never launched the extension (the replacement race above).
            vcamOutLog.error("camera not visible to this app 3 s after activation - asking to quit and reopen the Bridge (if the camera's own log shows no \"device ready\", macOS never launched it)")
            self.setStage(.cameraProcessMissing)
        }
    }

    private var isStarting: Bool {
        if case .starting = _stage { return true }
        return false
    }

    /// MUST be read under `lock`.
    private var isCameraProcessMissing: Bool {
        if case .cameraProcessMissing = _stage { return true }
        return false
    }

    // MARK: - The camera appearing is an EVENT

    private var deviceListener: CMIOObjectPropertyListenerBlock?

    /// CoreMediaIO says when the machine's camera list changes. That is exactly the moment
    /// our answer changes — the extension finished launching, or the operator approved it in
    /// System Settings — so the card follows on its own, with no polling, no timer, and
    /// nothing for the operator to toggle off and on to "wake it up".
    private func watchDeviceList() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshFromDeviceList(fallback: .starting)
        }
        if CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject),
                                              &address, queue, block) == noErr {
            deviceListener = block
        }
    }

    private func stopWatchingDeviceList() {
        guard let listener = deviceListener else { return }
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject),
                                              &address, queue, listener)
        deviceListener = nil
    }

    /// Re-derive the stage from the machine, never from memory. `fallback` is what to say
    /// when the camera is not in the list — "starting" while we are waiting for it to appear,
    /// but the installer's own verdict (awaiting approval, cannot install) outranks that.
    private func refreshFromDeviceList(fallback: Stage) {
        // ALWAYS on our own queue.  Enumerating CoreMediaIO devices runs an AVFoundation
        // discovery first (see CMIOSinkConnection.refreshCameraList) and both are synchronous
        // calls into other processes — cheap, but not free, and two callers arrive on the main
        // thread: the activation completion, which macOS delivers on .main, and the operator
        // dismissing the message on the card.  Neither is worth a stutter in the multiview.
        guard DispatchQueue.getSpecific(key: Self.queueKey) != nil else {
            queue.async { [weak self] in self?.refreshFromDeviceList(fallback: fallback) }
            return
        }
        let present = CMIOSinkConnection.deviceExists(uuid: kVCamDeviceUUID)
        lock.lock()
        let live = _isLive
        let open = sink != nil
        // A verdict that the camera is UNREACHABLE outranks the caller's fallback.  Every path
        // here passes `.starting`, which says nothing on the card — so once the timeout had
        // concluded the camera would never appear, the very next device-list notification
        // erased that conclusion and left the output switched on, silent, and doing nothing.
        // The operator got no message at all, which is the one outcome this card exists to
        // prevent.  It clears itself the moment the device really is there (below).
        let stuck = !present && isCameraProcessMissing
        let verdict = installVerdict
        lock.unlock()
        if !present { setStage(stuck ? .cameraProcessMissing : (verdict ?? fallback)); return }
        if live, open { setStage(.live); return }
        // The camera is there. If the operator has this output switched on but we never
        // managed to open the sink — the usual case right after an approval — open it now.
        if live { openSink() } else { setStage(.ready) }
    }

    // MARK: - Lifecycle (the toggle owns the SINK, nothing else)

    func start() {
        lock.lock(); _isLive = true; lock.unlock()
        startPacing()
        // ASK MACOS HERE, on the first switch-on, and never merely because the card exists.
        //
        // Installing a camera extension makes macOS demand an approval in System Settings. Doing
        // that the moment the card is created would put a security prompt in front of someone who
        // has just opened the app for the first time and asked for nothing - and a prompt nobody
        // understands is a prompt people decline. Switching the output on IS the request; that is
        // also where OBS puts it. `activateOnce` still guarantees one request per app session, so
        // a toggle worked back and forth cannot churn the extension.
        installer.activateOnce { [weak self] result in
            guard let self else { return }
            let verdict: Stage?
            switch result {
            case .installed:         verdict = nil
            case .needsApproval:     verdict = .awaitingApproval
            case .notInApplications: verdict = .needsInstall("Move Airlive Bridge to /Applications - macOS only loads a camera extension from there.")
            case .afterRestart:      verdict = .needsInstall("Restart the Mac to finish installing the virtual camera.")
            case .failed(let why):   verdict = .needsInstall(why)
            }
            self.lock.lock(); self.installVerdict = verdict; self.lock.unlock()
            if let verdict {
                self.setStage(verdict)
            } else {
                // Installed (on a first install: right after the operator approved it). Now the
                // camera has to APPEAR; if it does not, the card says so and names the remedy -
                // only while the output is on (switched off meanwhile, nothing is waiting for it).
                self.refreshFromDeviceList(fallback: .starting)
                self.lock.lock(); let on = self._isLive; self.lock.unlock()
                if on { self.expectDeviceShortly() }
            }
        }
        openSink()
    }

    func stop() {
        // The flag drops HERE, not inside the async block, exactly as `start()` raises it
        // here. Asymmetry was a race with teeth: switch off then on, and the teardown block —
        // queued first, run first — cleared the flag that `start()` had already set, so
        // `openSink` found `wanted == false` and returned without a word. The card still read
        // "on", because that is the same flag start() had set. Off-then-on silently produced
        // a camera that was never opened.
        lock.lock()
        _isLive = false
        // The connection is taken OUT of the object here, synchronously, and handed to the
        // block below — which therefore no longer needs `self` to exist by the time it runs.
        // Deleting the card releases this output immediately, and the teardown used to hang
        // off a weak self: the object died first, the block returned at its `guard`, and the
        // extension was never told to stop.  Its stream stayed open with a client that was
        // gone.  Ownership, not lifetime, is what closes a stream.
        let connection = sink
        sink = nil
        _lastFrame = nil
        _waiting.removeAll()
        if let t = transfer { VTPixelTransferSessionInvalidate(t) }
        transfer = nil
        pool = nil
        lock.unlock()
        stopPacing()
        queue.async { [weak self] in
            // Outside the lock: this talks to the extension's process and its own close()
            // must not be able to park an incoming frame behind it.
            if let reason = connection?.close() { self?.setStage(.failed(reason)) }
            else { self?.refreshFromDeviceList(fallback: .starting) }
        }
        // The extension is deliberately LEFT INSTALLED: uninstalling on every toggle would
        // re-prompt the operator for approval each time, and a camera that vanishes from an
        // app's list mid-show is worse than one that shows a "no program" placeholder.
    }

    /// Open the sink and start pushing. Safe to call repeatedly — the device appearing, the
    /// operator approving and the toggle going on all land here, and only the first one that
    /// finds a real camera does any work.
    private func openSink() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let alreadyOpen = self.sink != nil
            let wanted = self._isLive
            self.lock.unlock()
            guard wanted, !alreadyOpen else { return }

            let connection = CMIOSinkConnection()
            if let reason = connection.open(deviceUUID: kVCamDeviceUUID) {
                // Not a verdict on the camera: it may simply not have appeared yet. The
                // device-list watcher will bring us back here the moment it does.  Logged
                // either way — a silent stage is fine on the card, never in the log.
                let present = CMIOSinkConnection.deviceExists(uuid: kVCamDeviceUUID)
                vcamOutLog.notice("sink NOT opened — \(reason, privacy: .public) (device present: \(present))")
                self.lock.lock()
                let stuck = self.isCameraProcessMissing
                let verdict = self.installVerdict
                self.lock.unlock()
                self.setStage(present ? .failed(reason) : (stuck ? .cameraProcessMissing : (verdict ?? .starting)))
                return
            }
            self.lock.lock()
            self.sink = connection
            self.framesSent = 0; self.framesDropped = 0
            self.appReceiving = false; self.lastTaken = 0; self.lastTakenAt = 0
            self.reportedOnce = false      // a new session may fail in a new way
            self.lock.unlock()
            vcamOutLog.notice("sink opened — pushing program into the camera")
            self.setStage(.live)
        }
    }

    func clearError() { refreshFromDeviceList(fallback: .starting) }

    /// Send frames at `resolution` from the next frame on. The converter is rebuilt for the new
    /// size; in-flight conversion holds the same lock, so no frame is cut in half.
    func setResolution(_ resolution: VirtualCameraResolution) {
        lock.lock()
        defer { lock.unlock() }
        guard resolution != _resolution else { return }
        _resolution = resolution
        if let t = transfer { VTPixelTransferSessionInvalidate(t) }
        transfer = nil
        pool = nil
        vcamOutLog.notice("resolution → \(resolution.title, privacy: .public)")
    }

    // MARK: - Frames

    /// A program frame arrived: it waits for the next tick (see "Pacing"). Nothing else happens on
    /// the caller's thread - the receiver's queue, which also serves its network and every tile.
    func send(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {
        // `timeNs` is unused on purpose: what reaches the camera is stamped with the tick it goes
        // out on. The parameter stays because the VideoOutput protocol has it and every other
        // output needs it.
        lock.lock(); defer { lock.unlock() }
        guard _isLive else { return }
        _lastArrival = CACurrentMediaTime()
        _waiting.append(pixelBuffer)
        if _waiting.count > Self.maxWaiting { _waiting.removeFirst(_waiting.count - Self.maxWaiting) }
    }

    private func startPacing() {
        guard paceTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: paceQueue)
        let period = Self.nsPerSecond / Self.ticksPerSecond
        // A repeating dispatch timer keeps its own deadlines on the start + k x interval grid, so
        // it does not drift; `deliverTick` still numbers each tick from the clock, not by counting.
        t.schedule(deadline: .now(), repeating: .nanoseconds(Int(period)), leeway: .nanoseconds(0))
        t.setEventHandler { [weak self] in self?.deliverTick() }
        paceQueue.async { [weak self] in
            self?.gridOriginNs = DispatchTime.now().uptimeNanoseconds
            self?.lastTick = -1
            self?.framesRepeated = 0
            self?.framesSkipped = 0
            self?.surplusTicks = 0
        }
        t.resume()
        paceTimer = t
    }

    private func stopPacing() {
        paceTimer?.cancel()
        paceTimer = nil
    }

    /// One tick: hand the camera exactly one frame - the oldest waiting one, or the last one again.
    /// On `paceQueue`.
    private func deliverTick() {
        // The tick this wake-up belongs to, from the clock: a late wake-up still stamps its own
        // grid time, and two wake-ups can never claim the same tick. The camera's clock is the
        // host clock, which is what `uptimeNanoseconds` reads (mach absolute time).
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let elapsed = Int64(nowNs &- gridOriginNs)
        let nearest = (elapsed * Self.ticksPerSecond + Self.nsPerSecond / 2) / Self.nsPerSecond
        let tick = max(nearest, lastTick + 1)
        lastTick = tick
        let tickNs = Int64(gridOriginNs) + tick * Self.nsPerSecond / Self.ticksPerSecond
        let tickTime = CMTime(value: tickNs, timescale: CMTimeScale(Self.nsPerSecond))

        lock.lock()
        guard _isLive, let sink = self.sink else { lock.unlock(); return }
        var next: CVPixelBuffer?
        if !_waiting.isEmpty {
            next = _waiting.removeFirst()
            // Still two waiting after this one, tick after tick: the phone has gained a whole
            // frame on the Mac. Drop the older of them - the delay goes back to one frame.
            if _waiting.count >= 2 {
                surplusTicks += 1
                if surplusTicks >= Self.surplusPersistence {
                    framesSkipped &+= UInt64(_waiting.count - 1)
                    _waiting.removeFirst(_waiting.count - 1)
                    surplusTicks = 0
                }
            } else {
                surplusTicks = 0
            }
        }
        let repeatFrame = next == nil && CACurrentMediaTime() - _lastArrival < Self.holdLimit ? _lastFrame : nil
        lock.unlock()

        // Before the room check: when nobody reads the camera there is never room, and that is
        // exactly the moment "no app is receiving" has to be noticed.
        noteReceiving(sink)
        guard next != nil || repeatFrame != nil else { return }
        // Nobody watching (or the extension has not taken the last frame yet): skip before the
        // conversion, not after it.
        guard sink.hasRoom else { framesDropped &+= 1; return }

        let frame: CVPixelBuffer
        if let next {
            guard let ready = cameraReady(next) else {
                reportOnce("The program couldn't be converted for the virtual camera.")
                return
            }
            frame = ready
            lock.lock(); if _isLive { _lastFrame = ready }; lock.unlock()   // never outlives a stop()
            probe(ready)
        } else if let repeatFrame {
            frame = repeatFrame
            framesRepeated &+= 1
        } else {
            return
        }
        switch sink.send(frame, presentationTime: tickTime) {
        case .sent:      framesSent &+= 1
        // Nobody has the camera open — the extension stops draining and the queue stays full.
        // That is the normal resting state of a virtual camera, not a fault, and calling it
        // one told operators the camera was broken whenever no app happened to have it open.
        case .queueFull: framesDropped &+= 1
        case .failed:    reportOnce("The virtual camera stopped accepting frames — switch this output off and on.")
        }
    }

    /// The program frame as the camera publishes it.
    ///
    /// PASS-THROUGH is the point of this function, not an optimisation of it: when the
    /// frame is already the camera's format and size — which is every frame of a normal
    /// 1080p program — the very same pixels the OBS output carries are handed to the
    /// camera, so the two cannot look different.  Converting instead meant choosing a
    /// colour matrix and a range, and choosing either differently from the source visibly
    /// changed the picture.
    private func cameraReady(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        // The IOSurface is not a detail of the pass-through, it is the reason one is possible:
        // the frame crosses into another process as a surface handle, so a buffer without one
        // has nothing to hand over and arrives as no picture at all.  Every frame we have ever
        // seen here carries one (VideoToolbox and AVFoundation both allocate that way) — this
        // sends the one that does not through the converter, whose pool is IOSurface-backed,
        // instead of silently publishing a black camera.
        lock.lock(); let target = _resolution; lock.unlock()
        if CVPixelBufferGetPixelFormatType(src) == kVCamPixelFormat,
           CVPixelBufferGetWidth(src) == target.width,
           CVPixelBufferGetHeight(src) == target.height,
           CVPixelBufferGetIOSurface(src) != nil {
            return src
        }
        // The converter is built and used under `lock`, but a failure is REPORTED after
        // releasing it — reporting takes the same lock, and NSLock is not recursive.
        lock.lock()
        var failure: String?
        if transfer == nil { failure = buildConverterLocked() }
        let converted = failure == nil ? convertLocked(src) : nil
        lock.unlock()
        if let failure { reportOnce(failure) }
        return converted
    }

    /// Built on FIRST use, not at start: a program that is already the right shape never
    /// needs it, and an unused VT session plus a 25 MB pool of IOSurfaces is exactly the
    /// kind of idle allocation that shows up as heat.
    private func buildConverterLocked() -> String? {
        guard transfer == nil else { return nil }
        let st = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
        guard st == noErr, transfer != nil else {
            return "Couldn't create the video converter (\(st))."
        }
        if let t = transfer {
            // Letterbox rather than crop: the program may be a portrait phone, and silently
            // cutting the operator's framing is worse than bars.
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_ScalingMode,
                                 value: kVTScalingMode_Letterbox)
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kVCamPixelFormat,
            kCVPixelBufferWidthKey as String: _resolution.width,
            kCVPixelBufferHeightKey as String: _resolution.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let ps = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        guard ps == kCVReturnSuccess, pool != nil else {
            return "Couldn't allocate the video buffer pool (\(ps))."
        }
        return nil
    }

    private func convertLocked(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        guard let transfer, let pool else { return nil }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) == kCVReturnSuccess,
              let dst else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: src, to: dst) == noErr else { return nil }
        // Carry the source's colour tags across.  A pool buffer is born untagged, and an
        // untagged frame is interpreted by whatever the consumer assumes — which is how a
        // correctly converted picture still ends up looking wrong.
        CVBufferPropagateAttachments(src, dst)
        return dst
    }

    /// 1 Hz luma reading of the frame handed to the camera.  Paired with the identical probe
    /// on the extension's side (VCamLog.swift), so "the picture looks wrong" becomes a
    /// comparison of two numbers rather than an argument about tags.
    private var lastProbe = Date.distantPast
    /// On `paceQueue`. See `appReceiving`.
    private func noteReceiving(_ sink: CMIOSinkConnection) {
        let taken = sink.framesTakenByCamera
        let now = CACurrentMediaTime()
        if taken != lastTaken {
            lastTaken = taken
            lastTakenAt = now
            guard !appReceiving else { return }
            appReceiving = true
            vcamOutLog.notice("an app is receiving the virtual camera")
        } else if appReceiving, now - lastTakenAt > Self.receivingWindow {
            appReceiving = false
            vcamOutLog.notice("no app is receiving the virtual camera - frames are not being taken")
        }
    }

    private func probe(_ buffer: CVPixelBuffer) {
        guard Date().timeIntervalSince(lastProbe) >= 1.0 else { return }
        lastProbe = Date()
        let passthrough = CVPixelBufferGetPixelFormatType(buffer) == kVCamPixelFormat
        vcamOutLog.notice("sending \(passthrough ? "pass-through" : "CONVERTED", privacy: .public) at 30 fps — enqueued \(self.framesSent), repeated \(self.framesRepeated), skipped \(self.framesSkipped), no room for \(self.framesDropped), \(self.appReceiving ? "an app is receiving" : "no app receiving", privacy: .public) — \(LumaProbe.describe(buffer), privacy: .public)")
    }

    private var reportedOnce = false
    private func reportOnce(_ message: String) {
        lock.lock(); let already = reportedOnce; reportedOnce = true; lock.unlock()
        if !already { setStage(.failed(message)) }
    }
}
