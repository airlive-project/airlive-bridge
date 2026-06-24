// AirPlayReceiver.swift — a channel fed by AirPlay Screen Mirroring.
//
// Wraps the ObjC++ `AirPlayEngine` (the vendored UxPlay AirPlay/RAOP + FairPlay
// stack + VideoToolbox decode) and adapts it to the `ChannelReceiver` seam: each
// AirPlay channel advertises as a named Apple TV (the channel name) that any iPhone
// can pick in Screen Mirroring — no app needed.  Decoded frames flow into the SAME
// publishFrame / mirror / program path as every other source.
//
// Video-only: AirPlay has no back-channel to the phone, so control/tally are no-ops
// (that's the Airlive app's job).  `onVideoFrame` fires on the engine's decoder
// thread; the captured `CVPixelBuffer` is retained by ARC for the main hop.

import Foundation
import CoreVideo

final class AirPlayReceiver: ChannelReceiver {
    private weak var channel: BridgeChannel?
    private let engine: AirPlayEngine
    /// Advertises the RAOP/AirPlay services via NSNetService (the dns_sd path the
    /// engine would use is blocked on macOS 26 with -65555).
    private let bonjour = AirPlayBonjour()

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

    func start() {
        engine.start()      // synchronous: server is up + TXT records built on return
        publishCurrent()
    }

    /// Pull the engine's live TXT/instance/port and advertise via NSNetService.
    private func publishCurrent() {
        guard let rTXT = engine.raopTXTRecord(), let aTXT = engine.airplayTXTRecord(),
              let rInst = engine.raopInstanceName(), let aInst = engine.airplayInstanceName(),
              engine.serverPort() != 0 else {
            print("[AirPlayReceiver] ❌ server not up (nil TXT/port) — skip advertise")
            return
        }
        bonjour.publish(port: Int(engine.serverPort()),
                        raopInstance: rInst, raopTXT: rTXT,
                        airplayInstance: aInst, airplayTXT: aTXT)
    }

    func stop() {
        bonjour.stop()
        engine.stop()
        channel?.publishFrame(nil)
        let clear = { [weak self] in self?.channel?.isConnected = false; self?.channel?.latestFrame = nil }
        if Thread.isMainThread { clear() } else { DispatchQueue.main.async(execute: clear) }
    }

    // AirPlay is one-way video — no Bonjour-`src`/back-channel, so these are no-ops
    // except `rename`, which re-advertises the Apple-TV name.
    func send(_ msg: ControlMessage) {}
    func rename(_ newName: String) {
        bonjour.stop()
        engine.setAdvertiseName(newName)   // restarts the server async (new name)
        // Re-advertise once the restarted server's records are ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.publishCurrent() }
    }
    func updateOrder(_ index: Int) {}
    func updateDelay(_ preset: LatencyPreset) {}
    func updateAuth(require: Bool, password: String, disconnectNow: Bool) {}
}
