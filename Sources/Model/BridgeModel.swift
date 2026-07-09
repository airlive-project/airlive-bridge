// BridgeModel.swift — top-level app state.
//
// Owns the list of channels and the current selection.  ContentView creates it
// as a `@StateObject`; the three zones (Channels rail | Selected channel +
// control | Outputs) observe it.  Pure model state + selection helpers — no
// networking lives here (each channel owns its own receiver).

import Foundation
import CoreVideo
import Combine   // session-autosave subscriptions (model + per-channel objectWillChange)

/// ⚠️ Solo is REMOVED FROM THE UI for launch (2026-07-03): the toolbar switch is
/// gone and `mode` stays `.multiview` for the app's whole life (profile load pins
/// it too).  The enum + the `mode ==` branches below are KEPT deliberately — the
/// routing/tally paths are field-verified, and stripping the plumbing would mean
/// re-touching them right before release for zero behaviour change.  If Solo
/// returns it will be as per-output aux routing, not as this global switch.
enum AppMode: String, CaseIterable, Identifiable {
    case multiview, solo
    var id: String { rawValue }
    var label: String { self == .solo ? "Solo" : "Multiview" }
}

/// Application-level state for Airlive Bridge.  `ObservableObject` for macOS 13
/// compatibility (see `BridgeChannel`).
final class BridgeModel: ObservableObject {

    /// All channels, in display order.
    @Published var channels: [BridgeChannel] = []

    /// Display name of the loaded/saved profile — the `.airliveprofile` FILE name
    /// (set by the app's Save/Open menu actions).  Shown in the window title, OBS
    /// style: "Airlive Bridge 1.0.0 - Profile: EAGLES".  "Default" until the
    /// operator saves or opens one.  Persisted so the title survives relaunches.
    @Published var profileName: String = "Default" {
        didSet { UserDefaults.standard.set(profileName, forKey: "bridge.profileName") }
    }

