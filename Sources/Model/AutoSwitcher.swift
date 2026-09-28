// AutoSwitcher.swift - the timed camera rotation behind the AUTO button.
//
// It exists for the unattended desk: a phone on a tripod, nobody at the Mac, and a fixed frame
// for two hours. A slow rotation is better than a frozen shot, and that is the whole claim - it
// does not know what is in the picture, so it will one day cut away from someone mid-sentence.
// That is a property of switching on a clock, not a defect to be fixed later.
//
// It is its OWN observable object rather than state on BridgeModel for one concrete reason: the
// countdown ticks once a second, and a published tick on the model would re-render the entire
// multiview every second for a number that lives in one small button. Only the button observes
// this.
//
// What it deliberately does NOT do: touch Preview. Auto drives PROGRAM and nothing else, so
// whatever the operator staged is still there when they come back.

import Foundation
import Combine

/// Main-thread only, like the rest of the model it drives. The tick timer runs on the main
/// runloop, so there is no queue to reason about here.
final class AutoSwitcher: ObservableObject {

    /// Running or not. Never restored at launch: a Bridge that comes up already cutting, because
    /// of a checkbox somebody left on last week, is a nasty surprise on a live desk. The RANGE is
    /// remembered, the mode is not.
    @Published private(set) var isOn = false

    /// Whole seconds to the next cut, for the button's readout. Assigned only when the displayed
    /// second actually changes, so the 10 Hz tick below costs one view update per second.
    @Published private(set) var remaining = 0

    /// The operator's range, in WHOLE seconds. Persisted.
    ///
    /// Whole, not fractional, and that is a decision rather than a shortcut: these are the bounds
    /// of a RANDOM draw, so a tenth of a second at the edge is unobservable - the hold that
    /// actually happens is a random number in between either way. Sub-second precision would also
    /// need a third segment in a `m:ss` field that is legible precisely because it has two.
    var minSeconds: Int {
        didSet { UserDefaults.standard.set(minSeconds, forKey: Keys.min) }
    }
    var maxSeconds: Int {
        didSet { UserDefaults.standard.set(maxSeconds, forKey: Keys.max) }
    }

    /// Bounds on the range. One second is the floor because below that a cut is a flicker, not a
    /// shot. One hour is the ceiling: there is no scenario that wants longer, and an unbounded
    /// field is a place for a typo to hide.
    static let minAllowed = 1
    static let maxAllowed = 3600

    private enum Keys {
        static let min = "bridge.autoSwitch.minSeconds"
        static let max = "bridge.autoSwitch.maxSeconds"
    }

    private weak var model: BridgeModel?
    private var ticker: Timer?
    private var deadline: Date?
    private var channelSub: AnyCancellable?

