// AirPlayReceiver.swift — a channel fed by AirPlay Screen Mirroring.
//
// Wraps the ObjC++ `AirPlayEngine` (the vendored UxPlay AirPlay/RAOP + FairPlay
// stack + VideoToolbox decode) and adapts it to the `ChannelReceiver` seam: each
// AirPlay channel advertises (via UxPlay's own dns_sd, like the OBS plugin) as a
// named Apple TV that any iPhone can pick in Screen Mirroring — no app needed.
// Decoded frames flow into the SAME publishFrame / mirror / program path as every
// other source.
//
// NOTE: discovery requires a TEAM-SIGNED app with Local Network access — an ad-hoc
// build's dns_sd register is denied (-65555). Video-only: AirPlay has no back-channel
// (control/tally are no-ops; that's the Airlive app's job). `onVideoFrame` fires on
// the engine's decoder thread; the captured `CVPixelBuffer` is retained by ARC.

import Foundation
import CoreVideo

final class AirPlayReceiver: ChannelReceiver {
    private weak var channel: BridgeChannel?
    private let engine: AirPlayEngine

    init(channel: BridgeChannel, name: String) {
        self.channel = channel
        self.engine = AirPlayEngine(name: name)
        engine.onVideoFrame = { [weak self] pixelBuffer, ptsNs in
            guard let self, let channel = self.channel else { return }
            channel.publishFrame(pixelBuffer)        // off-decoder-thread mirror (zero-copy)
            DispatchQueue.main.async {
                if !channel.isConnected { channel.isConnected = true }
                channel.onProgramFrame?(pixelBuffer, ptsNs)   // program bus (NDI)
                if channel.latestFrame == nil { channel.latestFrame = pixelBuffer }
            }
        }
    }

    func start() { engine.start() }   // engine self-registers the Bonjour services

    func stop() {
        engine.stop()
        channel?.publishFrame(nil)
        let clear = { [weak self] in self?.channel?.isConnected = false; self?.channel?.latestFrame = nil }
        if Thread.isMainThread { clear() } else { DispatchQueue.main.async(execute: clear) }
    }

    func send(_ msg: ControlMessage) {}              // no back-channel over AirPlay
    func rename(_ newName: String) { engine.setAdvertiseName(newName) }
    func updateOrder(_ index: Int) {}
    func updateDelay(_ preset: LatencyPreset) {}
    func updateAuth(require: Bool, password: String, disconnectNow: Bool) {}

    // Safety net: if this receiver is ever released without an explicit stop()
    // (removeChannel does call stop(), but a future path might not), tear the engine
    // down so its httpd / Bonjour / decoder threads don't outlive us and keep
    // advertising a zombie Apple TV.
    deinit { engine.stop() }
}
