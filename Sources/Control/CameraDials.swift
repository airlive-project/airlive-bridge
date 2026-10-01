// CameraDials.swift - turns Stream Deck dial ticks into camera commands for the Preview camera.
//
// The dials drive the SAME camera the on-screen control panel drives (the staged Preview camera),
// on the SAME value ladders (CameraLadders), with the same rule that touching a manual value leaves
// auto. One tick = one ladder stop.
//
// Two things a dial needs that a drag-and-release slider does not:
//
// 1. A value to step FROM before the camera has answered. Ticks arrive faster than the camera's
//    confirming snapshot, so stepping from `remote` would land five ticks on the same value. The
//    commanded value is held as PENDING with the same sticky rule as the lens pick (`pendingLens`):
//    it stands until the camera reports it, or reports something genuinely different (the operator
//    changed it on the phone). Known limit: the camera has no state-request verb, so a snapshot that
//    never arrives leaves the pending value standing - the dial then shows what it commanded rather
//    than what the camera holds. Fixing that needs the camera app (docs: stale snapshot diagnosis).
//
// 2. A ceiling on what reaches the phone. A fast spin is dozens of ticks a second and every camera
//    command is a device reconfiguration on the phone. Commands go out at most every `sendInterval`
//    with the LATEST value, and not at all while the dial rests - the cheap-control-packet rule.
//
// Main-thread only, like the model it reads.

import Foundation

/// A camera setting a dial can drive. Raw values are the wire names in ControlProtocol.
enum DialParam: String, Codable, CaseIterable {
    case iso, shutter, temperature, tint, focus, zoom, ev

    /// The auto mode a manual value of this setting overrides; nil = no auto mode (zoom), or a
    /// setting that works INSIDE auto (EV biases the auto-exposure target, it does not leave it).
    fileprivate var autoGroup: AutoGroup? {
        switch self {
        case .iso, .shutter:       return .exposure
        case .temperature, .tint:  return .whiteBalance
        case .focus:               return .focus
        case .zoom, .ev:           return nil
        }
    }

    /// Two values closer than this are the same value: half the finest ladder step, so float noise
    /// in a camera echo never reads as "the camera moved".
    fileprivate var tolerance: Double {
        switch self {
        case .iso, .shutter, .tint: return 0.5
        case .temperature:          return 1
        case .focus:                return 0.004
        case .zoom, .ev:            return 0.04
        }
    }
}

fileprivate enum AutoGroup {
    case exposure, whiteBalance, focus

    func isOn(in s: StateSnapshot) -> Bool {
        switch self {
        case .exposure:     return s.exposureAuto
        case .whiteBalance: return s.whiteBalanceAuto
        case .focus:        return s.focusAuto
        }
    }

    func command(_ on: Bool) -> ControlMessage {
        switch self {
        case .exposure:     return .setExposureAuto(on)
        case .whiteBalance: return .setWhiteBalanceAuto(on)
        case .focus:        return .setFocusAuto(on)
        }
    }
}

final class CameraDials {

    /// Called when a dial changed what the controllers should show (a pending value moved).
    var onChange: (() -> Void)?

    private weak var model: BridgeModel?

    private struct Key: Hashable {
        let channel: UUID
        let param: DialParam
    }
    private struct Pending {
        let value: Double
        /// What the camera reported when the dial first moved. While it still reports this, the
        /// camera has not answered yet and the pending value stands.
        let reportedBefore: Double
    }
    private var pending: [Key: Pending] = [:]
    /// Commanded but not yet sent to the phone (waiting out the throttle).
    private var unsent: Set<Key> = []
    private var sendTimer: Timer?
    private var lastSend = Date.distantPast

    /// At most ~7 commands a second during a fast spin: the picture still follows the dial, and the
    /// phone is not asked to reconfigure its sensor on every tick.
    private static let sendInterval: TimeInterval = 0.15

    init(model: BridgeModel) {
        self.model = model
    }

    // MARK: - Target

    /// The camera the dials drive: the staged Preview camera, if it owns a control back-channel.
    /// Exactly the camera the on-screen control panel shows.
    var target: BridgeChannel? {
        guard let channel = model?.previewChannel(),
              channel.kind == .airlive || channel.kind == .screenMirroringPlusControl else { return nil }
        return channel
    }

    /// A command would actually reach the phone and be obeyed.
    func isControllable(_ channel: BridgeChannel) -> Bool {
        channel.remoteControlConnected && channel.remoteControlAllowed && channel.remote != nil
    }

    // MARK: - Commands

    /// Step `param` by `steps` ladder stops. False when there is no controllable camera to step.
    func adjust(_ param: DialParam, steps: Int) -> Bool {
        guard let channel = target, isControllable(channel), let snapshot = channel.remote else { return false }
        let ladder = Self.ladder(param, snapshot)
        let key = Key(channel: channel.id, param: param)
        let from = value(param, of: channel, snapshot)
        let index = Self.nearestIndex(of: from, in: ladder)
        let to = ladder[min(max(index + steps, 0), ladder.count - 1)]
        guard abs(to - from) > param.tolerance else { return true }   // at the end of the ladder

        let reported = Self.reported(param, snapshot)
        pending[key] = Pending(value: to, reportedBefore: pending[key]?.reportedBefore ?? reported)
        unsent.insert(key)
        scheduleSend()
        onChange?()
        return true
    }

