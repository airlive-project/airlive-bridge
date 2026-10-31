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
    /// Which run of frames a delayed frame belongs to. Moves when the mirror session drops and
    /// when the delay changes, so a frame still waiting from before is dropped, not shown: an old
    /// session's frame would put a dead picture back on a blanked tile, and one scheduled under a
    /// longer delay would land AFTER newer frames sent under the shorter one.
    private var _generation = 0

    init(channel: BridgeChannel, name: String) {
        self.channel = channel
        self.engine = AirPlayEngine(name: name)
        self._extraDelaySec = Swift.max(0, Double(channel.extraDelayMs) / 1000.0)
        engine.onVideoFrame = { [weak self] pixelBuffer, ptsNs in
            guard let self else { return }
            self.stateLock.lock()
            if self._stopped { self.stateLock.unlock(); return }
            let d = self._extraDelaySec
            let generation = self._generation
            let needGate = !self._didFlipGate
            if needGate { self._didFlipGate = true }
            self.stateLock.unlock()

            let deliver = { [weak self] in
                guard let self, let channel = self.channel else { return }
                // A frame scheduled before stop() must not resurrect a torn-down channel.
                // On air is read NOW, not when the frame arrived: with a delay, a cut to this
                // channel would otherwise leave the program empty for the whole delay.
                self.stateLock.lock()
                let current = !self._stopped && generation == self._generation
                let isPgm = self._isProgramSource
                // The frame that was to flip the connected gate is being dropped: hand that job to
                // the next frame, or a delay change in a session's first moments leaves it unset.
                if !current && needGate { self._didFlipGate = false }
                self.stateLock.unlock()
                guard current else { return }
                channel.publishFrame(pixelBuffer)        // off-thread mirror (zero-copy) — every tile
                // Program tap right here: the tap is lock-guarded and the outputs come from the
                // lock-guarded ProgramBus, so it never needs main.  Routing it through main put
                // NDI / HDMI / the virtual camera behind SwiftUI's rendering — the same defect
                // that once made the passthrough outputs judder.
                if isPgm { channel.onProgramFrame?(pixelBuffer, ptsNs) }
                // The published connect / no-signal gate IS main-isolated — and flips once.
                // Channel captured WEAKLY so a late hop can't resurrect a stopped channel.
                guard needGate else { return }
                DispatchQueue.main.async { [weak channel] in
                    guard let channel else { return }
                    if !channel.isConnected { channel.isConnected = true }
                    if channel.latestFrame == nil { channel.latestFrame = pixelBuffer }
                }
            }
            // Fixed additive delay (0 → immediate, the original zero-risk path).
            guard d > 0 else { return deliver() }
            // Strict, like the camera playout (StrictTimer.swift).
            self.delayQueue.strictAfter(d, execute: deliver)
        }
        // #12: the engine fires this (on a UxPlay network thread) when the mirror session drops —
        // the phone stopped mirroring or the connection reset.  Clear the channel's video state
        // so it doesn't read "connected" forever, and reset the gate so the NEXT session re-flips
        // isConnected/latestFrame.  (For a combined channel the control side stays untouched.)
        engine.onConnectionLost = { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); self._didFlipGate = false; self._generation += 1; self.stateLock.unlock()
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
        channel?.publishFrame(nil)
        let clear = { [weak self] in self?.channel?.isConnected = false; self?.channel?.latestFrame = nil }
        if Thread.isMainThread { clear() } else { DispatchQueue.main.async(execute: clear) }
        // engine.stop() joins the UxPlay restart worker + decoder thread and can block a while (a
        // worker mid dnssd/httpd teardown, or a decode in flight) — do it OFF main so removing a
        // channel from the SwiftUI list never freezes the UI. Capture self STRONGLY so the receiver +
        // engine outlive the async teardown even if the channel is released meanwhile; engine.stop()
        // is idempotent (running_ guard) so the deinit fallback is a safe no-op afterwards.
        DispatchQueue.global(qos: .userInitiated).async { self.engine.stop() }
    }

    func send(_ msg: ControlMessage) {}              // no back-channel over AirPlay
    func rename(_ newName: String) { engine.setAdvertiseName(newName) }
    func updateOrder(_ index: Int) {}
    func updateDelay(_ preset: LatencyPreset) {}   // no preset jitter buffer on the AirPlay path
    func updateExtraDelay(_ ms: Int) {
        let v = Swift.max(0, Double(ms) / 1000.0)
        stateLock.lock()
        if v != _extraDelaySec { _extraDelaySec = v; _generation += 1 }
        stateLock.unlock()
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
