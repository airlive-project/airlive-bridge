// VirtualCameraOutput.swift — PROGRAM → macOS Virtual Camera.
//
// Publishes the program feed as a system camera, so Zoom / Meet / Teams / QuickTime
// can pick "Airlive Bridge Virtual Camera" from their normal camera list.  Unlike every
// other output there is no socket and no encode: frames are converted to the extension's
// fixed 1080p BGRA and pushed into the extension's SINK stream (see CMIOSinkConnection),
// which the extension — a separate process macOS launches on demand — pulls from.
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
import SystemExtensions
import os

/// Same subsystem the extension logs under — one `log show` shows both ends of the hop.
private let vcamOutLog = Logger(subsystem: "studio.airlive.vcam", category: "bridge")

/// The virtual camera's fixed wire size and cadence.  The extension declares the same
/// values; they are a compile-time contract between the two targets, not negotiated.
let kVCamWidth: Int32 = 1920
let kVCamHeight: Int32 = 1080
let kVCamFrameRate: Int32 = 30
/// The camera publishes 8-bit 4:2:0 bi-planar VIDEO RANGE — the exact format the program
/// decoder produces, so the normal case is a pass-through with no conversion at all.
/// Declared identically by the extension (AirliveProviderSource); the two are one contract.
let kVCamPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
/// Device identity the extension publishes — how we find it among all cameras.
let kVCamDeviceUUID = "6F1B7A54-2C3E-4B7E-9E4D-A1C0D2E3F4A5"
/// The camera's name as every OTHER app lists it.  Declared by the extension
/// (AirliveProviderSource) and repeated here for the UI: the operator has to recognise
/// the same words in Zoom's picker, so the two must never drift apart.
let kVCamDeviceName = "Airlive Bridge Virtual Camera"

final class VirtualCameraOutput: NSObject, VideoOutput {

    let id: UUID
    var label: String
    let kind: OutputKind = .vcam
    var config: String = ""

