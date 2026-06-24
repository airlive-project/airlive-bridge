// BridgeModel.swift — top-level app state.
//
// Owns the list of channels and the current selection.  ContentView creates it
// as a `@StateObject`; the three zones (Channels rail | Selected channel +
// control | Outputs) observe it.  Pure model state + selection helpers — no
// networking lives here (each channel owns its own receiver).

import Foundation
import CoreVideo

/// What the Bridge is monitoring / sending: one camera at a time (Solo) or the
/// composited grid of all cameras (Multiview).  The two are MUTUALLY EXCLUSIVE
/// for output — we never publish solo feeds AND the multiview program at once
/// (Phase 2 wires the senders to this).
enum AppMode: String, CaseIterable, Identifiable {
    case solo, multiview
    var id: String { rawValue }
    var label: String { self == .solo ? "Solo" : "Multiview" }
}

/// Application-level state for Airlive Bridge.  `ObservableObject` for macOS 13
/// compatibility (see `BridgeChannel`).
final class BridgeModel: ObservableObject {

    /// All channels, in display order.
    @Published var channels: [BridgeChannel] = []

    /// Currently-selected channel's id (drives the center zone), or nil when
    /// none is selected.  In Solo mode the selected camera IS the program source.
    @Published var selectedID: UUID? { didSet { if mode == .solo { routeProgram() } } }

    /// Solo (one camera) vs Multiview (the switcher).
    @Published var mode: AppMode = .solo { didSet { routeProgram() } }

    /// Multiview switcher buses: the camera staged in PREVIEW and the camera live
    /// on PROGRAM.  `programID` set by CUT in Multiview; in Solo the program
    /// source is the selected camera (see `effectiveProgramID`).
    @Published var previewID: UUID?
    @Published var programID: UUID? { didSet { routeProgram() } }

    func previewChannel() -> BridgeChannel? { channels.first { $0.id == previewID } }
    func programChannel() -> BridgeChannel? { channels.first { $0.id == effectiveProgramID } }

    /// Load a camera into Preview (stage it).
    func stage(_ id: UUID) { previewID = id }
    /// Cut: the staged Preview camera goes live to Program.
    func take() { if let p = previewID { programID = p } }

    // MARK: - Shortcut actions

    /// Space: cut Preview → Program (Multiview only; nothing to cut in Solo).
    func cutAction() { if mode == .multiview { take() } }

    /// Digit N (0-based): put camera N on PROGRAM — a hot-cut in Multiview, a
    /// selection in Solo.  Out-of-range is a no-op.
    func programSelect(_ index: Int) {
        guard index >= 0, index < channels.count else { return }
        let id = channels[index].id
        if mode == .multiview { programID = id } else { select(id) }
    }

    /// ⇧+digit N (0-based): set the FOCUSED camera's lens to its Nth available
    /// lens — the staged (Preview) camera in Multiview, the selected camera in
    /// Solo.  No-op if there's no camera or N is out of range.
    func lensSelect(_ index: Int) {
        let target = mode == .multiview ? previewChannel() : selectedChannel
        guard let channel = target,
              let lenses = channel.remote?.availableLenses,
              index >= 0, index < lenses.count else { return }
        channel.send(.setLens(lenses[index]))
    }

    // MARK: - Program bus (the single output path)
    //
    // PROGRAM is what's published downstream: the program output(s) (NDI/SRT/RTSP)
    // are created ONCE and send continuously; switching the program source (CUT in
    // Multiview, or selecting a camera in Solo) only changes which channel's frames
    // feed them — the sender is never recreated, so there's no flicker/re-discovery
    // (the conflict-free switch).  Cameras stream in our own protocol; only the
    // program is converted to NDI.

    /// Downstream program outputs (NDI today; SRT/RTSP later).
    @Published var programOutputs: [VideoOutput] = []

    /// The channel currently feeding the program: the PGM camera in Multiview, the
    /// selected camera in Solo.
    var effectiveProgramID: UUID? { mode == .solo ? selectedID : programID }

    /// Seed ONE output of every implemented kind, all OFF — so the operator sees the
    /// full protocol surface as cards and just toggles the ones they want on (no
    /// hunting in a menu).  The "+" then adds EXTRA instances (a 2nd NDI, another SRT
    /// adapter…).  Not started here; `feedProgram*` only sends to live outputs.
    private func seedDefaultOutputs() {
        let defaults: [VideoOutput] = [
            NDIOutput(label: OutputKind.ndi.displayName),
            AirliveRelayOutput(label: OutputKind.obs.displayName),
            RTSPOutput(label: OutputKind.rtsp.displayName, port: 8554),
            SRTOutput(label: OutputKind.srt.displayName),
        ]
        defaults.forEach { configureOutput($0) }
        programOutputs = defaults
    }

