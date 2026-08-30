// CMIOSinkConnection.swift — the Bridge's end of the virtual camera.
//
// Finds our camera extension among the machine's CoreMediaIO devices and opens its SINK
// stream — the one that runs into the extension.  Frames are enqueued as IOSurface-backed
// sample buffers, so crossing to the extension's process hands over a surface rather than
// copying pixels.
//
// This replaced a shared memory-mapped file, which could never have worked: macOS runs a
// camera extension as its own user (`_cmiodalassistants`), so every path keyed to a home
// directory — App Group container included — resolves to two different places on the two
// sides.  CoreMediaIO's sink stream is the transport designed to cross exactly that
// boundary.

import Foundation
import CoreMedia
import CoreVideo
import CoreMediaIO
import AVFoundation
import os

/// Same subsystem the extension logs under, so ONE `log stream` command shows both ends of
/// the hop and the break is visible as the line that never appears.
private let sinkLog = Logger(subsystem: "studio.airlive.vcam", category: "bridge")

/// What happened to one frame.  `queueFull` is NOT a failure: it is what "nobody has the
/// camera open" looks like from this side, and reporting it as an error told the operator the
/// camera was broken whenever Zoom simply wasn't running.
enum SinkSendResult {
    case sent
    case queueFull
    case failed
}

final class CMIOSinkConnection {

    private var deviceID: CMIODeviceID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var started = false
    /// `send` runs on the program bus and `close` on the output's own queue; the lock is
    /// what stops a frame being enqueued into a queue that is being torn down.
    private let lock = NSLock()
    private var sent: UInt64 = 0
    private var lastLog = Date.distantPast

    /// Open the sink on the device with `deviceUUID`.  Returns a human-readable reason on
    /// failure rather than a status code — every failure here is something the operator can
    /// act on (approve the extension, update the app).
    func open(deviceUUID: String) -> String? {
        guard let dev = findDevice(uuid: deviceUUID) else {
            return "Virtual camera not found — approve “\(kVCamDeviceName)” in System Settings → General → Login Items & Extensions."
        }
        deviceID = dev
        sinkLog.notice("found virtual camera device \(dev)")
        guard let sink = findSinkStream(device: dev) else {
            // The device exists but exposes no inbound stream: an older extension build is
            // still the one macOS has staged.
            return "The installed virtual camera is an older version — quit every app using it, then relaunch Airlive Bridge."
        }
        streamID = sink

        var q: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &q) == noErr,
              let queueRef = q?.takeRetainedValue() else {
            return "Couldn't open the virtual camera's frame queue."
        }
        queue = queueRef