    /// The named profile FILE behind menu "Save Profile" (update-in-place); nil until
    /// the operator saves/opens one — then Save overwrites it without a panel.
    var profileURL: URL? {
        didSet { UserDefaults.standard.set(profileURL?.path, forKey: "bridge.profileURL") }
    }


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
        // Re-pick the program feed mode when the ON-AIR source's connectivity flips: a mid-air
        // drop falls to continuous black, a reconnect goes back to passthrough/transcode — so
        // every output keeps carrying the program across the gap (never a freeze, never silence).
        if channel.id == effectiveProgramID {
            applyFeedMode(computeFeedMode())
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

    /// LAW: the PROGRAM streams to EVERY output, no exceptions.  How the passthrough outputs
    /// (OBS/RTSP/SRT) get their H.264 depends on what's on air:
    ///   • `.passthrough` — an Airlive camera: forward its ORIGINAL bitstream (zero transcode);
    ///   • `.transcode`   — a source with decoded frames only (AirPlay mirror / HDMI capture):
    ///                      encode those frames with `programEncoder`;
    ///   • `.black`       — no live video at all: a 30 fps black frame, encoded the same way.
    /// NDI always takes the decoded frames directly and is unaffected by the mode.
    enum ProgramFeedMode { case passthrough, transcode, black }
    private var programFeedMode: ProgramFeedMode = .black

    private var blackTimer: DispatchSourceTimer?
    private lazy var programEncoder: ProgramEncoder = {
        let enc = ProgramEncoder()
        // Guarded by the CURRENT mode ON MAIN: a VT callback already in flight when the operator
        // cuts back to a raw camera must not slip a stale encoded format/sample into the program.
        enc.onFormat = { [weak self] payload in
            guard let self, self.programFeedMode != .passthrough else { return }
            self.feedProgramFormat(payload)
        }
        enc.onSample = { [weak self] payload, pts in
            guard let self, self.programFeedMode != .passthrough else { return }
            self.feedProgramSample(payload, pts)
        }
        return enc
    }()

    /// The mode the CURRENT program state calls for.  Main-confined.
    private func computeFeedMode() -> ProgramFeedMode {
        guard let pc = channels.first(where: { $0.id == effectiveProgramID }),
              pc.isConnected, pc.videoActive else { return .black }
        return pc.producesRawH264 ? .passthrough : .transcode
    }

    /// Apply a feed mode: run the black ticker only in `.black`, keep the encoder alive for
    /// both encoded modes, drop it entirely on raw passthrough.  Idempotent; main-confined
    /// (all callers — routeProgram, connectivity edges — are main).
    private func applyFeedMode(_ mode: ProgramFeedMode) {
        programFeedMode = mode
        switch mode {
        case .black:
            programEncoder.start()
            if blackTimer == nil {
                pushBlackFrame()                        // immediate — don't wait a frame interval
                let t = DispatchSource.makeTimerSource(queue: .main)
                t.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33))
                t.setEventHandler { [weak self] in self?.pushBlackFrame() }
                t.resume()
                blackTimer = t
            }
        case .transcode:
            blackTimer?.cancel(); blackTimer = nil
            programEncoder.start()   // fed per-frame from feedProgram()
        case .passthrough:
            blackTimer?.cancel(); blackTimer = nil
            programEncoder.stop()
        }
    }

    private func pushBlackFrame() {
        guard let black = blackProgramFrame else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        feedProgram(black, timeNs: now)            // NDI/HDMI — isLive-gated inside (no-op when none live)
        // Thermal: the 1080p hardware H.264 encode is the expensive part — run it ONLY
        // when a passthrough consumer (connected OBS / PLAYING RTSP / connected SRT) is
        // actually there.  An idle Bridge (no outputs, OBS not connected) must not burn a
        // 30 fps encode for nobody (CLAUDE.md "no work for nobody").  Checked per tick, so
        // it starts automatically the moment a consumer connects — no re-arm needed.
        if hasLivePassthroughConsumer() {
            programEncoder.encode(black, timeNs: now)  // OBS/RTSP/SRT (H.264)
        }
    }

    /// Clear every channel's tally (UI + the camera's LED) — used when leaving multiview, so a
    /// camera that was red/green on the switcher doesn't stay lit under Solo's manual tally.
    private func clearAllTally() {
        for ch in channels {
            if TallyStore.shared.state(for: ch.id) != .off { TallyStore.shared.set(.off, for: ch.id) }
            if ch.tallyAllowed { ch.send(.setCue(TallyState.off.rawValue)) }
        }
    }

    /// Wire a channel's connectivity-edge callback to the model (re-assert / clear tally),
    /// and its change stream to the session autosave — a rename / delay tweak on the
    /// channel object doesn't touch any model-level @Published, so the model wouldn't
    /// hear about it otherwise.  (Autosave diffs the encoded snapshot, so the channel's
    /// live-state churn — snapshots, connects — costs one tiny JSON encode, no disk.)
    private func wireConnectivity(_ channel: BridgeChannel) {
        channel.onConnectivityChanged = { [weak self, weak channel] in
            guard let self, let channel else { return }
            self.handleConnectivityChange(channel)
        }
        // Keyed by channel id (NOT stored in the grow-forever set): the entry dies
        // with the channel in removeChannel / the profile teardown, so a long session
        // of add/remove cycles can't accumulate dead subscriptions.
        channelAutosaveSubs[channel.id] = channel.objectWillChange
            .sink { [weak self] _ in self?.scheduleAutosave() }
    }

    /// One-shot request to take the detached Multiview Wall window fullscreen (set by
    /// the "Full-Screen" button, consumed by the wall once its NSWindow exists).  Detach
    /// opens the same clean wall WINDOWED; Full-Screen opens it and flips it fullscreen.
    @Published var wallFullscreenRequested = false

    func previewChannel() -> BridgeChannel? { channels.first { $0.id == previewID } }
    func programChannel() -> BridgeChannel? { channels.first { $0.id == effectiveProgramID } }

    /// Load a camera into Preview (stage it).
    func stage(_ id: UUID) { previewID = id }
    /// Cut: the staged Preview camera goes live to Program.  ANY created channel can be cut to air,
    /// signal or not — a channel with no live video airs BLACK (like a real switcher: an empty input
    /// is a legitimate program; the black feeder covers NDI, passthrough blacks on its timeout).
    /// Covers the CUT button, the Space shortcut, and double-click hot-cut (all route through here).
    func take() {
        guard let p = previewID, channels.contains(where: { $0.id == p }) else { return }
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
    /// Plain digit 1–9: stage that tile in PREVIEW — the safe bus, same as clicking
    /// the tile.  (Direct-to-air lives on ⌘digit — `cutDirect` — the classic
    /// two-bus switcher keyboard: number row = preview bus, ⌘row = program bus.)
    func programSelect(_ index: Int) {
        let list = multiviewChannels                  // digits map to visible tiles, not RC channels
        guard index >= 0, index < list.count else { return }
        select(list[index].id)                        // select() also stages Preview
    }

    /// ⌘digit 1–9: cut that tile STRAIGHT to PROGRAM, preview untouched.  Any created
    /// channel cuts to air — no signal = black program (real-switcher model).
    func cutDirect(_ index: Int) {
        let list = multiviewChannels
        guard index >= 0, index < list.count else { return }
        programID = list[index].id
    }

    /// ⇧+digit N (0-based): set the FOCUSED camera's lens to its Nth available
    /// lens — the staged (Preview) camera in Multiview, the selected camera in
    /// Solo.  No-op if there's no camera or N is out of range.
    func lensSelect(_ index: Int) {
        let target = mode == .multiview ? previewChannel() : selectedChannel
        guard let channel = target,
              let lenses = channel.remote?.availableLenses,
              index >= 0, index < lenses.count else { return }
        channel.selectLens(lenses[index])   // optimistic — highlight moves instantly, keyboard too
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
            AirliveRelayOutput(label: OutputKind.obs.displayName),   // OBS Plugin pinned at the TOP
            NDIOutput(label: OutputKind.ndi.displayName),
            HDMIOutput(label: OutputKind.hdmi.displayName),
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
            // Live Connected/Waiting status on the OBS card.
            relay.onConnectionChanged = { [weak self] in self?.objectWillChange.send() }
            // ALWAYS ON — no toggle: the plugin receives, the Bridge sends, period.  Same-machine
            // loopback: when OBS (with the source) is up it connects within ~1 s, otherwise the
            // relay just keeps retrying — zero operator action, nothing to mis-toggle.
            relay.start()
        }
        // SRT peer accepted the call / RTSP client hit PLAY — force one IDR so the viewer decodes
        // NOW, not at the next natural keyframe (the camera's LAN GOP is 6–10 s; a mid-GOP join
        // would sit dark that long).
        if let srt = output as? SRTOutput {
            srt.onReady = { [weak self] in self?.requestKeyframeForProgram(force: true) }
            // Spinner → green on the card the moment the caller actually connects (and back on drop).
            srt.onConnectionChanged = { [weak self] in self?.objectWillChange.send() }
        }
        if let rtsp = output as? RTSPOutput {
            rtsp.onPlay = { [weak self] in self?.requestKeyframeForProgram(force: true) }
            rtsp.onStateChanged = { [weak self] in self?.objectWillChange.send() }   // lastError → card
        }
        if let ndi = output as? NDIOutput {
            ndi.onStateChanged = { [weak self] in self?.objectWillChange.send() }    // lastError → card
        }
        if let hdmi = output as? HDMIOutput {
            hdmi.onStateChanged = { [weak self] in self?.objectWillChange.send() }   // lastError → card
        }
        // An output added mid-stream starts with the CURRENT program SPS/PPS (the camera won't
        // resend them — once per connection), so its first decoded frame is the forced IDR above.
        if let cached = lastProgramFormatPayload { output.relayFormat(cached) }
    }

    /// Add an EXTRA program output (from "+").  Created OFF — a fresh output must never
    /// auto-publish; the operator flips the toggle when ready.  The program tap is still
    /// wired here so toggling it on later starts streaming immediately.
    func addProgramOutput(_ output: VideoOutput) {
        configureOutput(output)
        programOutputs.append(output)
        routeProgram()
        // Undo tracks the CURRENT instance through remove→restore cycles via a Ref box
        // (a restored output is a fresh object with a fresh id).
        let cfg = outputConfig(of: output)
        let ref = Ref(output)
        registerUndo(
            undo: { [weak self] in self?.removeProgramOutput(ref.value) },
            redo: { [weak self] in if let new = self?.restoreOutput(cfg) { ref.value = new } })
    }
    func removeProgramOutput(_ output: VideoOutput) {
        guard let index = programOutputs.firstIndex(where: { $0.id == output.id }) else { return }
        let cfg = outputConfig(of: output)
        let ref = Ref(output)
        registerUndo(
            undo: { [weak self] in if let new = self?.restoreOutput(cfg, at: index) { ref.value = new } },
            redo: { [weak self] in self?.removeProgramOutput(ref.value) })
        output.stop()
        programOutputs.remove(at: index)
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
        // Leaving raw passthrough (AirPlay/capture/Control-only on air): forget the CAMERA's
        // cached SPS/PPS so a reconnecting output can't replay it against encoder frames.
        // The encoder re-populates the cache with ITS format on the first IDR (≤1 s).
        let pc = channels.first(where: { $0.id == pid })
        let programProducesRaw = (pc?.producesRawH264 ?? true) && (pc?.videoActive ?? true)
        if !programProducesRaw {
            lastProgramFormatPayload = nil
            for output in programOutputs { output.clearLastFormat() }   // OBS + RTSP + SRT (NDI no-op)
        }
        // Pick how the passthrough outputs are fed for THIS program state (LAW: every output
        // always carries the program): camera → raw passthrough, AirPlay/capture → transcode,
        // no live video → continuous black.  handleConnectivityChange re-applies on drops.
        applyFeedMode(computeFeedMode())
        // On a REAL source change, gate EVERY passthrough output until the new source's format
        // arrives (#20 — was OBS-relay-only; RTSP/SRT decoded ~300 ms against the old SPS/PPS), and
        // FORCE an IDR for the new source.  Forcing (not the lastKeyframeProgramID dedup) is
        // essential: after A→AirPlay→A the dedup sees A unchanged and skips, leaving the relay gated
        // with no keyframe → OBS frozen for a GOP.  The force still no-ops safely if the new source
        // can't produce a keyframe (requestKeyframe re-checks producesRawH264/videoActive).
        if pid != lastRoutedProgramID {
            lastRoutedProgramID = pid
            for output in programOutputs { output.awaitFormat() }        // OBS + RTSP + SRT (NDI no-op)
            requestKeyframeForProgram(force: true)
        } else {
            requestKeyframeForProgram()   // routine re-route (mode toggle, add/remove): dedup, no re-poke
        }
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
    /// Any LIVE passthrough consumer that needs a clean IDR after a CUT — the OBS relay (connected),
    /// or an RTSP/SRT output that's serving.  RTSP/SRT are gated on the same awaitFormat() as the OBS
    /// relay now, so they too need the forced keyframe or they freeze/corrupt for a whole GOP on a cut.
    private func hasLivePassthroughConsumer() -> Bool {
        programOutputs.contains { out in
            if let relay = out as? AirliveRelayOutput { return relay.isConnected }   // real TCP peer
            if let rtsp = out as? RTSPOutput { return rtsp.hasPlayingClient }         // a client is PLAYING
            if let srt = out as? SRTOutput { return srt.isLive }                      // caller-mode: connected peer
            return false   // NDI decodes frames, needs no IDR request
        }
    }

    private func requestKeyframeForProgram(force: Bool = false) {
        guard hasLivePassthroughConsumer() else { return }
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
            // Re-check at fire time: the program may have moved again and every passthrough consumer
            // may have dropped — never poke the phone for nothing.
            guard self.hasLivePassthroughConsumer() else { return }
            self.channels.first { $0.id == self.effectiveProgramID }?.send(.forceKeyframe())
        }
        keyframeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + keyframeDebounceSeconds, execute: work)
    }

    private func feedProgram(_ buffer: CVPixelBuffer, timeNs: UInt64) {
        for output in programOutputs where output.isLive {
            output.send(buffer, timeNs: timeNs)   // buffer outputs (NDI)
        }
        // TRANSCODE mode (AirPlay mirror / HDMI capture on air — no raw bitstream): the same
        // decoded frame is hardware-encoded so OBS/RTSP/SRT carry the program too.  LAW: the
        // program streams to every output, no exceptions.
        if programFeedMode == .transcode {
            programEncoder.encode(buffer, timeNs: timeNs)
        }
    }
    /// Latest program SPS/PPS payload — handed to a passthrough output the moment it starts, so a
    /// mid-stream toggle-on can decode.  CRITICAL: the camera sends formatDescription ONCE per
    /// connection (deliberate, thermal) and its LAN GOP is 6–10 s — an output that missed the one
    /// format packet would mux slices with NO SPS/PPS forever (found live: SRT "non-existing PPS").
    private var lastProgramFormatPayload: Data?
    private func feedProgramFormat(_ payload: Data) {
        lastProgramFormatPayload = payload
        // ALL outputs, live or not: relayFormat only caches parameter sets (cheap) — samples
        // stay isLive-gated in feedProgramSample.  An OFF output must still track the current
        // format so flipping it on later starts from valid decode state.
        for output in programOutputs { output.relayFormat(payload) }
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

    init() {
        seedDefaultOutputs()
        routeProgram()   // the program bus runs from launch — empty program = continuous black
        if !restoreLastSession() {   // a previous session replaces the seeded defaults
            seedFirstLaunchChannels()
        }
        wireAutosave()
    }

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
        let before = channels.map(\.id)
        channels.move(fromOffsets: source, toOffset: destination)
        pushChannelOrder()
        let after = channels.map(\.id)
        guard before != after else { return }
        registerUndo(
            undo: { [weak self] in self?.reorderChannels(before) },
            redo: { [weak self] in self?.reorderChannels(after) })
    }

    /// Reorder the program outputs (drag-reorder in the Outputs rail).  Order is
    /// purely cosmetic — it doesn't change which channel is on program — so a plain
    /// @Published move (which re-renders the list) is all that's needed.
    func moveProgramOutput(from source: IndexSet, to destination: Int) {
        let before = programOutputs.map(\.id)
        programOutputs.move(fromOffsets: source, toOffset: destination)
        let after = programOutputs.map(\.id)
        guard before != after else { return }
        registerUndo(
            undo: { [weak self] in self?.reorderOutputs(before) },
            redo: { [weak self] in self?.reorderOutputs(after) })
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
        let channel = BridgeChannel(name: name ?? defaultChannelName(kind: kind),
                                    kind: kind, captureDeviceID: captureDeviceID)
        wireConnectivity(channel)
        channels.append(channel)
        selectedID = channel.id
        if previewID == nil { previewID = channel.id }   // stage the first camera
        channel.start(order: channels.count - 1)   // first advert already carries the right ord
        applyAuth(to: channel)      // gate it with the current global password
        routeProgram()              // wire the program tap (covers the new channel)
        pushChannelOrder()          // advertise positions (this one + any shifted)
        let cfg = channelConfig(of: channel)
        registerUndo(
            undo: { [weak self] in self?.removeChannel(cfg.id) },
            redo: { [weak self] in self?.restoreChannel(cfg) })
        return channel
    }

    /// Stop and remove the channel with `id`, fixing up the selection if the
    /// removed channel was selected (falls back to the previous channel, or nil
    /// when the list becomes empty).
    func removeChannel(_ id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        let cfg = channelConfig(of: channels[index])
        registerUndo(
            undo: { [weak self] in self?.restoreChannel(cfg, at: index) },
            redo: { [weak self] in self?.removeChannel(id) })
        channels[index].stop()
        channels.remove(at: index)
        channelAutosaveSubs.removeValue(forKey: id)   // its autosave sub dies with it
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
        BridgeProfile(mode: mode.rawValue,
                      channels: channels.map(channelConfig(of:)),
                      outputs: programOutputs.map(outputConfig(of:)))
    }

    /// One channel's persisted shape — shared by the profile snapshot and undo records.
    private func channelConfig(of ch: BridgeChannel) -> BridgeProfile.ChannelConfig {
        BridgeProfile.ChannelConfig(
            id: ch.id, name: ch.name, kind: ch.kind.rawValue,
            captureDeviceID: ch.captureDeviceID, delayRaw: ch.delay.rawValue,
            extraDelayMs: ch.extraDelayMs, previewEnabled: ch.previewEnabled)
    }

    /// One output's persisted shape — shared by the profile snapshot and undo records.
    private func outputConfig(of out: VideoOutput) -> BridgeProfile.OutputConfig {
        BridgeProfile.OutputConfig(
            kind: out.kind.rawValue, label: out.label, config: out.config,
            port: (out as? RTSPOutput).map { Int($0.port) })
    }

    /// Replace the ENTIRE setup with a saved profile: tear down the current channels +
    /// outputs, then rebuild from the snapshot.  Channels come back as fresh receiver
    /// slots (no live connection — the iPhone reconnects by the preserved id); outputs
    /// come back OFF (a restored output must not auto-publish).
    func applyProfile(_ profile: BridgeProfile) {
        clearUndoHistory()   // different world — old records reference dead channels
        // Silence the per-didSet tally broadcasts while the buses churn through the rebuild
        // (previewID/programID/mode/selectedID each fire on the way); we sync ONCE at the
        // end with the final state in place.
        suppressTallySync = true

        // 1. Tear down the current setup.
        for channel in channels { channel.stop() }
        channels.forEach { TallyStore.shared.clear($0.id) }
        channels = []
        channelAutosaveSubs.removeAll()
        for output in programOutputs { output.stop() }
        programOutputs = []
        previewID = nil; programID = nil; selectedID = nil

        // 2. Mode — ALWAYS multiview (Solo is removed from the UI; a profile saved by an
        //    older build may still say "solo", which would strand the app in a view that
        //    no longer exists).
        mode = .multiview

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
            // Only ONE OBS relay is possible (a single loopback slot 127.0.0.1:47788) —
            // a hand-edited / older-build profile with two .obs entries would restore as
            // two relays both hammering that slot.  Skip the duplicate (same guard
            // restoreOutput uses); the post-loop block guarantees exactly one exists.
            if cfg.kind == OutputKind.obs.rawValue,
               programOutputs.contains(where: { $0.kind == .obs }) { continue }
            guard let output = makeOutput(from: cfg) else {
                // No silent shrinkage: a profile from a newer build (or with .vcam)
                // must SAY that a card didn't come back, not just be missing it.
                print("[Bridge] ⚠️ profile output kind '\(cfg.kind)' isn't available in this build — skipped")
                continue
            }
            configureOutput(output)
            programOutputs.append(output)
        }
        // The always-on OBS Plugin card must exist even when restoring a profile saved
        // before it did (configureOutput starts its reconnect loop).
        if !programOutputs.contains(where: { $0.kind == .obs }) {
            let relay = AirliveRelayOutput(label: OutputKind.obs.displayName)
            configureOutput(relay)
            programOutputs.insert(relay, at: 0)   // pinned at the TOP, same as seedDefaultOutputs
        }

        routeProgram()       // wire the program tap across the new channels
        pushChannelOrder()   // advertise positions

        // Now that the full setup is in place, broadcast tally once (matches take()'s
        // single-sync discipline).
        suppressTallySync = false
        if mode == .multiview { syncMultiviewTally() }
    }

    /// Reset to a first-launch setup: no channels, the full default output surface, OFF.
    /// (Menu "New Profile" — the caller confirms first when a show is built.)
    func newProfile() {
        clearUndoHistory()   // different world — old records reference dead channels
        suppressTallySync = true
        for channel in channels { channel.stop() }
        channels.forEach { TallyStore.shared.clear($0.id) }
        channels = []
        channelAutosaveSubs.removeAll()
        for output in programOutputs { output.stop() }
        programOutputs = []
        previewID = nil; programID = nil; selectedID = nil
        seedDefaultOutputs()
        routeProgram()
        suppressTallySync = false
        profileName = "Default"
        profileURL = nil
    }

    // MARK: - Undo / Redo (⌘Z / ⇧⌘Z — config actions only)
    //
    // Covers what an operator can fat-finger: add / remove / reorder / rename of
    // channels and outputs.  LIVE switching (CUT, tally, output on/off) is
    // deliberately NOT undoable — "undo" mid-show must never change what's on air.

    private struct ConfigAction {
        let undoAction: () -> Void
        let redoAction: () -> Void
    }
    @Published private var undoStack: [ConfigAction] = []
    @Published private var redoStack: [ConfigAction] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// True while undo()/redo() replays an action — the replayed mutations must not
    /// register themselves as fresh undo records.
    private var isReplayingUndo = false
    private static let undoDepth = 50

    private func registerUndo(undo: @escaping () -> Void, redo: @escaping () -> Void) {
        guard !isReplayingUndo else { return }
        undoStack.append(ConfigAction(undoAction: undo, redoAction: redo))
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
        redoStack.removeAll()   // a fresh action forks history — the redo branch dies
    }

    func undo() {
        guard let action = undoStack.popLast() else { return }
        isReplayingUndo = true; action.undoAction(); isReplayingUndo = false
        redoStack.append(action)
    }

    func redo() {
        guard let action = redoStack.popLast() else { return }
        isReplayingUndo = true; action.redoAction(); isReplayingUndo = false
        undoStack.append(action)
    }

    /// History is per-setup: a loaded/new profile is a different world — undoing
    /// across the boundary would replay actions against channels that no longer exist.
    private func clearUndoHistory() {
        undoStack.removeAll(); redoStack.removeAll()
    }

    /// Rename with undo (the rail's name field commits through here).
    func renameChannel(_ id: UUID, to newName: String) {
        guard let channel = channels.first(where: { $0.id == id }),
              channel.name != newName else { return }
        let old = channel.name
        registerUndo(
            undo: { [weak self] in self?.channels.first { $0.id == id }?.rename(old) },
            redo: { [weak self] in self?.channels.first { $0.id == id }?.rename(newName) })
        channel.rename(newName)
    }

    /// Output rename with undo.  Nudges `objectWillChange` because `VideoOutput`
    /// isn't observable (same pattern as the card's on/off toggle).
    /// Replay goes through an ID LOOKUP, never the captured instance: a
    /// remove→undo cycle replaces the object, and mutating the old orphan would
    /// silently change nothing on screen.  Lookup miss → honest no-op.
    func renameOutput(_ output: VideoOutput, to newLabel: String) {
        let old = output.label
        // Re-assert the uniqueness `defaultName` guarantees at add-time: two outputs of
        // the SAME kind with the SAME label collide downstream (two NDI senders under one
        // p_ndi_name → receivers see one flapping source).  Suffix a clash to " 2", " 3"…
        let newLabel = uniqueOutputLabel(newLabel, kind: output.kind, excluding: output.id)
        guard old != newLabel else { return }
        let id = output.id
        registerUndo(
            undo: { [weak self] in self?.applyToOutput(id) { $0.label = old } },
            redo: { [weak self] in self?.applyToOutput(id) { $0.label = newLabel } })
        output.label = newLabel
        objectWillChange.send()
    }

    /// Transport-config edit (SRT destination) with undo.  Same id-lookup replay
    /// as `renameOutput`.
    func setOutputConfig(_ output: VideoOutput, to newConfig: String) {
        let old = output.config
        guard old != newConfig else { return }
        let id = output.id
        registerUndo(
            undo: { [weak self] in self?.applyToOutput(id) { $0.config = old } },
            redo: { [weak self] in self?.applyToOutput(id) { $0.config = newConfig } })
        output.config = newConfig
        objectWillChange.send()
    }

    /// Undo-replay helper: mutate the CURRENT instance behind an output id.
    private func applyToOutput(_ id: UUID, _ mutate: (VideoOutput) -> Void) {
        guard let out = programOutputs.first(where: { $0.id == id }) else { return }
        mutate(out)
        objectWillChange.send()
    }

    /// A label unique among outputs of the same kind (NDI/SRT/… source names must not
    /// collide).  Returns `base` if free, else "base 2", "base 3"…  `excluding` skips
    /// the output being renamed so re-committing its own name is a no-op.
    private func uniqueOutputLabel(_ base: String, kind: OutputKind, excluding id: UUID) -> String {
        let taken = Set(programOutputs.filter { $0.kind == kind && $0.id != id }.map(\.label))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Rebuild one channel from its config (undo of a remove / redo of an add).
    /// Same recipe as `applyProfile`'s loop; the preserved id means a previously
    /// paired phone reconnects to the restored slot.
    @discardableResult
    private func restoreChannel(_ cfg: BridgeProfile.ChannelConfig, at index: Int? = nil) -> BridgeChannel {
        // A same-named channel may have taken the slot since the remove (names are
        // what the PHONE lists) — two identical entries in the Airlive receiver
        // list would be indistinguishable, so suffix the restored one.
        var name = cfg.name
        if channels.contains(where: { $0.name == name }) { name += " (restored)" }
        let channel = BridgeChannel(
            id: cfg.id, name: name,
            kind: ChannelKind(rawValue: cfg.kind) ?? .airlive,
            captureDeviceID: cfg.captureDeviceID,
            delay: LatencyPreset(rawValue: cfg.delayRaw) ?? .normal)
        channel.extraDelayMs = cfg.extraDelayMs
        channel.previewEnabled = cfg.previewEnabled
        wireConnectivity(channel)
        let at = min(index ?? channels.count, channels.count)
        channels.insert(channel, at: at)
        channel.start(order: at)
        applyAuth(to: channel)
        if previewID == nil { previewID = channel.id }
        routeProgram()
        pushChannelOrder()
        return channel
    }

    /// Rebuild one output from its config, OFF (undo of a remove / redo of an add).
    /// Returns nil for an OBS relay when one already exists — only one loopback slot.
    @discardableResult
    private func restoreOutput(_ cfg: BridgeProfile.OutputConfig, at index: Int? = nil) -> VideoOutput? {
        if cfg.kind == OutputKind.obs.rawValue,
           programOutputs.contains(where: { $0.kind == .obs }) { return nil }
        guard let output = makeOutput(from: cfg) else { return nil }
        configureOutput(output)
        programOutputs.insert(output, at: min(index ?? programOutputs.count, programOutputs.count))
        routeProgram()
        return output
    }

    /// Restore a saved channel order (undo/redo of a ▲/▼ move).
    private func reorderChannels(_ order: [UUID]) {
        channels.sort {
            (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0)
        }
        pushChannelOrder()
    }

    /// Restore a saved output order (undo/redo of a ▲/▼ move).
    private func reorderOutputs(_ order: [UUID]) {
        programOutputs.sort {
            (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0)
        }
    }

    // MARK: - Session autosave (everything as you left it, crash-safe)
    //
    // The whole layout (channels + names + order + delays + outputs) persists WITHOUT the
    // operator ever touching the Profiles menu: a debounced snapshot goes to Application
    // Support on every config change, and the next launch restores it via `applyProfile`
    // — which by design brings channels back as fresh receiver slots (phones reconnect)
    // and outputs back OFF (nothing auto-publishes after a reboot).  Named profiles stay
    // a separate, explicit act; this is just "the app remembers the room".

    /// `~/Library/Application Support/Airlive Bridge/LastSession.airliveprofile`.
    private static var autosaveURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Airlive Bridge", isDirectory: true)
            .appendingPathComponent("LastSession.\(BridgeProfileDocument.fileExtension)")
    }

    private var autosaveCancellables = Set<AnyCancellable>()
    /// Per-channel autosave subscriptions — removed with their channel (see wireConnectivity).
    private var channelAutosaveSubs: [UUID: AnyCancellable] = [:]
    private var autosaveWork: DispatchWorkItem?
    private var lastAutosavedData: Data?

    /// Model-level changes (add/remove/reorder channel or output, rename, selection…)
    /// all pass through `objectWillChange`; per-channel changes are wired in
    /// `wireConnectivity`.  2 s debounce + snapshot diff keeps this thermally free.
    private func wireAutosave() {
        objectWillChange
            .sink { [weak self] _ in self?.scheduleAutosave() }
            .store(in: &autosaveCancellables)
    }

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autosaveNow() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Write the current snapshot if it differs from the last write (main thread).
    /// Also called directly from `applicationWillTerminate` so a quit right after a
    /// change never loses it.
    func autosaveNow() {
        var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }
        guard let data = try? encoder.encode(snapshotProfile()), data != lastAutosavedData else { return }
        do {
            let url = Self.autosaveURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            lastAutosavedData = data
        } catch {
            print("[Bridge] ⚠️ session autosave failed: \(error.localizedDescription)")
        }
    }

    /// Launch-time restore of the autosaved session.  Returns false ONLY on a true
    /// first launch (no session file) — the caller then seeds the starter channels.
    /// A corrupt file still counts as "not first launch": the operator HAD a setup,
    /// so don't paper over its loss with fresh demo channels.
    @discardableResult
    private func restoreLastSession() -> Bool {
        let isFirstLaunch = !FileManager.default.fileExists(atPath: Self.autosaveURL.path)
        if !isFirstLaunch {
            do {
                let profile = try BridgeProfile.read(from: Self.autosaveURL)
                applyProfile(profile)
                if profile.channels.isEmpty {
                    // Valid file, zero channels: either the operator really cleared
                    // everything, or an autosave raced a wipe before a crash.  Say so —
                    // a silently empty Bridge reads as data loss.
                    print("[Bridge] restored session has NO channels — if that's unexpected, check Profiles ▸ Open")
                }
            }
            catch {
                print("[Bridge] ⚠️ couldn't restore the last session: \(error.localizedDescription)")
            }
        }
        profileName = UserDefaults.standard.string(forKey: "bridge.profileName") ?? "Default"
        if let path = UserDefaults.standard.string(forKey: "bridge.profileURL"),
           FileManager.default.fileExists(atPath: path) {
            profileURL = URL(fileURLWithPath: path)
        }
        return !isFirstLaunch
    }

    /// First launch: open with the three source kinds already created, so a new
    /// operator sees a working room instead of an empty rail (the no-onboarding
    /// decision — the UI explains itself, the starter channels show the options).
    private func seedFirstLaunchChannels() {
        addChannel()                                    // Cam 1 — Airlive Camera
        addChannel(kind: .airplay)                      // Cam 2 — Screen Mirroring
        addChannel(kind: .screenMirroringPlusControl)   // Cam 3 (Control)
        selectedID = channels.first?.id
        previewID = channels.first?.id
        clearUndoHistory()   // the seed isn't an operator action — ⌘Z must not strip the defaults
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
        case .hdmi: output = HDMIOutput(label: cfg.label)
        case .srt:  output = SRTOutput(label: cfg.label)
        case .vcam: output = nil                       // not implemented
        }
        output?.config = cfg.config
        return output
    }

    // MARK: - Private

    /// "Cam N" using the lowest free index, so removing Cam 2 and re-adding reuses
    /// "Cam 2" rather than ever-increasing numbers.  The combined kind gets a
    /// "(Control)" suffix — this name is what the PHONE operator sees in the Airlive
    /// app's receiver list, and on a combined channel that Airlive link is
    /// control-only (video rides AirPlay), so the name must say so up front.
    /// The base number is unique ACROSS suffixes (no "Cam 3" + "Cam 3 (Control)").
    private func defaultChannelName(kind: ChannelKind) -> String {
        let used = Set(channels.map(\.name))
        let suffix = kind == .screenMirroringPlusControl ? " (Control)" : ""
        var n = 1
        while used.contains("Cam \(n)") || used.contains("Cam \(n) (Control)") { n += 1 }
        return "Cam \(n)\(suffix)"
    }
}

/// Mutable box so an undo record can keep pointing at the CURRENT instance across
/// remove→restore cycles (a restored output is a fresh object with a fresh id).
private final class Ref<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
