// AirliveDeviceSource.swift — the device, its outgoing stream, and its incoming sink.
//
// Two streams on one device, running opposite ways:
//   • SOURCE — what Zoom / Meet / QuickTime read.
//   • SINK   — what the Bridge writes into (see AirliveStreamSink).
//
// The device owns both timers, because the two are mutually exclusive: while the Bridge is
// pushing, the placeholder must stay quiet, and the moment it stops, the placeholder takes
// over again.  A camera that goes black when its app closes reads as broken, so "nothing on
// air" is stated in words instead.

import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import QuartzCore

final class AirliveDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var streamSource: AirliveStreamSource!
    private var streamSink: AirliveStreamSink!

    /// One queue for both timers, so the placeholder and the pull can never run
    /// concurrently and fight over the source stream.
    private let timerQueue = DispatchQueue(label: "studio.airlive.vcam.timer",
                                           qos: .userInteractive,
                                           autoreleaseFrequency: .workItem,
                                           target: .global(qos: .userInteractive))
    private var placeholderTimer: DispatchSourceTimer?
    private var sinkTimer: DispatchSourceTimer?

    /// True while the Bridge holds the sink open.  Gates the PULL timer only — never the
    /// picture.  What the camera shows is decided by whether frames actually arrive.
    private var sinkStarted = false

    /// When the last REAL frame was forwarded.  This, and nothing else, decides whether the
    /// camera shows the program or the placeholder.
    ///
    /// It used to be the `sinkStarted` flag, and that was the wrong question: a flag says what
    /// the Bridge announced, not what is happening. Announcements go missing — an app that
    /// quits without closing, a stop that never arrives, a sink opened while nothing is being
    /// pushed — and every one of those left the camera showing nothing at all, because the
    /// placeholder was suppressed on the strength of a promise. Frames are not a promise.
    ///
    /// Written from CoreMediaIO's own callback queue and read from `timerQueue`, so it is
    /// guarded: an unsynchronised double read/write across two queues is undefined behaviour
    /// even when it happens to work on every machine we own.
    private let frameClock = NSLock()
    private var _lastRealFrame: CFTimeInterval = 0
    private var lastRealFrame: CFTimeInterval {
        get { frameClock.lock(); defer { frameClock.unlock() }; return _lastRealFrame }
        set { frameClock.lock(); _lastRealFrame = newValue; frameClock.unlock() }
    }
    /// A quarter-second without a frame is a gap the viewer would see as a freeze, and short
    /// enough that the placeholder returns while they are still looking.
    private static let realFrameGrace: CFTimeInterval = 0.25

    private var format: CMFormatDescription!
    private var placeholder: CVPixelBuffer?
    /// The placeholder's OWN description, derived from its own buffer — see publishPlaceholder.
    private var placeholderFormat: CMFormatDescription?

    private let shownPlaceholder = RateLog("placeholder shown")

    private let pulled = RateLog("pulled from sink")
    private let forwarded = RateLog("forwarded to consumers")
    /// Only counts a REAL starvation — see `pullFrame`.  It used to count every empty poll,
    /// which meant it printed "60/s" while the camera was working perfectly, because the timer
    /// deliberately polls three times per frame.  A log line that cries wolf every second on a
    /// healthy machine is worse than no line at all.
    private let starved = RateLog("no frame ready at frame time")

    init(localizedName: String, deviceUUID: UUID, sourceUUID: UUID, sinkUUID: UUID) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceUUID,
                                     legacyDeviceID: nil, source: self)

        // The stream's format carries its COLOUR meaning, not just its size.  Declared with
        // no extensions, a camera hands the consumer bytes and no way to know what they are:
        // every app then falls back to its own assumption, and one that guesses full-range for
        // our video-range luma clips the shadows into flat patches with hard edges.  Rec.709
        // is what both decoders tag their output with, so this states the truth rather than
        // changing a single pixel.
        let colour: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
            kCMFormatDescriptionExtension_FullRangeVideo: false,
        ]
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kVCamPixelFormat,
                                       width: kVCamWidth, height: kVCamHeight,
                                       extensions: colour as CFDictionary,
                                       formatDescriptionOut: &format)

        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: format,
            maxFrameDuration: CMTime(value: 1, timescale: kVCamFrameRate),
            minFrameDuration: CMTime(value: 1, timescale: kVCamFrameRate),
            validFrameDurations: nil)

        streamSource = AirliveStreamSource(localizedName: kVCamDeviceName,
                                           streamID: sourceUUID, streamFormat: streamFormat, device: device)
        streamSink = AirliveStreamSink(localizedName: "\(kVCamDeviceName) Sink",
                                       streamID: sinkUUID, streamFormat: streamFormat, device: device)
        do {
            // ORDER MATTERS: the source must be stream 0 and the sink stream 1.  The app
            // selects the sink by direction, but index is the documented fallback and some
            // hosts assume it.
            try device.addStream(streamSource.stream)
            try device.addStream(streamSink.stream)
        } catch let e {
            fatalError("failed to add streams: \(e.localizedDescription)")
        }
        vcamLog.notice("device ready — \(localizedName, privacy: .public) \(kVCamWidth)x\(kVCamHeight)@\(kVCamFrameRate)")
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        // 'virt' — the four-char transport code macOS uses for a software device.
        if properties.contains(.deviceTransportType) { p.transportType = Int(0x76697274) }
        if properties.contains(.deviceModel) { p.model = kVCamDeviceName }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: - Sink: pull frames the Bridge pushed

    func startStreamingSink(client: CMIOExtensionClient) {
        timerQueue.async { [weak self] in
            guard let self else { return }
            self.sinkStarted = true
            vcamLog.notice("SINK started — Bridge is pushing")
            self.updateSinkTimer()
        }
    }

    func stopStreamingSink() {
        timerQueue.async { [weak self] in
            guard let self else { return }
            self.sinkStarted = false
            vcamLog.notice("SINK stopped — placeholder resumes")
            self.updateSinkTimer()
        }
    }

    /// The pull timer runs only when BOTH ends are real: the Bridge is pushing AND some app
    /// actually has the camera open.  Draining frames nobody will ever see is work for
    /// nobody — and at 90 Hz it is a wake-up every 11 ms, forever, for a camera sitting idle
    /// in a list.  With the timer stopped the queue simply fills, and the Bridge stops
    /// building frames it cannot deliver.
    ///
    /// MUST be called on `timerQueue`.
    private func updateSinkTimer() {
        let wanted = sinkStarted && streamSource.isStreaming
        if wanted, sinkTimer == nil {
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
            // Deliberately THREE TIMES the frame rate.  The queue is one buffer deep, so
            // oversampling the pull keeps it drained and the latency at one frame instead
            // of letting frames sit waiting for the next tick.
            t.schedule(deadline: .now(), repeating: 1.0 / (Double(kVCamFrameRate) * 3.0), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.pullFrame() }
            sinkTimer = t
            t.resume()
            vcamLog.notice("pull timer ON (pushing + watched)")
        } else if !wanted, sinkTimer != nil {
            sinkTimer?.cancel()
            sinkTimer = nil
            vcamLog.notice("pull timer OFF (nothing to do)")
        }
    }

    /// One buffer per tick, deliberately: the sink queue is ONE deep (AirliveStreamSink), so
    /// the `hasMoreSampleBuffers` flag can never be true and a drain loop would be a loop that
    /// never runs a second time.  The oversampled timer above is what keeps the queue empty.
    private func pullFrame() {
        // The client is re-read every tick rather than captured when the timer was built: a
        // rapid off/on gives the extension a NEW client, and a timer pinned to the old one
        // would poll a connection that is never going to yield another frame again.
        guard let client = streamSink.client else { return }
        streamSink.stream.consumeSampleBuffer(from: client) { [weak self] sbuf, sequenceNumber, discontinuity, _, error in
            guard let self else { return }
            if let error {
                self.noteStarved("err=\(error.localizedDescription)")
                return
            }
            guard let sbuf else {
                // Nothing queued — but two polls in three find nothing even when the Bridge is
                // pushing perfectly, because the timer runs at three times the frame rate on
                // purpose.  Starvation is only starvation once a whole frame interval has gone
                // by with nothing to show; anything less is the oversampling doing its job.
                if CACurrentMediaTime() - self.lastRealFrame > 1.0 / Double(kVCamFrameRate) {
                    self.noteStarved()
                }
                return
            }
            self.pulled.tick(LumaProbe.describe(CMSampleBufferGetImageBuffer(sbuf)))

            // Stamp with the host clock AT THE MOMENT OF FORWARDING, not with the
            // program's own presentation time.  The source stream's clock is the host
            // clock, and the program's timeline has a different origin (it starts when
            // the phone connects); a consumer handed timestamps from another timeline
            // treats every frame as arriving at the wrong moment and shows nothing.
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let nowNs = UInt64(max(0, now.seconds) * Double(NSEC_PER_SEC))

            if self.streamSource.isStreaming {
                // The discontinuity flag is FORWARDED, not replaced by a constant: it is the
                // producer's own statement that this frame does not follow the last one, and a
                // consumer that is told the truth can conceal the seam instead of tearing.
                self.streamSource.stream.send(sbuf, discontinuity: discontinuity, hostTimeInNanoseconds: nowNs)
                self.lastRealFrame = CACurrentMediaTime()
                self.forwarded.tick()
            }
            // The acknowledgement CoreMediaIO needs to retire the buffer.  Skipping it
            // leaves the app's queue looking permanently full.
            self.streamSink.stream.notifyScheduledOutputChanged(
                CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: nowNs))
        }
    }

    /// One frame interval passed with the sink open and nothing in it.  CoreMediaIO publishes
    /// this as `sinkBufferUnderrunCount`, which the sink stream advertises — so it has to mean
    /// what it says.
    private func noteStarved(_ note: @autoclosure () -> String = "") {
        streamSink.noteUnderrun()
        starved.tick(note())
    }

    // MARK: - Source: placeholder while nothing is being pushed

    func startStreaming() {
        timerQueue.async { [weak self] in
            guard let self, self.placeholderTimer == nil else { return }
            vcamLog.notice("SOURCE started — a consumer opened the camera")
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.timerQueue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(kVCamFrameRate), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.publishPlaceholder() }
            self.placeholderTimer = t
            t.resume()
            self.updateSinkTimer()   // somebody is watching now — start draining if the Bridge is pushing
        }
    }

    func stopStreaming() {
        timerQueue.async { [weak self] in
            guard let self else { return }
            self.placeholderTimer?.cancel()
            self.placeholderTimer = nil
            vcamLog.notice("SOURCE stopped — last consumer closed the camera")
            self.updateSinkTimer()   // nobody left to show frames to
        }
    }

    /// The camera's DEFAULT picture. It yields to the program for exactly as long as the
    /// program keeps arriving, and comes back on its own the moment it stops — whether the
    /// operator switched the output off, quit the Bridge, or the machine simply went quiet.
    /// Nothing has to be told; nothing can be forgotten.
    private func publishPlaceholder() {
        guard streamSource.isStreaming else { return }
        guard CACurrentMediaTime() - lastRealFrame > Self.realFrameGrace else { return }
        guard let buffer = currentPlaceholder(), let description = placeholderFormat else { return }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: kVCamFrameRate),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        // The description comes from the PLACEHOLDER'S OWN BUFFER, not from the stream's.
        //
        // That one difference is why the placeholder was published for weeks and never seen:
        // a real frame arrives from the Bridge carrying a description built from the frame
        // itself, and consumers render it; the placeholder was handed the stream's hand-built
        // description instead, and was quietly dropped. Two kinds of sample went down one
        // stream, and only one of them was the kind that works. Now there is only one kind.
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: buffer, dataReady: true,
                                           makeDataReadyCallback: nil, refcon: nil,
                                           formatDescription: description,
                                           sampleTiming: &timing, sampleBufferOut: &sbuf)
        guard let sbuf else { return }
        streamSource.stream.send(sbuf, discontinuity: [],
                                 hostTimeInNanoseconds: UInt64(max(0, now.seconds) * Double(NSEC_PER_SEC)))
        shownPlaceholder.tick()
    }

    /// Drawn once and reused — it never changes.  Its colour is stated ON THE BUFFER and its
    /// description derived FROM the buffer, so what goes down the stream is the same shape of
    /// sample the Bridge sends: consumers cannot tell the two apart, which is the point.
    private func currentPlaceholder() -> CVPixelBuffer? {
        if let placeholder { return placeholder }
        guard let made = PlaceholderFrame.make(width: Int(kVCamWidth), height: Int(kVCamHeight)) else { return nil }
        CVBufferSetAttachment(made, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(made, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(made, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        var description: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: made,
                                                           formatDescriptionOut: &description) == noErr,
              description != nil else {
            vcamLog.error("placeholder: no format description — it cannot be shown")
            return nil
        }
        placeholderFormat = description
        placeholder = made
        return made
    }
}