        let st = CMIODeviceStartStream(dev, sink)
        guard st == noErr else {
            sinkLog.error("CMIODeviceStartStream failed (\(st))")
            return "Couldn't start sending to the virtual camera."
        }
        started = true
        sent = 0
        sinkLog.notice("sink open — stream \(sink), queue capacity \(CMSimpleQueueGetCapacity(queueRef))")
        return nil
    }

    /// Returns a reason if the stream could not be stopped.
    ///
    /// The stop is issued OUTSIDE the lock on purpose: it is a synchronous call into another
    /// process, and holding the lock across it would park the next frame — arriving on the
    /// program bus — until that process answered, stalling every other output behind it.
    /// Dropping `started` first is what makes that safe: from here on `send` refuses anyway.
    @discardableResult
    func close() -> String? {
        lock.lock()
        let wasStarted = started
        let dev = deviceID, stream = streamID, total = sent
        started = false
        queue = nil
        lock.unlock()

        guard wasStarted else { return nil }
        let st = CMIODeviceStopStream(dev, stream)
        guard st == noErr else {
            // The one link in the chain that used to discard its result.  If this fails, the
            // extension never learns the Bridge stopped: it keeps believing frames are coming
            // and holds the placeholder back, so the camera freezes on its last picture with
            // nothing said anywhere.
            sinkLog.error("CMIODeviceStopStream failed (\(st)) — the extension still thinks we are pushing")
            return "Couldn't stop sending to the virtual camera — quit apps using it, then try again."
        }
        sinkLog.notice("sink closed cleanly after \(total) frames")
        return nil
    }

    /// Enqueue one frame in the camera's published format.  `timeNs` is the program's host time.
    /// Returns whether the frame actually reached the queue — the caller counts these, so a
    /// camera that is "on" but never delivering can say so instead of showing black.
    @discardableResult
    func send(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) -> SinkSendResult {
        lock.lock(); defer { lock.unlock() }
        guard started, let queue else { return .failed }
        // One buffer deep by design: if the extension hasn't drained the previous frame, the
        // newest one is worth more than queueing both, so skip rather than pile up.  A queue
        // that STAYS full means the extension stopped draining because no app has the camera
        // open — checked before anything is built, so an unwatched camera costs one comparison
        // per frame and nothing else.
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return .queueFull }

        // The format description is derived FROM THE BUFFER, per frame, not built by hand
        // once.  A hand-built description carries no colour attachments, and CoreMediaIO
        // hands the consumer a sample whose description disagrees with its pixels — which
        // renders as black, silently.  (This is what Apple's own camera-extension sample
        // does on the sending side; the extension keeps a plain description because it only
        // declares the stream's shape.)
        var desc: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &desc) == noErr,
              let desc else { return .failed }

        // Host clock, not the program's timeline.  The sink's clock is the host clock; a
        // timestamp from the program's own timeline (which starts when the phone connects)
        // reads as wildly out of date and the frame is discarded downstream.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: kVCamFrameRate),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        _ = timeNs
        var sbuf: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pixelBuffer, dataReady: true,
                                                 makeDataReadyCallback: nil, refcon: nil,
                                                 formatDescription: desc,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sbuf) == noErr,
              let sbuf else { return .failed }

        // CMSimpleQueue holds UNRETAINED pointers: a successful enqueue hands our +1 over to
        // CoreMediaIO, which releases it downstream.  A FAILED enqueue hands over nothing,
        // so we must release it ourselves or leak ~8 MB per dropped frame.
        let boxed = Unmanaged.passRetained(sbuf)
        if CMSimpleQueueEnqueue(queue, element: boxed.toOpaque()) != noErr {
            boxed.release()
            return .failed
        }
        sent &+= 1
        if Date().timeIntervalSince(lastLog) >= 1.0 {
            lastLog = Date()
            sinkLog.notice("enqueued \(self.sent) frames total, queue depth \(CMSimpleQueueGetCount(queue))")
        }
        return .sent
    }

    /// Bring this process's view of the machine's cameras up to date.
    ///
    /// A camera that appears AFTER a process has already looked can stay invisible to it: the
    /// enumeration below answers from what CoreMediaIO knows, and in a long-running app that
    /// can be an older answer than the truth. It cost a whole afternoon — a fresh probe found
    /// the camera on its first try while the Bridge, running since before the extension
    /// launched, insisted it was not there.
    ///
    /// AVFoundation owns the camera lifecycle on macOS and notices new ones; asking it first
    /// is what makes the answer current. Cheap, and only asked when we are looking anyway.
    private func refreshCameraList() {
        // A camera extension is an EXTERNAL device to AVFoundation — under a name that
        // changed in macOS 14, hence the two spellings for one deployment target of 13.
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types.append(.external) } else { types.append(.externalUnknown) }
        _ = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                             mediaType: .video,
                                             position: .unspecified).devices
    }

    /// Is the camera published right now?  One enumeration, microseconds — cheap enough to
    /// ask on every device-list change instead of remembering an answer that goes stale.
    static func deviceExists(uuid: String) -> Bool {
        CMIOSinkConnection().findDevice(uuid: uuid) != nil
    }

    // MARK: - CoreMediaIO lookup

    private func findDevice(uuid: String) -> CMIODeviceID? {
        refreshCameraList()
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr
        else { return nil }

        for dev in devices where deviceUID(dev)?.caseInsensitiveCompare(uuid) == .orderedSame { return dev }
        return nil
    }

    private func deviceUID(_ device: CMIODeviceID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &value) == noErr,
              let uid = value?.takeRetainedValue() else { return nil }
        return uid as String
    }

    private func findSinkStream(device: CMIODeviceID) -> CMIOStreamID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [CMIOStreamID](repeating: 0, count: Int(size) / MemoryLayout<CMIOStreamID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &streams) == noErr else { return nil }

        // The direction value is INVERTED between the two APIs: a sink is `.sink` (1) in
        // CMIOExtensionStreamDirection but reads back as 0 here, where 0 means "output
        // stream" from the host's point of view.  Matching on the number, not on index,
        // keeps this correct regardless of the order the extension added its streams.
        for stream in streams where streamDirection(stream) == 0 { return stream }
        return nil
    }

    private func streamDirection(_ stream: CMIOStreamID) -> UInt32? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(stream, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr
        else { return nil }
        return value
    }
}
