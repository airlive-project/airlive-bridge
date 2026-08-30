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

/// Wire size of the virtual camera.  Fixed 1080p: the program feed is already a 1080p
/// proxy, and a camera that changes resolution mid-session confuses callers.
let kFrameWidth: Int32 = 1920
let kFrameHeight: Int32 = 1080
/// Cadence the source stream publishes at.
let kFrameRate: Int32 = 30
/// Pixel format the camera publishes: 8-bit 4:2:0 bi-planar, VIDEO RANGE — bit for bit
/// what the Bridge's H.264 decoder produces, and what every hardware webcam delivers.
///
/// It used to be 32BGRA, which forced a YCbCr→RGB pass on every frame.  That pass has to
/// pick a matrix and a range, and picking either one differently from the source shifts
/// the whole picture: the operator saw a flatter, washed-out image here while OBS — which
/// gets the untouched bitstream — looked right.  Publishing the source's own format means
/// there is no matrix to get wrong, no range to guess, and no per-frame GPU work at all.
let kVCamPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

/// Identity of the device and its two streams.  These live in the extension's Info.plist so
/// the ONE value the Bridge also needs — the device UUID it matches on to find us among all
/// cameras — comes from a single place in project.yml rather than a literal hand-copied
/// into two targets.  The device UUID must stay stable across releases: macOS keys the
/// user's per-app camera permission to it.
enum CameraIdentity {
    static func uuid(_ key: String, fallback: String) -> UUID {
        let s = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return UUID(uuidString: s ?? "") ?? UUID(uuidString: fallback)!
    }
    static var device: UUID { uuid("AirliveCameraDeviceUUID", fallback: "6F1B7A54-2C3E-4B7E-9E4D-A1C0D2E3F4A5") }
    static var source: UUID { uuid("AirliveCameraSourceUUID", fallback: "3A2B1C0D-4E5F-4A6B-8C7D-9E0F1A2B3C4D") }
    static var sink: UUID   { uuid("AirliveCameraSinkUUID",   fallback: "5C4D3E2F-1A0B-4C9D-8E7F-6A5B4C3D2E1F") }
}

final class AirliveProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: AirliveDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = AirliveDeviceSource(localizedName: "Airlive Bridge Virtual Camera",
                                           deviceUUID: CameraIdentity.device,
                                           sourceUUID: CameraIdentity.source,
                                           sinkUUID: CameraIdentity.sink)
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
