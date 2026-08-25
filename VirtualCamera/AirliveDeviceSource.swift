// AirliveDeviceSource.swift — the device + its single video stream.
//
// `startStreaming` is called when the FIRST app opens the camera and `stopStreaming`
// when the last one closes it, so the timer only runs while somebody is watching —
// an idle virtual camera costs nothing.

import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo

final class AirliveDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var streamSource: AirliveStreamSource!

    /// Publishing clock.  `.strict` so macOS does not coalesce it with other timers —
    /// a coalesced camera tick shows up as visible judder in the consuming app.
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "studio.airlive.vcam.timer",
                                           qos: .userInteractive,
                                           autoreleaseFrequency: .workItem,
                                           target: .global(qos: .userInteractive))

    private var format: CMFormatDescription!
    private var reader: SharedFrameReader?
    private var placeholder: CVPixelBuffer?
    /// Reused so we allocate one buffer for the whole session, not one per frame.
    private var scratch: CVPixelBuffer?
    private var sequence: UInt64 = 0

    init(localizedName: String) {
        super.init()
        // A STABLE uuid: macOS keys the user's per-app camera permission off the device
        // id, so a random one each launch would re-prompt in every conferencing app.
        let deviceID = UUID(uuidString: "6F1B7A54-2C3E-4B7E-9E4D-A1C0D2E3F4A5")!
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID,
                                     legacyDeviceID: nil, source: self)

        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: kFrameWidth, height: kFrameHeight,
                                       extensions: nil, formatDescriptionOut: &format)

        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: format,
            maxFrameDuration: CMTime(value: 1, timescale: kFrameRate),
            minFrameDuration: CMTime(value: 1, timescale: kFrameRate),
            validFrameDurations: nil)

        streamSource = AirliveStreamSource(
            localizedName: "Airlive Virtual Camera",
            streamID: UUID(uuidString: "3A2B1C0D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!,
            streamFormat: streamFormat, device: device)
        do { try device.addStream(streamSource.stream) }
        catch let e { fatalError("failed to add stream: \(e.localizedDescription)") }

        reader = SharedFrameReader()
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            // 'virt' — the four-char transport code macOS uses for a software device.
            // Spelled out rather than pulled from IOKit's audio headers, which a camera
            // extension has no reason to link.
            p.transportType = Int(0x76697274)   // 'virt'
        }
        if properties.contains(.deviceModel) { p.model = "Airlive Virtual Camera" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: - Publishing

    func startStreaming() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.publishFrame() }
        timer = t
        t.resume()
    }

    func stopStreaming() {
        timer?.cancel()
        timer = nil
    }

    /// One tick: the newest frame the Bridge published, or the placeholder while the
    /// Bridge is closed / nothing is on air.  A camera that opens to a black void reads
    /// as broken, so "no program" is stated on screen instead.
    private func publishFrame() {
        guard streamSource.isStreaming else { return }
        let buffer = reader?.latestFrame(into: &scratch) ?? currentPlaceholder()
        guard let buffer else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: kFrameRate),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var fmt: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: buffer,
                                                     formatDescriptionOut: &fmt)
        guard let fmt else { return }

        var sbuf: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: buffer,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: fmt,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &sbuf)
        guard let sbuf else { return }
        sequence &+= 1
        streamSource.stream.send(sbuf, discontinuity: [],
                                 hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
    }

    /// Built once, then reused — it never changes.
    private func currentPlaceholder() -> CVPixelBuffer? {
        if let placeholder { return placeholder }
        placeholder = PlaceholderFrame.make(width: Int(kFrameWidth), height: Int(kFrameHeight))
        return placeholder
    }
}
