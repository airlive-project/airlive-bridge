// AirliveStreamSource.swift — the one video stream apps subscribe to.
//
// CoreMediaIO calls start/stop as consumers come and go; `isStreaming` gates the
// device's timer so we never build a frame nobody will read.

import Foundation
import CoreMediaIO
import CoreMedia

final class AirliveStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    private weak var device: CMIOExtensionDevice?

    /// Consumer count, not a bool: several apps can hold the camera at once and the
    /// LAST one closing must stop the timer (a bool would stop it on the first close
    /// and leave the others on a frozen picture).
    private let lock = NSLock()
    private var clients = 0
    var isStreaming: Bool { lock.lock(); defer { lock.unlock() }; return clients > 0 }

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.streamFormat = streamFormat
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: kFrameRate)
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    /// Any client may open the camera — this is a virtual webcam, the same as the
    /// built-in one; access is governed by macOS's own per-app camera permission.
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        lock.lock(); clients += 1; lock.unlock()
        (device?.source as? AirliveDeviceSource)?.startStreaming()
    }

    func stopStream() throws {
        lock.lock(); if clients > 0 { clients -= 1 }; let none = clients == 0; lock.unlock()
        if none { (device?.source as? AirliveDeviceSource)?.stopStreaming() }
    }
}
