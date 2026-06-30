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
    private let delayQueue = DispatchQueue(label: "studio.airlive.bridge.airplay.delay",
                                           qos: .userInteractive)

    // Cross-thread scalars: written on main (setters), read on the engine's decoder thread +
    // `delayQueue` (the frame callback).  All access goes through `stateLock` — a plain `var`
    // would be a data race (TSan-visible, and the Swift memory model gives no atomicity).
    private let stateLock = NSLock()
    private var _extraDelaySec: Double = 0   // operator's "Additional delay" (seconds)
    private var _isProgramSource = false     // H1: only the program source needs the per-frame main hop
    private var _didFlipGate = false         // one main hop per session to set isConnected/latestFrame
    private var _stopped = false             // gate late decoder callbacks after stop()

    init(channel: BridgeChannel, name: String) {
        self.channel = channel
        self.engine = AirPlayEngine(name: name)
        self._extraDelaySec = Swift.max(0, Double(channel.extraDelayMs) / 1000.0)
        engine.onVideoFrame = { [weak self] pixelBuffer, ptsNs in
            guard let self else { return }
            self.stateLock.lock()
            if self._stopped { self.stateLock.unlock(); return }
            let d = self._extraDelaySec
            let isPgm = self._isProgramSource
            let needGate = !self._didFlipGate
            if needGate { self._didFlipGate = true }
            self.stateLock.unlock()

            let deliver = { [weak self] in
                guard let self, let channel = self.channel else { return }
                // A frame scheduled before stop() must not resurrect a torn-down channel.
                self.stateLock.lock(); let stopped = self._stopped; self.stateLock.unlock()
                if stopped { return }
                channel.publishFrame(pixelBuffer)        // off-thread mirror (zero-copy) — every tile
                // Main-isolated work ONLY when needed: the program tap (per frame) or the
                // one-shot connect / latestFrame flip.  A non-program AirPlay channel does ZERO
                // per-frame main hops after its first frame (H1).  Channel captured WEAKLY so a
                // late hop can't keep a stopped channel alive or flip its state back on.
                guard isPgm || needGate else { return }
                DispatchQueue.main.async { [weak channel] in
                    guard let channel else { return }
                    if needGate {
                        if !channel.isConnected { channel.isConnected = true }
                        if channel.latestFrame == nil { channel.latestFrame = pixelBuffer }
                    }
                    if isPgm { channel.onProgramFrame?(pixelBuffer, ptsNs) }   // program bus (NDI)
                }
            }
            // Fixed additive delay (0 → immediate, the original zero-risk path).
            if d <= 0 { deliver() } else { self.delayQueue.asyncAfter(deadline: .now() + d, execute: deliver) }
        }
        // #12: the engine fires this (on a UxPlay network thread) when the mirror session drops —
        // the phone stopped mirroring or the connection reset.  Clear the channel's video state
        // so it doesn't read "connected" forever, and reset the gate so the NEXT session re-flips
        // isConnected/latestFrame.  (For a combined channel the control side stays untouched.)
        engine.onConnectionLost = { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); self._didFlipGate = false; self.stateLock.unlock()
            self.channel?.publishFrame(nil)   // blank mirrors (off-main, thread-safe)
            let clear = { [weak self] in self?.channel?.isConnected = false; self?.channel?.latestFrame = nil }
            if Thread.isMainThread { clear() } else { DispatchQueue.main.async(execute: clear) }
        }
    }

    func start() { engine.start() }   // engine self-registers the Bonjour services

    func stop() {
        stateLock.lock(); _stopped = true; _didFlipGate = false; stateLock.unlock()
        engine.onVideoFrame = nil       // stop NEW decoder callbacks BEFORE teardown (no stale frames)
        engine.onConnectionLost = nil   // and don't fire "lost" during our own teardown
        engine.stop()
        channel?.publishFrame(nil)
        let clear = { [weak self] in self?.channel?.isConnected = false; self?.channel?.latestFrame = nil }
        if Thread.isMainThread { clear() } else { DispatchQueue.main.async(execute: clear) }
    }

    func send(_ msg: ControlMessage) {}              // no back-channel over AirPlay
    func rename(_ newName: String) { engine.setAdvertiseName(newName) }
    func updateOrder(_ index: Int) {}
    func updateDelay(_ preset: LatencyPreset) {}   // no preset jitter buffer on the AirPlay path
    func updateExtraDelay(_ ms: Int) {
        let v = Swift.max(0, Double(ms) / 1000.0)
        stateLock.lock(); _extraDelaySec = v; stateLock.unlock()
    }
    /// H1: only the program AirPlay channel needs the per-frame `onProgramFrame` main hop.
    func setProgramSource(_ isProgram: Bool) {
        stateLock.lock(); _isProgramSource = isProgram; stateLock.unlock()
    }
    func updateAuth(require: Bool, password: String, disconnectNow: Bool) {}

    // Safety net: if this receiver is ever released without an explicit stop()
    // (removeChannel does call stop(), but a future path might not), tear the engine
    // down so its httpd / Bonjour / decoder threads don't outlive us and keep
    // advertising a zombie Apple TV.
    deinit { engine.stop() }
}
