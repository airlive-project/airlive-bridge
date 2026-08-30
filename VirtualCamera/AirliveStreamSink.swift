// AirliveStreamSink.swift — the channel the Bridge pushes frames INTO.
//
// A camera extension is launched by macOS as its own user (`_cmiodalassistants`), not as
// the person running the Bridge.  Anything keyed to a home directory — an App Group
// container, a temp file, shared memory reached by path — therefore resolves to two
// different places on the two sides and can never meet.  CoreMediaIO's own answer is a
// second stream on the same device, running the other way: the app enqueues buffers, the
// extension pulls them.  The buffers are IOSurface-backed, so the hop is a handle, not a
// copy of the pixels.
//
// This is a PULL model, which is easy to misread: the sink source below is only asked to
// start and stop.  The actual reading is `CMIOExtensionStream.consumeSampleBuffer(from:)`,
// which the DEVICE calls on a timer — see AirliveDeviceSource.

import Foundation
import CoreMediaIO
import CoreMedia

final class AirliveStreamSink: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    private weak var device: CMIOExtensionDevice?

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.streamFormat = streamFormat
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    /// The same format the source stream publishes — the frame crosses the device
    /// untouched, so there is nothing to convert on the way through.
    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration,
         .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
         .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: kFrameRate)
        }
        // One buffer in flight, one needed to start: this is live video, so a deep queue
        // would only add latency — a late frame is worth less than the next one.
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    /// CRITICAL: the client handed in here is the ONLY handle from which buffers can later
    /// be pulled.  Failing to keep it leaves a sink that starts cleanly and then never
    /// yields a single frame — which looks exactly like "the app isn't sending anything".
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        vcamLog.notice("sink: client authorized — \(client.clientID.uuidString, privacy: .public)")
        return true
    }

    private(set) var client: CMIOExtensionClient?

    func startStream() throws {
        guard let client else {
            vcamLog.error("sink: startStream with NO client — nothing can ever be pulled")
            return
        }
        (device?.source as? AirliveDeviceSource)?.startStreamingSink(client: client)
    }

    func stopStream() throws {
        // Forget the client here: it belongs to the connection that just closed.  Holding a
        // dead client is what turns a fast off/on into a camera that starts cleanly and then
        // never yields another frame.
        client = nil
        (device?.source as? AirliveDeviceSource)?.stopStreamingSink()
    }
}
