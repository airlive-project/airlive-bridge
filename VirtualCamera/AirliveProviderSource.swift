// AirliveProviderSource.swift — the virtual camera other apps see.
//
// Three CoreMediaIO objects, nested: a PROVIDER owns one DEVICE, which owns two STREAMS —
// one that Zoom reads, one that the Bridge writes into.  See AirliveDeviceSource.
//
// The extension is a separate process macOS launches on demand, under its OWN user, and it
// keeps running with the Bridge closed.  So a missing Bridge is a normal state, not an
// error: the camera must still open cleanly and say what is going on.

import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo

// Size, cadence, pixel format and identity are declared ONCE, in
// Sources/Shared/VirtualCameraContract.swift, and compiled into this target too.

final class AirliveProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: AirliveDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = AirliveDeviceSource(localizedName: kVCamDeviceName,
                                           deviceUUID: UUID(uuidString: kVCamDeviceUUID)!,
                                           sourceUUID: UUID(uuidString: kVCamSourceStreamUUID)!,
                                           sinkUUID: UUID(uuidString: kVCamSinkStreamUUID)!)
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