    /// Where the camera actually is right now.  Every value is set by a real event —
    /// an activation callback, the camera list changing, the sink opening — so the card
    /// cannot show a state the machine has left.
    private enum Stage {
        case installing                 // request submitted, nothing to say yet
        case awaitingApproval           // macOS is asking the operator
        case needsInstall(String)       // it cannot be installed, and why
        case starting                   // approved; the device has not appeared YET (transient)
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
            case .installing, .starting, .ready, .live: return nil
            }
        }
    }

    private let lock = NSLock()
    private var _stage: Stage = .installing
    private var _isLive = false
    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return _isLive }
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return _stage.message }

    /// Wired by BridgeModel.configureOutput, exactly like every other output's — without it
    /// nothing this class learns can reach the card, and every fix below would be invisible.
    var onStateChanged: (() -> Void)?

    private func setStage(_ stage: Stage) {
        lock.lock(); _stage = stage; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStateChanged?() }
    }

    /// Opening and closing the sink talks to CoreMediaIO and can block; frames do NOT
    /// come through here — see `send`.
    private let queue = DispatchQueue(label: "studio.airlive.bridge.vcam", qos: .userInitiated)
    private var sink: CMIOSinkConnection?

    /// Fallback conversion ONLY — built lazily the first time a frame arrives that is not
    /// already the camera's format and size (an AirPlay mirror, a capture card at 720p, and
    /// the black "no program" filler, which is BGRA).  The normal path never touches it: the
    /// program decoder's buffers go across untouched.  VTPixelTransferSession rather than
    /// CoreImage — a fixed-function block instead of a filter graph.
    ///
    /// GUARDED BY `lock`: `send` runs on the program bus and `stop` on this output's own
    /// queue, so an unguarded pair could invalidate the session while a frame was mid-transfer.
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    private let installer = SystemExtensionInstaller()

    /// Frames sent / skipped since start.  Touched only from the program bus, which delivers
    /// frames one at a time; they exist so the log can answer "on but blank" without guessing.
    private var framesSent: UInt64 = 0
    private var framesDropped: UInt64 = 0

    init(id: UUID = UUID(), label: String = "Virtual Camera") {
        self.id = id
        self.label = label
        super.init()
        watchDeviceList()
        install()
    }

    deinit {
        stopWatchingDeviceList()
    }

    // MARK: - Installing the camera (ONCE, because the card exists)

    /// Ask macOS for the camera. Runs when the card is created — adding a Virtual Camera
    /// output IS the request for one — and never again for the life of this output.
    ///
    /// It used to run on every toggle-on, and that was the whole disease: each call submits
    /// an activation request, and a request that replaces the staged extension tears its
    /// process down and relaunches it, which unpublishes the device for a moment. The lookup
    /// running beside it then failed and wrote "camera not found" about a camera that exists.
    private func install() {
        installer.activate { [weak self] result in
            guard let self else { return }
            switch result {
            case .installed:
                // Approved and staged. The device usually appears within a second, and the
                // list watcher below is what notices; do not call that gap an error.
                self.refreshFromDeviceList(fallback: .starting)
            case .needsApproval:
                self.setStage(.awaitingApproval)
            case .notInApplications:
                self.setStage(.needsInstall("Move Airlive Bridge to /Applications — macOS only loads a camera extension from there."))
            case .failed(let why):
                self.setStage(.needsInstall(why))
            }
        }
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
        let present = CMIOSinkConnection.deviceExists(uuid: kVCamDeviceUUID)
        lock.lock(); let live = _isLive; let open = sink != nil; lock.unlock()
        if !present { setStage(fallback); return }
        if live, open { setStage(.live); return }
        // The camera is there. If the operator has this output switched on but we never
        // managed to open the sink — the usual case right after an approval — open it now.
        if live { openSink() } else { setStage(.ready) }
    }

    // MARK: - Lifecycle (the toggle owns the SINK, nothing else)

    func start() {
        lock.lock(); _isLive = true; lock.unlock()
        openSink()
    }

    func stop() {
        // The flag drops HERE, not inside the async block, exactly as `start()` raises it
        // here. Asymmetry was a race with teeth: switch off then on, and the teardown block —
        // queued first, run first — cleared the flag that `start()` had already set, so
        // `openSink` found `wanted == false` and returned without a word. The card still read
        // "on", because that is the same flag start() had set. Off-then-on silently produced
        // a camera that was never opened.
        lock.lock(); _isLive = false; lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let connection = self.sink
            self.sink = nil
            if let t = self.transfer { VTPixelTransferSessionInvalidate(t) }
            self.transfer = nil
            self.pool = nil
            self.lock.unlock()
            // Outside the lock: this talks to the extension's process and its own close()
            // must not be able to park an incoming frame behind it.
            if let reason = connection?.close() { self.setStage(.failed(reason)) }
            else { self.refreshFromDeviceList(fallback: .starting) }
        }
        // The extension is deliberately LEFT INSTALLED: uninstalling on every toggle would
        // re-prompt the operator for approval each time, and a camera that vanishes from
        // Zoom's list mid-call is worse than one that shows a "no program" placeholder.
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
                self.setStage(present ? .failed(reason) : .starting)
                return
            }
            self.lock.lock()
            self.sink = connection
            self.framesSent = 0; self.framesDropped = 0
            self.reportedOnce = false      // a new session may fail in a new way
            self.lock.unlock()
            vcamOutLog.notice("sink opened — pushing program into the camera")
            self.setStage(.live)
        }
    }

    func clearError() { refreshFromDeviceList(fallback: .starting) }

    // MARK: - Frames

    func send(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {
        lock.lock(); let live = _isLive; let sink = self.sink; lock.unlock()
        guard live, let sink else { return }
        // Enqueued on the CALLER's thread, deliberately.  The contract forbids holding the
        // buffer past this call, and the enqueue itself is a pointer push into a lock-free
        // queue — hopping to another thread would mean copying a full 1080p frame to avoid
        // a few microseconds of work.
        guard let frame = cameraReady(pixelBuffer) else {
            reportOnce("The program couldn't be converted for the virtual camera.")
            return
        }
        probe(frame)
        switch sink.send(frame, timeNs: timeNs) {
        case .sent:      framesSent &+= 1
        // Nobody has the camera open — the extension stops draining and the queue stays full.
        // That is the normal resting state of a virtual camera, not a fault, and calling it
        // one told operators the camera was broken whenever Zoom simply wasn't running.
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
        if CVPixelBufferGetPixelFormatType(src) == kVCamPixelFormat,
           CVPixelBufferGetWidth(src) == Int(kVCamWidth),
           CVPixelBufferGetHeight(src) == Int(kVCamHeight) {
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
            kCVPixelBufferWidthKey as String: Int(kVCamWidth),
            kCVPixelBufferHeightKey as String: Int(kVCamHeight),
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
    private func probe(_ buffer: CVPixelBuffer) {
        guard Date().timeIntervalSince(lastProbe) >= 1.0 else { return }
        lastProbe = Date()
        let passthrough = CVPixelBufferGetPixelFormatType(buffer) == kVCamPixelFormat
        vcamOutLog.notice("sending \(passthrough ? "pass-through" : "CONVERTED", privacy: .public) \(LumaProbe.describe(buffer), privacy: .public)")
    }

    private var reportedOnce = false
    private func reportOnce(_ message: String) {
        lock.lock(); let already = reportedOnce; reportedOnce = true; lock.unlock()
        if !already { setStage(.failed(message)) }
    }
}
