// AirliveProviderSource.swift — the virtual camera other apps see.
//
// Three CoreMediaIO objects, nested: a PROVIDER owns one DEVICE, which owns one
// video STREAM.  Zoom/Meet/QuickTime open the stream; we push frames into it.
//
// Frames come from the Bridge through a shared-memory slot in the App Group
// container (see SharedFrameBuffer) — the channel Apple's own camera-extension
// template is set up for.  The extension NEVER talks to the Bridge directly: the
// Bridge may not even be running, and a camera must still open cleanly, so a
// missing feed is a normal state that shows a placeholder rather than an error.

import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo

/// Wire size of the virtual camera.  Fixed 1080p: the program feed is already a
/// 1080p proxy, and a camera that changes resolution mid-session confuses callers.
let kFrameWidth: Int32 = 1920
let kFrameHeight: Int32 = 1080
/// Cadence we publish at.  Consumers expect a steady rate, so the stream ticks at a
/// fixed 30 and repeats the newest frame when the Bridge has nothing newer.
let kFrameRate: Int32 = 30

// MARK: - Provider

final class AirliveProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: AirliveDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = AirliveDeviceSource(localizedName: "Airlive Virtual Camera")
        do { try provider.addDevice(deviceSource.device) }
        catch let e { fatalError("failed to add device: \(e.localizedDescription)") }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "Airlive" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
