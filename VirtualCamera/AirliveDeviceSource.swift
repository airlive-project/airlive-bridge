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

    /// True while the Bridge holds the sink open.  Read at the top of the placeholder tick:
    /// real frames always win.
    private var sinkStarted = false

    private var format: CMFormatDescription!
    private var placeholder: CVPixelBuffer?

    private let pulled = RateLog("pulled from sink")
    private let forwarded = RateLog("forwarded to consumers")
    private let empty = RateLog("EMPTY pull (nothing queued)")

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
                                       width: kFrameWidth, height: kFrameHeight,
                                       extensions: colour as CFDictionary,
                                       formatDescriptionOut: &format)

        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: format,
            maxFrameDuration: CMTime(value: 1, timescale: kFrameRate),
            minFrameDuration: CMTime(value: 1, timescale: kFrameRate),
            validFrameDurations: nil)

        streamSource = AirliveStreamSource(localizedName: "Airlive Bridge Virtual Camera",
                                           streamID: sourceUUID, streamFormat: streamFormat, device: device)
        streamSink = AirliveStreamSink(localizedName: "Airlive Bridge Virtual Camera Sink",
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
        vcamLog.notice("device ready — \(localizedName, privacy: .public) \(kFrameWidth)x\(kFrameHeight)@\(kFrameRate)")
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        // 'virt' — the four-char transport code macOS uses for a software device.
        if properties.contains(.deviceTransportType) { p.transportType = Int(0x76697274) }
        if properties.contains(.deviceModel) { p.model = "Airlive Bridge Virtual Camera" }
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
            t.schedule(deadline: .now(), repeating: 1.0 / (Double(kFrameRate) * 3.0), leeway: .milliseconds(1))
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

    private func pullFrame() {
        // The client is re-read every tick rather than captured when the timer was built: a
        // rapid off/on gives the extension a NEW client, and a timer pinned to the old one
        // would poll a connection that is never going to yield another frame again.
        guard let client = streamSink.client else { return }
        streamSink.stream.consumeSampleBuffer(from: client) { [weak self] sbuf, sequenceNumber, _, _, error in
            guard let self else { return }
            if let error {
                self.empty.tick("err=\(error.localizedDescription)")
                return
            }
            guard let sbuf else { self.empty.tick(); return }
            self.pulled.tick(LumaProbe.describe(CMSampleBufferGetImageBuffer(sbuf)))

            // Stamp with the host clock AT THE MOMENT OF FORWARDING, not with the
            // program's own presentation time.  The source stream's clock is the host
            // clock, and the program's timeline has a different origin (it starts when
            // the phone connects); a consumer handed timestamps from another timeline
            // treats every frame as arriving at the wrong moment and shows nothing.
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let nowNs = UInt64(max(0, now.seconds) * Double(NSEC_PER_SEC))

            if self.streamSource.isStreaming {
                self.streamSource.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: nowNs)
                self.forwarded.tick()
            }
            // The acknowledgement CoreMediaIO needs to retire the buffer.  Skipping it
            // leaves the app's queue looking permanently full.
            self.streamSink.stream.notifyScheduledOutputChanged(
                CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: nowNs))
        }
    }

    // MARK: - Source: placeholder while nothing is being pushed

    func startStreaming() {
        timerQueue.async { [weak self] in
            guard let self, self.placeholderTimer == nil else { return }
            vcamLog.notice("SOURCE started — a consumer opened the camera")
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.timerQueue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate), leeway: .milliseconds(1))
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

    /// Runs only when the Bridge is NOT pushing — real frames always take precedence.
    private func publishPlaceholder() {
        guard !sinkStarted, streamSource.isStreaming else { return }
        guard let buffer = currentPlaceholder(), let format else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: kFrameRate),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: buffer, dataReady: true,
                                           makeDataReadyCallback: nil, refcon: nil,
                                           formatDescription: format,
                                           sampleTiming: &timing, sampleBufferOut: &sbuf)
        guard let sbuf else { return }
        streamSource.stream.send(sbuf, discontinuity: [],
                                 hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
    }

    /// Drawn once and reused — it never changes.
    private func currentPlaceholder() -> CVPixelBuffer? {
        if let placeholder { return placeholder }
        placeholder = PlaceholderFrame.make(width: Int(kFrameWidth), height: Int(kFrameHeight))
        return placeholder
    }
}
