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
    case multiview, solo          // order = the toolbar switch order (Multiview first)
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
    @Published var mode: AppMode = .multiview {   // default to the switcher view
        didSet {
            guard mode != oldValue else { return }
            routeProgram()
            if mode == .multiview { syncMultiviewTally() }
            else { clearAllTally() }   // leaving multiview → cameras must not keep stale auto-tally
        }
    }

    /// Multiview switcher buses: the camera staged in PREVIEW and the camera live
    /// on PROGRAM.  `programID` set by CUT in Multiview; in Solo the program
    /// source is the selected camera (see `effectiveProgramID`).
    @Published var previewID: UUID? { didSet { syncTallyIfNeeded() } }
    @Published var programID: UUID? {
        didSet { routeProgram(); syncTallyIfNeeded() }
    }

    /// Set while `take()` swaps both buses so the two didSets don't EACH broadcast tally —
    /// otherwise the outgoing camera flashes red→off→green.  We broadcast ONCE after the
    /// swap (Studio's cutTransition discipline).
    private var suppressTallySync = false
    private func syncTallyIfNeeded() {
        guard mode == .multiview, !suppressTallySync else { return }
        syncMultiviewTally()
    }

    /// In Multiview, tally auto-follows the buses like a real switcher: the PROGRAM camera
    /// gets a red cue, the staged PREVIEW camera green, everyone else off — pushed to the
    /// iPhones (`setCue`) AND mirrored in `TallyStore` so the rail/preview show it.  Only
    /// fires on a real change, so it's event-driven (one packet per cut/stage, never per
    /// frame).  Solo keeps its manual Tally row untouched.
    /// `force` re-sends every cue even if unchanged — used when a camera (re)connects so its
    /// tally LED is re-asserted (the camera forgot its cue across the drop), bypassing the
    /// TallyStore dedup that would otherwise skip the "unchanged" send.
    private func syncMultiviewTally(force: Bool = false) {
        for ch in multiviewChannels {
            let state: TallyState = ch.id == programID ? .program
                                  : (ch.id == previewID ? .preview : .off)
            if !force && TallyStore.shared.state(for: ch.id) == state { continue }
            TallyStore.shared.set(state, for: ch.id)
            // `ch.send` routes to the channel's back-channel — the ARLV control side for a
            // combined "Screen Mirroring + Remote Control" channel, else its single receiver.
            // Skip if the operator turned tally OFF on that camera.
            if ch.tallyAllowed { ch.send(.setCue(state.rawValue)) }
        }
    }

    /// A channel's connectivity edge changed (wired to `BridgeChannel.onConnectivityChanged`).
    /// On (re)connect, re-assert tally so a rejoined camera's LED matches its bus again; on full
    /// disconnect, clear its stale tally border so a dead channel doesn't keep glowing red/green.
    private func handleConnectivityChange(_ channel: BridgeChannel) {
        // Tally: re-assert to a (re)connected camera; clear a fully-disconnected one's border.
        if channel.anyConnected {
            if mode == .multiview { syncMultiviewTally(force: true) }
        } else if TallyStore.shared.state(for: channel.id) != .off {
            TallyStore.shared.set(.off, for: channel.id)
        }
        // NDI dead-signal: if the ON-AIR source's VIDEO transport just dropped, push ONE black
        // frame so NDI reads as a clear "no source" instead of freezing on the camera's last
        // frame (#6).  Keyed off `isConnected` (the video side), so a combined channel that loses
        // its AirPlay video — even with its control link still up — still blacks the program.
        // NDI holds the last frame, so one black frame suffices until the operator cuts elsewhere.
        if channel.id == effectiveProgramID, !channel.isConnected, let black = blackProgramFrame {
            feedProgram(black, timeNs: DispatchTime.now().uptimeNanoseconds)
        }
    }

    /// A cached opaque-black 1080p BGRA frame, pushed to NDI when the program source drops (#6).
    private lazy var blackProgramFrame: CVPixelBuffer? = Self.makeBlackBuffer(width: 1920, height: 1080)

    private static func makeBlackBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        if let base = CVPixelBufferGetBaseAddress(buf) {
            var opaqueBlack: [UInt8] = [0, 0, 0, 255]   // BGRA: opaque black (not alpha-0 keyable)
            memset_pattern4(base, &opaqueBlack, CVPixelBufferGetBytesPerRow(buf) * height)
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    /// Clear every channel's tally (UI + the camera's LED) — used when leaving multiview, so a
    /// camera that was red/green on the switcher doesn't stay lit under Solo's manual tally.
    private func clearAllTally() {
        for ch in channels {
            if TallyStore.shared.state(for: ch.id) != .off { TallyStore.shared.set(.off, for: ch.id) }
            if ch.tallyAllowed { ch.send(.setCue(TallyState.off.rawValue)) }
        }
    }

    /// Wire a channel's connectivity-edge callback to the model (re-assert / clear tally).
    private func wireConnectivity(_ channel: BridgeChannel) {
        channel.onConnectivityChanged = { [weak self, weak channel] in
            guard let self, let channel else { return }
            self.handleConnectivityChange(channel)
        }
    }

    /// One-shot request to take the detached Multiview Wall window fullscreen (set by
    /// the "Full-Screen" button, consumed by the wall once its NSWindow exists).  Detach
    /// opens the same clean wall WINDOWED; Full-Screen opens it and flips it fullscreen.
    @Published var wallFullscreenRequested = false

    func previewChannel() -> BridgeChannel? { channels.first { $0.id == previewID } }
    func programChannel() -> BridgeChannel? { channels.first { $0.id == effectiveProgramID } }

    /// Load a camera into Preview (stage it).
    func stage(_ id: UUID) { previewID = id }
    /// Cut: the staged Preview camera goes live to Program.  REFUSES a Control-only source
    /// (videoActive=false): airing a channel with no video would silently dead-air the
    /// program outputs (NDI/RTSP/SRT/OBS) with no picture.  Covers the CUT button, the
    /// Space shortcut, and double-click hot-cut (all route through here).
    func take() {
        // Only cut to a source that is BOTH connected AND sending video — airing a
        // disconnected or control-only camera dead-airs the program outputs.
        guard let p = previewID,
              let pc = channels.first(where: { $0.id == p }),
              pc.isConnected, pc.videoActive else { return }
        // Flip-flop like Studio's cutTransition: Preview → Program, and the OUTGOING
        // Program drops back into Preview (so you can cut straight back).  Suppress the
        // per-didSet tally so the swap emits ONE cue per camera, no red→off→green flash.
        let outgoing = programID
        suppressTallySync = true
        programID = p
        previewID = outgoing
        suppressTallySync = false
        if mode == .multiview { syncMultiviewTally() }
    }

    // MARK: - Shortcut actions

    /// Space: cut Preview → Program (Multiview only; nothing to cut in Solo).
    func cutAction() { if mode == .multiview { take() } }

    /// Digit N (0-based): put camera N on PROGRAM — a hot-cut in Multiview, a
    /// selection in Solo.  Out-of-range is a no-op.
    func programSelect(_ index: Int) {
        let list = multiviewChannels                  // digits map to visible tiles, not RC channels
        guard index >= 0, index < list.count else { return }
        let channel = list[index]
        if mode == .multiview {
            // Don't hot-cut a disconnected or Control-only (no-video) source straight to air.
            guard channel.isConnected, channel.videoActive else { return }
            programID = channel.id
        } else {
            select(channel.id)
        }
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

    /// False when the current program source emits no raw H.264 (AirPlay / combined / capture):
    /// the PASSTHROUGH outputs (OBS relay / RTSP / SRT) can't carry it, so the UI warns instead
    /// of those outputs going silently black.  NDI is unaffected (it uses decoded frames).
    @Published var programSupportsPassthrough: Bool = true

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

    /// Add an EXTRA program output (from "+").  Created OFF — a fresh output must never
    /// auto-publish; the operator flips the toggle when ready.  The program tap is still
    /// wired here so toggling it on later starts streaming immediately.
    func addProgramOutput(_ output: VideoOutput) {
        configureOutput(output)
        programOutputs.append(output)
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
            let isProgram = channel.id == pid
            if isProgram {
                channel.onProgramFrame = { [weak self] buffer, timeNs in self?.feedProgram(buffer, timeNs: timeNs) }
                channel.onProgramFormat = { [weak self] payload in self?.feedProgramFormat(payload) }
                channel.onProgramSample = { [weak self] payload, ts in self?.feedProgramSample(payload, ts) }
            } else {
                channel.onProgramFrame = nil
                channel.onProgramFormat = nil
                channel.onProgramSample = nil
            }
            // H1: closures are set HERE (main); the receiver gates its per-frame taps on
            // this flag so non-program channels skip the per-frame main hop entirely.
            channel.setProgramSource(isProgram)
        }
        // Passthrough outputs (OBS/RTSP/SRT) need raw H.264; an AirPlay/combined/capture program
        // emits only decoded frames (NDI-only).  Flag it for the UI, and forget any cached OBS
        // format header so a reconnect can't replay the previous camera's SPS/PPS into a now
        // frameless relay (which would stall OBS's decoder).
        let programProducesRaw = channels.first(where: { $0.id == pid })?.producesRawH264 ?? true
        programSupportsPassthrough = (pid == nil) ? true : programProducesRaw
        if !programProducesRaw {
            for case let relay as AirliveRelayOutput in programOutputs { relay.clearLastFormat() }
        }
        // On a REAL source change, gate the OBS relay's samples until the NEW source's format
        // arrives (the forced keyframe below brings it) — otherwise OBS decodes the new camera's
        // H.264 against the previous camera's SPS/PPS for ~300 ms (#20).
        if pid != lastRoutedProgramID {
            lastRoutedProgramID = pid
            for case let relay as AirliveRelayOutput in programOutputs { relay.awaitFormat() }
        }
        requestKeyframeForProgram()   // instant relay resync on CUT / hot-cut / select
    }
    private var lastRoutedProgramID: UUID?

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
        // Only an ARLV camera actually sending video can satisfy a keyframe request: skip a
        // Control-only source (encoder off) AND an AirPlay/combined source (no ARLV encoder at
        // all) — a forceKeyframe to either is a wasted control packet that can't help.
        guard let pc = channels.first(where: { $0.id == effectiveProgramID }),
              pc.producesRawH264, pc.videoActive else { return }
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
        let n = multiviewChannels.count   // Remote-Control channels have no tile
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
            channel.updateAuth(require: !password.isEmpty, password: password,
                               disconnectNow: disconnectNow)
        }
    }

    /// Push the global auth config to ONE channel (used when a fresh channel's
    /// receiver comes online, so its very first connection is gated correctly).
    private func applyAuth(to channel: BridgeChannel) {
        let password = BridgeKeychain.password(account: Self.authAccount) ?? ""
        channel.updateAuth(require: !password.isEmpty, password: password,
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

    /// Reorder the program outputs (drag-reorder in the Outputs rail).  Order is
    /// purely cosmetic — it doesn't change which channel is on program — so a plain
    /// @Published move (which re-renders the list) is all that's needed.
    func moveProgramOutput(from source: IndexSet, to destination: Int) {
        programOutputs.move(fromOffsets: source, toOffset: destination)
    }

    /// Publish each channel's position (Bonjour TXT `ord`) so the iPhone lists
    /// channels in the operator's Bridge order — names stay free to rename.
    private func pushChannelOrder() {
        for (index, channel) in channels.enumerated() { channel.updateOrder(index) }
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
        wireConnectivity(channel)
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

    // MARK: - Multiview tiles

    /// Tiles shown in the multiview.  Every channel kind carries video — a combined
    /// "Screen Mirroring + Remote Control" channel shows its AirPlay side — so all channels get
    /// a tile.  The indirection stays (grid + capacity + program-select + tally all read it) so
    /// a future tileless kind would have a single filter point.
    var multiviewChannels: [BridgeChannel] { channels }

    // MARK: - Profiles (save / load the whole setup)

    /// Snapshot the current configuration into a portable profile.  LIVE state
    /// (connections, which outputs run, the PVW/PGM buses) is NOT captured — only the
    /// layout the operator built.  See `BridgeProfile`.
    func snapshotProfile() -> BridgeProfile {
        let channelConfigs = channels.map { ch in
            BridgeProfile.ChannelConfig(
                id: ch.id, name: ch.name, kind: ch.kind.rawValue,
                captureDeviceID: ch.captureDeviceID, delayRaw: ch.delay.rawValue,
                extraDelayMs: ch.extraDelayMs, previewEnabled: ch.previewEnabled)
        }
        let outputConfigs = programOutputs.map { out in
            BridgeProfile.OutputConfig(
                kind: out.kind.rawValue, label: out.label, config: out.config,
                port: (out as? RTSPOutput).map { Int($0.port) })
        }
        return BridgeProfile(mode: mode.rawValue, channels: channelConfigs, outputs: outputConfigs)
    }

    /// Replace the ENTIRE setup with a saved profile: tear down the current channels +
    /// outputs, then rebuild from the snapshot.  Channels come back as fresh receiver
    /// slots (no live connection — the iPhone reconnects by the preserved id); outputs
    /// come back OFF (a restored output must not auto-publish).
    func applyProfile(_ profile: BridgeProfile) {
        // Silence the per-didSet tally broadcasts while the buses churn through the rebuild
        // (previewID/programID/mode/selectedID each fire on the way); we sync ONCE at the
        // end with the final state in place.
        suppressTallySync = true

        // 1. Tear down the current setup.
        for channel in channels { channel.stop() }
        channels.forEach { TallyStore.shared.clear($0.id) }
        channels = []
        for output in programOutputs { output.stop() }
        programOutputs = []
        previewID = nil; programID = nil; selectedID = nil

        // 2. Mode (before rebuilding so the tally/routing didSets see the right mode).
        mode = AppMode(rawValue: profile.mode) ?? .multiview

        // 3. Rebuild channels — preserve ids so a previously-paired phone reconnects to
        //    the same slot.  Settings are set BEFORE start() so the receiver's init reads
        //    the right delay / extra-delay.
        for (index, cfg) in profile.channels.enumerated() {
            let channel = BridgeChannel(
                id: cfg.id, name: cfg.name,
                kind: ChannelKind(rawValue: cfg.kind) ?? .airlive,
                captureDeviceID: cfg.captureDeviceID,
                delay: LatencyPreset(rawValue: cfg.delayRaw) ?? .normal)
            channel.extraDelayMs = cfg.extraDelayMs
            channel.previewEnabled = cfg.previewEnabled
            wireConnectivity(channel)
            channels.append(channel)
            channel.start(order: index)
            applyAuth(to: channel)            // gate it with the current global password
        }
        previewID = channels.first?.id        // stage the first camera (matches addChannel)
        selectedID = channels.first?.id

        // 4. Rebuild outputs — all OFF (operator toggles them on).
        for cfg in profile.outputs {
            guard let output = makeOutput(from: cfg) else { continue }
            configureOutput(output)
            programOutputs.append(output)
        }

        routeProgram()       // wire the program tap across the new channels
        pushChannelOrder()   // advertise positions

        // Now that the full setup is in place, broadcast tally once (matches take()'s
        // single-sync discipline).
        suppressTallySync = false
        if mode == .multiview { syncMultiviewTally() }
    }

    /// Reconstruct a `VideoOutput` from a saved config (OFF — the caller never starts it).
    /// Unknown / not-implemented kinds (e.g. `.vcam`) are skipped.
    private func makeOutput(from cfg: BridgeProfile.OutputConfig) -> VideoOutput? {
        guard let kind = OutputKind(rawValue: cfg.kind) else { return nil }
        let output: VideoOutput?
        switch kind {
        case .ndi:  output = NDIOutput(label: cfg.label)
        case .obs:  output = AirliveRelayOutput(label: cfg.label)
        case .rtsp: output = RTSPOutput(label: cfg.label, port: UInt16(cfg.port ?? 8554))
        case .srt:  output = SRTOutput(label: cfg.label)
        case .vcam: output = nil                       // not implemented
        }
        output?.config = cfg.config
        return output
    }

    // MARK: - Private

    /// "Camera N" using the lowest free index, so removing CAM 2 and re-adding reuses
    /// "Camera 2" rather than ever-increasing numbers.  All kinds are cameras (a combined
    /// channel is a camera with both video + control).
    private func defaultChannelName() -> String {
        let used = Set(channels.map(\.name))
        var n = 1
        while used.contains("Camera \(n)") { n += 1 }
        return "Camera \(n)"
    }
}
