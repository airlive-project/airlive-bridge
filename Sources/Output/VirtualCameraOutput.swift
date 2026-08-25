// VirtualCameraOutput.swift — PROGRAM → macOS Virtual Camera.
//
// Publishes the program feed as a system camera, so Zoom / Meet / Teams / QuickTime
// can pick "Airlive Virtual Camera" from their normal camera list.  Unlike every other
// output there is no socket and no encode: frames are converted to the extension's
// fixed 1080p BGRA and dropped into a shared App Group slot (see SharedFrameBuffer),
// which the extension — a separate process macOS launches on demand — reads.
//
// Two things make this output unlike the others, and both are macOS rules, not ours:
//   • The extension can ONLY load when the Bridge runs from /Applications.
//   • The FIRST activation asks the operator to approve it in System Settings.
// Neither is an error state, so both are reported as plain guidance on the card.

import Foundation
import CoreVideo
import VideoToolbox
import SystemExtensions

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

    /// Publishing happens here, never on the caller's thread: the copy into shared
    /// memory is a full 1080p frame and the caller may be the main thread.
    private let queue = DispatchQueue(label: "studio.airlive.bridge.vcam", qos: .userInitiated)
    private var writer: SharedFrameWriter?

    /// Hardware format conversion + scale: whatever the program is (NV12 from a camera,
    /// BGRA from a capture card, any size) becomes the one format the extension declares.
    /// VTPixelTransferSession rather than CoreImage — a fixed-function block instead of a
    /// filter graph, which is the difference between "free" and "warm" per frame.
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    private let installer = SystemExtensionInstaller()

    init(id: UUID = UUID(), label: String = "Virtual Camera") {
        self.id = id
        self.label = label
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let w = SharedFrameWriter() else {
                self.setError("Couldn't open the shared frame buffer — reinstall Airlive Bridge.")
                return
            }
            self.writer = w
            self.buildConverter()
            self.lock.lock(); self._isLive = true; self._lastError = nil; self.lock.unlock()
        }
        // Activation talks to macOS on the main thread and may show the approval prompt.
        installer.activate { [weak self] result in
            switch result {
            case .installed:      self?.setError(nil)
            case .needsApproval:  self?.setError("Approve “Airlive Virtual Camera” in System Settings → General → Login Items & Extensions.")
            case .notInApplications: self?.setError("Move Airlive Bridge to /Applications — macOS only loads a camera extension from there.")
            case .failed(let m):  self?.setError(m)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.writer = nil
            if let t = self.transfer { VTPixelTransferSessionInvalidate(t) }
            self.transfer = nil
            self.pool = nil
            self.lock.lock(); self._isLive = false; self.lock.unlock()
        }
        // The extension is deliberately LEFT INSTALLED: uninstalling on every toggle would
        // re-prompt the operator for approval each time, and a camera that vanishes from
        // Zoom's list mid-call is worse than one that shows a "no program" placeholder.
    }

    func clearError() { lock.lock(); _lastError = nil; lock.unlock() }

    // MARK: - Frames

    func send(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {
        guard isLive else { return }
        // Convert on the CALLER's thread (hardware, sub-millisecond) because the contract
        // forbids retaining `pixelBuffer` past this call; the expensive part — the copy
        // into shared memory — then happens on our own queue.
        guard let converted = convert(pixelBuffer) else { return }
        queue.async { [weak self] in self?.writer?.publish(converted) }
    }

    private func buildConverter() {
        guard transfer == nil else { return }
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
        if let t = transfer {
            // Letterbox rather than crop: the program may be a portrait phone, and silently
            // cutting the operator's framing is worse than bars.
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_ScalingMode,
                                 value: kVTScalingMode_Letterbox)
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: SharedFrame.width,
            kCVPixelBufferHeightKey as String: SharedFrame.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
    }

    private func convert(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        guard let transfer, let pool else { return nil }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) == kCVReturnSuccess,
              let dst else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: src, to: dst) == noErr else { return nil }
        return dst
    }

    private func setError(_ message: String?) {
        lock.lock(); _lastError = message; lock.unlock()
    }
}