    /// Wire output-kind-specific hooks (currently: the relay's keyframe request).
    private func configureOutput(_ output: VideoOutput) {
        if let relay = output as? AirliveRelayOutput {
            // onReady fires on main once OBS is actually connected — force one IDR
            // even if the program source didn't change (the fresh relay needs it).
            relay.onReady = { [weak self] in self?.requestKeyframeForProgram(force: true) }
        }
    }

    /// Add an EXTRA program output (from "+").  Starts immediately; the tap is rewired.
    func addProgramOutput(_ output: VideoOutput) {
        configureOutput(output)
        programOutputs.append(output)
        output.start()
        routeProgram()
    }
    func removeProgramOutput(_ output: VideoOutput) {
        output.stop()
        programOutputs.removeAll { $0.id == output.id }
    }

    /// Wire the effective-program channel's frames to the program outputs; clear
    /// the tap on every other channel so exactly one feeds the program.
    func routeProgram() {
        let pid = effectiveProgramID
        for channel in channels {
            if channel.id == pid {
                channel.onProgramFrame = { [weak self] buffer, timeNs in self?.feedProgram(buffer, timeNs: timeNs) }
                channel.onProgramFormat = { [weak self] payload in self?.feedProgramFormat(payload) }
                channel.onProgramSample = { [weak self] payload, ts in self?.feedProgramSample(payload, ts) }
            } else {
                channel.onProgramFrame = nil
                channel.onProgramFormat = nil
                channel.onProgramSample = nil
            }
        }
        requestKeyframeForProgram()   // instant relay resync on CUT / hot-cut / select
    }

    /// Last program we asked an IDR for — so routine re-routes (mode toggle, channel
    /// add/remove, re-selecting the SAME source, staging to Preview) never re-poke the
    /// camera.  We force a keyframe only when the program SOURCE actually changes (a
    /// real CUT) or when a relay first connects (`force`).
    private var lastKeyframeProgramID: UUID?
    private var keyframeDebounce: DispatchWorkItem?
    /// Coalesce window for forced IDRs.  ≥ the camera's own ~250 ms rate-limit and a
    /// GOP floor, so a director hammering CUT (A→B→A…) yields ONE forceKeyframe on
    /// the SETTLED program, not one per intermediate click (per the camera team's
    /// thermal note — bursts pushed the phone nominal→fair).
    private let keyframeDebounceSeconds = 0.3

