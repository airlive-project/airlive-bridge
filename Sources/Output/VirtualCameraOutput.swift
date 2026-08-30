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

import Foundation
import CoreVideo
import VideoToolbox
import SystemExtensions
import AppKit    // one notification: the operator returning from System Settings (see watchForApproval)
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

    private let lock = NSLock()
    private var _isLive = false
    private var _lastError: String?
    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return _isLive }
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return _lastError }

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
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let connection = CMIOSinkConnection()
            if let reason = connection.open(deviceUUID: kVCamDeviceUUID) {
                // The extension isn't there or isn't the build we expect — say which, and
                // do NOT claim to be live.
                self.setError(reason)
                return
            }
            self.lock.lock()
            self.sink = connection
            self.framesSent = 0; self.framesDropped = 0
            self.reportedOnce = false          // a new session may fail in a new way
            self._isLive = true
            // Do NOT clear an existing message here: the installer runs in parallel and may
            // already have said "restart the Mac to finish installing".  Opening the sink
            // SUCCEEDS in that case — against the outgoing extension, which is still live —
            // and wiping the message left the operator running yesterday's build with no hint.
            self.lock.unlock()
        }
        // Activation talks to macOS on the main thread and may show the approval prompt.
        watchForApproval()
        installer.activate { [weak self] result in
            switch result {
            case .installed:      self?.sinkOpenedOrRetry()
            case .needsApproval:  self?.setError("Approve “\(kVCamDeviceName)” in System Settings → General → Login Items & Extensions.")
            case .notInApplications: self?.setError("Move Airlive Bridge to /Applications — macOS only loads a camera extension from there.")
            case .failed(let m):  self?.setError(m)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self._isLive = false                        // stop send() FIRST
            let connection = self.sink
            self.sink = nil
            if let t = self.transfer { VTPixelTransferSessionInvalidate(t) }
            self.transfer = nil
            self.pool = nil
            self.lock.unlock()
            // Outside the lock: this talks to the extension's process and its own close()
            // must not be able to park an incoming frame behind it.
            if let reason = connection?.close() { self.setError(reason) }
        }
        DispatchQueue.main.async { [weak self] in self?.stopWatchingForApproval() }
        // The extension is deliberately LEFT INSTALLED: uninstalling on every toggle would
        // re-prompt the operator for approval each time, and a camera that vanishes from
        // Zoom's list mid-call is worse than one that shows a "no program" placeholder.
    }

    func clearError() { lock.lock(); _lastError = nil; lock.unlock() }

    /// Watches for the operator coming back from System Settings.
    ///
    /// Approving an extension happens in another app, and the callback that tells us it
    /// finished does not always arrive — it certainly does not when the request was made
    /// before the approval.  Rather than leaving a stale "approve this" on the card forever,
    /// the sink is retried the moment the Bridge is frontmost again: by then the operator has
    /// either approved it or not, and the answer is one cheap device lookup away.
    private var activationObserver: NSObjectProtocol?

    private func watchForApproval() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isLive == false || self.lastError != nil else { return }
            self.sinkOpenedOrRetry()
        }
    }

    private func stopWatchingForApproval() {
        if let o = activationObserver { NotificationCenter.default.removeObserver(o) }
        activationObserver = nil
    }

    // MARK: - Frames

    /// Open the sink now that the extension is installed.
    ///
    /// On a FIRST activation the two halves of `start()` race and the sink half always loses:
    /// the device does not exist yet, so it fails immediately and gives up. The operator then
    /// approves the extension in System Settings — and nothing retried, so the card went quiet
    /// while the camera stayed dark until they toggled it off and on by hand.
    private func sinkOpenedOrRetry() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let alreadyOpen = self.sink != nil; self.lock.unlock()
            if alreadyOpen { self.setError(nil); return }
            let connection = CMIOSinkConnection()
            if let reason = connection.open(deviceUUID: kVCamDeviceUUID) { self.setError(reason); return }
            self.lock.lock()
            self.sink = connection
            self.framesSent = 0; self.framesDropped = 0
            self._isLive = true
            self._lastError = nil
            self.lock.unlock()
        }
    }

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
        case .failed:    reportOnce("The virtual camera stopped accepting frames — toggle this output off and on.")
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
        // releasing it — `setError` takes the same lock, and NSLock is not recursive.
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
        if !already { setError(message) }
    }

    private func setError(_ message: String?) {
        lock.lock(); _lastError = message; lock.unlock()
    }
}