    init(model: BridgeModel?) {
        self.model = model
        let d = UserDefaults.standard
        // 10 to 20, and both halves of that were argued rather than picked.
        //
        // The AVERAGE is long because our cuts are UNMOTIVATED: a director holds a shot until the
        // sense of it ends, a clock cannot, so every extra cut is another chance to land in the
        // middle of a sentence. On a sermon that is the whole cost.
        //
        // The SPREAD is wide for the same reason randomness is here at all. Ten seconds of spread
        // against a fifteen-second mean reads as a person at the desk; a narrow window reads as a
        // slightly wobbly metronome, which is the thing we were trying not to be.
        minSeconds = d.object(forKey: Keys.min) as? Int ?? 10
        maxSeconds = d.object(forKey: Keys.max) as? Int ?? 20

        // Watch the channel LIST itself rather than trusting every caller to remember a
        // `refresh()`. Forgetting one is not hypothetical: a restored profile left the button
        // dead on launch with three channels sitting right there, because the only paths that
        // recomputed were connect, add and remove. The explicit calls stay as belt and braces;
        // this is the one that cannot be forgotten.
        //
        // The main hop matters: `@Published` fires in willSet, so reading the array from the
        // sink directly would still see the OLD one.
        channelSub = model?.$channels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    // MARK: - Eligibility

    /// The cameras auto may cut to: everything with a live video transport. Recomputed on every
    /// pick rather than captured at start, so a camera that joins mid-rotation is simply in the
    /// next draw, and one that drops is simply not.
    ///
    /// A channel that is connected but has stopped delivering frames still counts. The model has
    /// no per-channel "are frames arriving" signal today, and inventing one for this feature was
    /// explicitly out of scope (operator, 2026-09-26).
    private var liveChannels: [BridgeChannel] {
        // `isConnected && videoActive`, which is the model's own test for "this channel has a
        // picture". `isConnected` ALONE is not it: on a camera channel it goes true at authorise
        // time, before a single frame and regardless of delivery mode, so a Control-only phone -
        // connected, video encoder off - would read as a candidate and auto would cut the
        // programme to black. Half a test is worse than none here, because it fails silently and
        // on air.
        model?.multiviewChannels.filter { $0.isConnected && $0.videoActive } ?? []
    }

    /// Auto needs somewhere to go: with one camera there is no rotation, only a timer that cuts a
    /// channel to itself.
    ///
    /// PUBLISHED rather than computed because the button has to grey out the moment a second
    /// camera appears or leaves, and `isConnected` lives on the CHANNEL - a view watching only
    /// the model would never hear about it. `refresh()` is the one place it is recomputed.
    @Published private(set) var canRun = false

    // MARK: - Control

    func toggle() { isOn ? stop() : start() }

    func start() {
        refresh()
        guard !isOn, canRun else { return }
        isOn = true
        // Pressed over a dark programme - and right after launch there IS no programme until the
        // first CUT - go to a live camera now instead of airing black for the whole first hold.
        // The same rule as an on-air camera dying mid-run (operator, 2026-09-28).
        rescueProgramIfDark()
        scheduleNext()
        // `.common` modes, NOT the default one. A plain scheduled timer stops firing the moment
        // macOS enters event tracking - an open menu, a popover, a drag - so the countdown would
        // freeze and the cut would simply not happen while the operator had something open. That
        // reads as "auto randomly stops working", which is the worst kind of bug to chase.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    /// Stop and forget. The next start rolls a fresh interval rather than resuming a half-spent
    /// one - "I turned it on" should mean the same thing every time.
    func stop() {
        guard isOn else { return }
        isOn = false
        deadline = nil
        remaining = 0
        ticker?.invalidate()
        ticker = nil
    }

    deinit {
        // The run loop retains a scheduled timer, so without this a deallocated switcher leaves a
        // 10 Hz wakeup firing for the life of the process. Unreachable today (one model, one
        // switcher) and cheap to be right about.
        ticker?.invalidate()
    }

    /// The operator cut by hand: that is them taking the desk back, so auto gets out of the way
    /// rather than resuming underneath and cutting again a second later.
    func operatorTookOver() { stop() }

    /// Something changed about the channels: one connected, one dropped, one was added or
    /// removed. Recomputes what is reachable, and - only if the operator engaged the rotation -
    /// rescues the programme and decides whether the rotation can continue.
    func refresh() {
        canRun = liveChannels.count >= 2

        // Everything below happens ONLY because the operator engaged the rotation. With AUTO off
        // the Bridge behaves exactly as it always has: a dead camera on air stays on air and airs
        // black, which is the switcher law this app is built on (a real desk does not rescue you,
        // it shows you what the input is doing). Rescuing unasked would be a new default
        // behaviour smuggled in behind a feature nobody switched on.
        guard isOn else { return }

        // Rescue BEFORE deciding to switch off, and that order is the whole point. Reversed, a
        // two-camera rig dies: the on-air camera drops, `canRun` goes false, auto quits - and
        // leaves the dead camera on air forever, because the thing that would have moved on just
        // quit. So the programme is saved first, even when the save leaves only one camera and
        // the rotation ends a line later.
        if rescueProgramIfDark() { scheduleNext() }   // the camera it put up gets a full hold

        // Down to one camera: switch OFF, and do not come back on when a second one returns.
        // Resuming by itself would be dangerous rather than helpful - a camera that reconnects is
        // often still in somebody's hands on the way to its position, and the rotation would put
        // it straight on air. Going back on air is the team's decision, made by pressing AUTO
        // when they are ready (operator, 2026-09-27).
        if !canRun { stop() }
    }

    /// Move the programme onto a camera that actually has a picture, if it is not on one now, and
    /// say whether it cut. Deliberately silent when the programme is already fine, and deliberately
    /// willing to act with only ONE camera left: getting off black matters more than whether a
    /// rotation can continue afterwards.
    @discardableResult
    private func rescueProgramIfDark() -> Bool {
        guard let model else { return false }
        let live = liveChannels
        let pgm = model.programID
        guard !live.contains(where: { $0.id == pgm }),
              let rescue = live.first(where: { $0.id != pgm }) else { return false }
        model.autoCut(to: rescue.id)
        return true
    }

    // MARK: - Timing

    private func tick() {
        guard isOn, let deadline else { return }
        let left = deadline.timeIntervalSinceNow
        if left <= 0 { cutNow(); return }
        let shown = Int(left.rounded(.up))
        if shown != remaining { remaining = shown }
    }

    /// Pick a camera and go. The next interval is rolled AFTER the cut, so a range edited while
    /// auto is running applies from the next shot and never yanks the number the operator is
    /// looking at.
    private func cutNow() {
        guard let model else { stop(); return }
        let live = liveChannels
        guard live.count >= 2 else { stop(); return }
        // Every live camera except the one on air. Nothing else is excluded, and that matters:
        // an earlier version also skipped the camera staged in PREVIEW, to avoid programme and
        // preview landing on the same channel. With three cameras that quietly starved one of
        // them - programme 1, preview 2, so the only candidate is 3; then programme 3, preview
        // still 2, so the only candidate is 1 - and camera 2 never reached air at all. Losing a
        // camera from the rotation is far worse than the collision it was avoiding (operator
        // found it in a minute of testing, 2026-09-27).
        let candidates = live.filter { $0.id != model.programID }
        guard let next = candidates.randomElement() else { stop(); return }

        // PREVIEW IS NEVER TOUCHED. It is the operator's workspace - the camera control panel is
        // bound to it - so a rotation that moves it retunes the controls under their hands for no
        // reason they can see. An earlier version flipped the outgoing programme into preview
        // whenever auto landed on the staged camera, which is what a manual CUT does; with three
        // cameras on a short interval it fired constantly and preview appeared to wander
        // (operator, 2026-09-27).
        //
        // The cost, accepted deliberately: when auto does put the staged camera on air,
        // programme and preview are the same channel, and one CUT press then switches auto off
        // without moving the picture (there is nothing to swap). Staging any camera clears it.
        // A second of puzzlement beats a preview with a mind of its own.
        model.autoCut(to: next.id)
        scheduleNext()
    }

    /// A fresh random hold inside the range. Random, not fixed, because a cut every exactly 15 s
    /// announces itself as a machine; an uneven rhythm reads as someone switching.
    private func scheduleNext() {
        // Clamp BOTH ends against BOTH bounds. Clamping the low end only at the floor and the
        // high end only at the ceiling lets a stored pair outside the range invert them, and
        // `Int.random(in:)` on an inverted range is a crash, not a bad value.
        let a = min(max(minSeconds, Self.minAllowed), Self.maxAllowed)
        let b = min(max(maxSeconds, Self.minAllowed), Self.maxAllowed)
        let lo = min(a, b), hi = max(a, b)
        let hold = lo == hi ? lo : Int.random(in: lo...hi)
        deadline = Date().addingTimeInterval(Double(hold))
        remaining = hold
    }

    /// `M:SS`, always, even for seven seconds. A readout that switches between `7` and `1:30`
    /// changes width mid-count and shoves whatever sits beside it.
    var display: String {
        guard isOn else { return "--:--" }
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}