    /// The dial's push: hand the setting back to the camera's auto mode. Zoom has none, so it
    /// returns to 1×; EV returns to 0.
    func reset(_ param: DialParam) -> Bool {
        guard let channel = target, isControllable(channel) else { return false }
        // Drop everything in flight for the whole auto group: a queued manual ISO sent after
        // "exposure auto on" would knock the camera straight back out of auto.
        let group = param.autoGroup
        for p in DialParam.allCases where p == param || (group != nil && p.autoGroup == group) {
            let key = Key(channel: channel.id, param: p)
            pending[key] = nil
            unsent.remove(key)
        }
        switch param {
        case .zoom: channel.send(.setZoom(1))
        case .ev:   channel.send(.setExposureBias(0))
        default:    if let group { channel.send(group.command(true)) }
        }
        onChange?()
        return true
    }

    // MARK: - What the controllers show

    /// The value the dial stands on: its own pending command while the camera has not answered,
    /// otherwise what the camera reports.
    func value(_ param: DialParam, of channel: BridgeChannel, _ snapshot: StateSnapshot) -> Double {
        let reported = Self.reported(param, snapshot)
        let key = Key(channel: channel.id, param: param)
        guard let p = pending[key] else { return reported }
        if abs(reported - p.value) <= param.tolerance { pending[key] = nil; return reported }   // confirmed
        if abs(reported - p.reportedBefore) <= param.tolerance { return p.value }               // not answered yet
        // Still in auto: the camera has not processed "leave auto" yet, and what it reports is its
        // own auto loop still moving (exposure readback, once a second) - not a change of mind.
        if param.autoGroup?.isOn(in: snapshot) == true { return p.value }
        pending[key] = nil                                                                      // moved elsewhere
        return reported
    }

    /// Auto is shown as ON only while the camera says so AND no manual value is pending - the
    /// moment a dial moves, the readout is manual, like the panel's slider.
    func isAuto(_ param: DialParam, of channel: BridgeChannel, _ snapshot: StateSnapshot) -> Bool {
        guard let group = param.autoGroup, group.isOn(in: snapshot) else { return false }
        return !DialParam.allCases.contains { $0.autoGroup == group && pending[Key(channel: channel.id, param: $0)] != nil }
    }

    /// The value's place on its ladder, 0…1, for the touch strip's bar.
    func position(_ param: DialParam, value: Double, _ snapshot: StateSnapshot) -> Double {
        let ladder = Self.ladder(param, snapshot)
        guard ladder.count > 1 else { return 0 }
        return Double(Self.nearestIndex(of: value, in: ladder)) / Double(ladder.count - 1)
    }

    /// The panel's own readouts, so the strip and the screen print a value the same way.
    static func display(_ param: DialParam, _ v: Double) -> String {
        switch param {
        case .iso:         return "\(Int(v.rounded()))"
        case .shutter:     return "1/\(Int(v.rounded()))"
        case .temperature: return "\(Int(v.rounded()))K"
        case .tint:        let i = Int(v.rounded()); return i > 0 ? "+\(i)" : "\(i)"
        case .focus:       return String(format: "%.3f", v)
        case .zoom:        return String(format: "%.1f×", v)
        case .ev:          return abs(v) < 0.05 ? "0.0" : String(format: "%+.1f", v)
        }
    }

    // MARK: - Sending (throttled)

    private func scheduleSend() {
        guard sendTimer == nil else { return }
        let delay = max(0, lastSend.addingTimeInterval(Self.sendInterval).timeIntervalSinceNow)
        // `.common` modes so an open menu in the Bridge does not hold a dial's command back.
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.sendPending() }
        RunLoop.main.add(timer, forMode: .common)
        sendTimer = timer
    }

    private func sendPending() {
        sendTimer = nil
        lastSend = Date()
        let keys = unsent
        unsent.removeAll()
        guard let model else { return }
        for key in keys {
            guard let p = pending[key],
                  let channel = model.channels.first(where: { $0.id == key.channel }),
                  let snapshot = channel.remote else { continue }
            // Leave auto first, as touching a manual value in the panel does - the camera would
            // otherwise ignore the value, or have its auto loop overwrite it a second later.
            if let group = key.param.autoGroup, group.isOn(in: snapshot) { channel.send(group.command(false)) }
            channel.send(Self.command(key.param, p.value))
        }
    }

    // MARK: - Pure mapping

    private static func ladder(_ param: DialParam, _ snapshot: StateSnapshot) -> [Double] {
        let l = CameraLadders(snapshot)
        switch param {
        case .iso:         return l.iso
        case .shutter:     return l.shutter
        case .temperature: return l.temperature
        case .tint:        return l.tint
        case .focus:       return l.focus
        case .zoom:        return l.zoom
        case .ev:          return l.exposureBias
        }
    }

    private static func reported(_ param: DialParam, _ s: StateSnapshot) -> Double {
        switch param {
        case .iso:         return Double(s.iso)
        case .shutter:     return Double(s.shutterDenom)
        case .temperature: return Double(s.wbKelvin)
        case .tint:        return Double(s.tint)
        case .focus:       return Double(s.focusPosition)
        case .zoom:        return Double(s.zoom)
        case .ev:          return Double(s.exposureBias)
        }
    }

    private static func command(_ param: DialParam, _ v: Double) -> ControlMessage {
        switch param {
        case .iso:         return .setISO(Float(v))
        case .shutter:     return .setShutter(Float(v))
        case .temperature: return .setWB(Float(v))
        case .tint:        return .setTint(Float(v))
        case .focus:       return .setFocusPosition(Float(v))
        case .zoom:        return .setZoom(Float(v))
        case .ev:          return .setExposureBias(Float(v))
        }
    }

    /// An auto-exposure ISO of 3703 is not on the ladder; the first tick steps from the nearest stop.
    private static func nearestIndex(of value: Double, in ladder: [Double]) -> Int {
        ladder.indices.min { abs(ladder[$0] - value) < abs(ladder[$1] - value) } ?? 0
    }
}