    /// Ask the on-air camera for a fresh keyframe — but ONLY when an OBS relay is
    /// ACTUALLY connected and receiving, AND the program source genuinely changed (or
    /// `force` for a fresh relay connect).  Gated tightly so the phone emits at most
    /// one extra I-frame per real CUT and never for routine UI churn or for NDI, and
    /// DEBOUNCED so rapid CUTs collapse to a single IDR on the settled program.
    private func requestKeyframeForProgram(force: Bool = false) {
        let obsReceiving = programOutputs.contains { ($0 as? AirliveRelayOutput)?.isConnected == true }
        guard obsReceiving else { return }
        let pid = effectiveProgramID
        guard force || pid != lastKeyframeProgramID else { return }   // real source change only
        lastKeyframeProgramID = pid

        keyframeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Re-check at fire time: the program may have moved again and the relay
            // may have dropped — never poke the phone for nothing.
            guard self.programOutputs.contains(where: { ($0 as? AirliveRelayOutput)?.isConnected == true }) else { return }
            self.channels.first { $0.id == self.effectiveProgramID }?.send(.forceKeyframe())
        }
        keyframeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + keyframeDebounceSeconds, execute: work)
    }

    private func feedProgram(_ buffer: CVPixelBuffer, timeNs: UInt64) {
        for output in programOutputs where output.isLive {
            output.send(buffer, timeNs: timeNs)   // buffer outputs (NDI)
        }
    }
    private func feedProgramFormat(_ payload: Data) {
        for output in programOutputs where output.isLive { output.relayFormat(payload) }   // relay (OBS)
    }
    private func feedProgramSample(_ payload: Data, _ ts: Int64) {
        for output in programOutputs where output.isLive { output.relaySample(payload, timestampMicros: ts) }
    }

    // MARK: - Multiview grid (adaptive 4 / 8 / 12 / 16)

    /// Cells in the multiview grid: the smallest of 4/8/12/16 that fits the
    /// channel count (capped at 16), so the grid grows in real steps instead of
    /// Studio's fixed 8.
    func multiviewCapacity() -> Int {
        let n = channels.count
        for cap in [4, 8, 12, 16] where n <= cap { return cap }
        return 16
    }

    /// Columns for the current capacity: a 2×2 quad for 4, otherwise 4-wide
    /// (4×2 / 4×3 / 4×4) — the standard multiview convention.
    func multiviewColumns() -> Int { multiviewCapacity() == 4 ? 2 : 4 }

    // MARK: - Security (ONE global password for the whole Bridge)
    //
    // The operator sets a single password that gates EVERY channel (simpler than
    // per-channel for a solo director).  The wire is still per-connection HMAC —
    // we just feed every channel's receiver the same secret.  Stored in the
    // Keychain (one account); OFF by default unless a password exists at launch.

    /// Keychain account for the single global Bridge password.
    private static let authAccount = "global"

    /// True when a global password is stored.  Setting a password IS enabling
    /// auth (it gates every channel); clearing it leaves the Bridge open — there
    /// is no separate toggle.  Derived (not @Published); `setPassword` fires
    /// `objectWillChange` so the UI re-reads it.
    var hasPassword: Bool { BridgeKeychain.password(account: Self.authAccount) != nil }

    init() { seedDefaultOutputs() }

    /// Set (or clear) the global password.  Stored in the Keychain, then pushed
    /// to every channel.  A password change is a REVOCATION (`disconnectNow`) so
    /// currently-connected cameras drop and must re-auth with the new secret.
    func setPassword(_ password: String) {
        BridgeKeychain.setPassword(password, account: Self.authAccount)
        objectWillChange.send()                 // `hasPassword` is derived
        pushAuthToAll(disconnectNow: true)
    }

    /// Push the current global auth config to every channel's receiver.  Auth is
    /// required exactly when a password exists.
    func pushAuthToAll(disconnectNow: Bool) {
        let password = BridgeKeychain.password(account: Self.authAccount) ?? ""
        for channel in channels {
            channel.receiver?.updateAuth(require: !password.isEmpty, password: password,
                                         disconnectNow: disconnectNow)
        }
    }

    /// Push the global auth config to ONE channel (used when a fresh channel's
    /// receiver comes online, so its very first connection is gated correctly).
    private func applyAuth(to channel: BridgeChannel) {
        let password = BridgeKeychain.password(account: Self.authAccount) ?? ""
        channel.receiver?.updateAuth(require: !password.isEmpty, password: password,
                                     disconnectNow: false)
    }

    // MARK: - Selection helpers

    /// The currently-selected channel, or nil.
    var selectedChannel: BridgeChannel? {
        guard let selectedID else { return nil }
        return channels.first { $0.id == selectedID }
    }

    /// Select a channel by id (no-op if it isn't in the list).  In Multiview the
    /// selection also STAGES it into Preview, so picking a channel on the left
    /// loads it to the Preview window (CUT then sends it to Program).
    func select(_ id: UUID) {
        guard channels.contains(where: { $0.id == id }) else { return }
        selectedID = id
        if mode == .multiview { previewID = id }
    }

    /// Reorder channels (drag in the Channels rail).  The multiview reads
    /// `channels` order, so the grid follows automatically; program/preview are
    /// tracked by id, so they stay valid.
    func moveChannel(from source: IndexSet, to destination: Int) {
        channels.move(fromOffsets: source, toOffset: destination)
        pushChannelOrder()
    }

    /// Publish each channel's position (Bonjour TXT `ord`) so the iPhone lists
    /// channels in the operator's Bridge order — names stay free to rename.
    private func pushChannelOrder() {
        for (index, channel) in channels.enumerated() { channel.receiver?.updateOrder(index) }
    }

    // MARK: - Channel management

    /// Create a new channel with an auto-numbered default name, append it, and
    /// select it.  Returns the new channel.
    @discardableResult
    func addChannel(kind: ChannelKind = .airlive,
                    captureDeviceID: String? = nil,
                    name: String? = nil) -> BridgeChannel {
        let channel = BridgeChannel(name: name ?? defaultChannelName(),
                                    kind: kind, captureDeviceID: captureDeviceID)
        channels.append(channel)
        selectedID = channel.id
        if previewID == nil { previewID = channel.id }   // stage the first camera
        channel.start(order: channels.count - 1)   // first advert already carries the right ord
        applyAuth(to: channel)      // gate it with the current global password
        routeProgram()              // wire the program tap (covers the new channel)
        pushChannelOrder()          // advertise positions (this one + any shifted)
        return channel
    }

    /// Stop and remove the channel with `id`, fixing up the selection if the
    /// removed channel was selected (falls back to the previous channel, or nil
    /// when the list becomes empty).
    func removeChannel(_ id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].stop()
        channels.remove(at: index)
        TallyStore.shared.clear(id)   // don't leak the channel's tally entry



        // Keep the switcher buses valid: a removed camera can't be PVW/PGM.
        if previewID == id { previewID = channels.first?.id }
        if programID == id { programID = nil }
        routeProgram()       // re-wire the program tap after the list changed
        pushChannelOrder()   // re-number remaining channels' positions

        guard selectedID == id else { return }
        if channels.isEmpty {
            selectedID = nil
        } else {
            // Prefer the channel that took the removed one's slot; else the last.
            selectedID = channels[min(index, channels.count - 1)].id
        }
    }

    // MARK: - Private

    /// "Camera N" using the lowest free index, so removing CAM 2 and adding
    /// again reuses "Camera 2" rather than ever-increasing numbers.
    private func defaultChannelName() -> String {
        let used = Set(channels.map(\.name))
        var n = 1
        while used.contains("Camera \(n)") { n += 1 }
        return "Camera \(n)"
    }
}
