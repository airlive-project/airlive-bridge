// CameraControlPanel.swift — remote camera control for the selected channel.
//
// The Blackmagic-style control surface, top to bottom (each block is its OWN
// tidy card so the eye groups them without hunting for dividers):
//
//   • LENS      — card-style quick-select tiles (0.5× / 1× / …).
//   • EXPOSURE  — ISO-compensation pill, then an AE pill that greys ISO +
//                 Shutter sliders while auto is on.
//   • WHITE BAL — an AWB pill that greys WB(K) + Tint while auto is on.
//   • FOCUS     — an AF pill that greys the Focus slider while auto is on.
//   • FRAMING   — Zoom slider + Preview-LUT pill.
//
// Every knob sends a `ControlMessage` to the iPhone via `channel.send(_:)`;
// every value LABEL reads back from `channel.remote` (the camera's reported
// StateSnapshot).
//
// Local @State vs readback
// ------------------------
// A slider needs local state to drag smoothly (binding straight to `remote`
// would fight the next snapshot and stutter).  So each control holds a local
// `@State`, seeded from `remote` on appear and re-seeded whenever a NEW snapshot
// arrives (the iPhone's auto-readback / confirmation).  We commit a command on
// editing-END only, so a drag sends ONE packet, not one per pixel — the
// cheap-control-packet rule.  When no snapshot has arrived yet, the panel shows
// a "waiting for camera" notice instead of dead controls.

import SwiftUI

struct CameraControlPanel: View {
    @ObservedObject var channel: BridgeChannel

    // Local slider state — seeded from `remote`, committed on drag-end.
    @State private var iso: Double = 400
    @State private var shutterDenom: Double = 50
    @State private var wbKelvin: Double = 5600
    @State private var tint: Double = 0
    @State private var focus: Double = 0.5
    @State private var zoom: Double = 1
    @State private var exposureBias: Double = 0   // EV compensation (works in AUTO — biases the auto target)
    // Stabilization pick — optimistic local (shows instantly; the camera's snapshot confirms).  fps /
    // resolution controls were removed: they only change the phone's LOCAL recording master, never the
    // fixed 1080p/30 monitoring wire, so they did nothing the Bridge operator could see.
    @State private var stabSel: String = ""   // "Standard" / "High" — runtime-safe, allowed mid-take

    // Toggle mirrors (the auto pills grey out their matching sliders).
    @State private var exposureAuto = true
    @State private var whiteBalanceAuto = true
    @State private var focusAuto = true
    @State private var isoCompensation = false
    @State private var lutEnabled = false

    /// Device-read capability ranges for THIS camera (slider bounds adapt to the phone instead
    /// of hardcoded tables).  Falls back to the wire defaults when an old camera sends none.
    private var caps: DeviceCapabilities { channel.remote?.capabilities ?? DeviceCapabilities() }


    /// The value ladders for THIS camera, shared with the Stream Deck dials (see CameraLadders).
    private var ladders: CameraLadders { CameraLadders(channel.remote) }

    // ── Quick-pick presets (standard stops, clamped to the device's reachable range) ──────────────
    // Shown as CHIPS above each tape; a tap jumps the value there.  Same "standard values Bridge
    // defines locally" principle as the ladders — no wire field needed.
    private var isoPresets: [Double] { [100, 400, 800, 1600].filter { $0 >= Double(caps.isoMin) && $0 <= Double(caps.isoMax) } }
    private var shutterPresets: [Double] { [30, 50, 60, 120].filter { $0 >= Double(caps.shutterMinDenom) && $0 <= Double(caps.shutterMaxDenom) } }
    /// White-balance lighting pills — the phone's EXACT `StripPreset.lighting` pairs: each pill is a
    /// TEMPERATURE + the TINT that goes with it (tungsten 3200/0, fluorescent 4000/+15, daylight
    /// 5600/+10, cloud 6500/+10).  Tapping one sets BOTH, 1:1 with the phone.  Fixed BM values — the
    /// phone doesn't vary them per device either.  Tint / Focus / Zoom have no pills of their own.
    private static let wbPresets: [(temp: Double, tint: Double)] = [
        (3200, 0), (4000, 15), (5600, 10), (6500, 10)
    ]
    private var tempPresets: [Double] {
        Self.wbPresets.map { $0.temp }.filter { $0 >= Double(caps.wbTempMin) && $0 <= Double(caps.wbTempMax) }
    }
    /// The tint paired with a temperature pill (phone's lighting pairs); nil if `temp` isn't a preset.
    private func wbTint(forTemp temp: Double) -> Double? {
        Self.wbPresets.first { abs($0.temp - temp) < 1 }?.tint
    }

    /// Camera COMMANDS need a live, permitted control link: they travel to the phone, so without
    /// the link there is nothing to send them to.  This gate covers the commands and nothing else -
    /// the Mac's OWN settings must never be locked away by the phone's state.  That is why the
    /// latency buffer now lives in the channel rail's footer instead of here: an operator whose
    /// phone dropped kept a jitter buffer they could no longer change, a saved setting with no way
    /// back, the same trap the shortcuts switch fell into.
    private var cameraControlAvailable: Bool {
        channel.remoteControlConnected && channel.remoteControlAllowed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionLabel(text: "Camera control")
            if channel.remote == nil {
                waitingNotice
            } else {
                content
                    .disabled(!cameraControlAvailable)
                    .opacity(cameraControlAvailable ? 1.0 : 0.4)
            }
            // The latency buffer USED to sit here, as a segmented bar. It moved to the channel
            // rail's footer (LatencyBufferFooter), behind a lock: it is a set-once transport
            // setting, not a thing an operator adjusts while directing, and a full-width bar in
            // the control panel invited exactly the mid-show mis-click it should never allow.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { seed(from: channel.remote) }
        // Re-seed when a NEW snapshot lands so labels + slider rest positions
        // track the camera's auto-readback / our own confirmed commands.
        .onChange(of: channel.remote) { newValue in
            seed(from: newValue)
        }
    }

    private var waitingNotice: some View {
        Card(padding: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "wifi.slash")
                    .foregroundColor(Theme.textFaint)
                Text("Connect an iPhone to control its camera.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Content (each control is its own card)

    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Titled SECTIONS, one AUTO each, in two columns.  Exposure-auto governs ISO+Shutter, WB-auto
            // governs Temp+Tint, focus-auto governs Focus.  Look has no auto.
            HStack(alignment: .top, spacing: Spacing.md) {
                exposureSection.frame(maxWidth: .infinity, maxHeight: .infinity)
                whiteBalanceSection.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)     // equal-height the pair → aligned bottoms
            HStack(alignment: .top, spacing: Spacing.md) {
                focusSection.frame(maxWidth: .infinity, maxHeight: .infinity)
                lookSection.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            // Stabilization is a row of Look now (operator, 2026-10-30). fps / resolution were removed —
            // they only change the phone's LOCAL recording master, never the fixed 1080p/30 monitoring
            // wire. Output delay is the Bridge-wide latency buffer in the channel rail's footer.
        }
    }

    /// A section body = two parameter rows + their gap.  The Look section pads to this so its card lines
    /// up with the parameter sections beside it.
    private static let sectionBodyHeight: CGFloat = ParamStrip.rowHeight * 2 + Spacing.sm

    // MARK: Sections

    /// EV compensation — a compact draggable value LEFT of the exposure AUTO (operator: "не ползунком,
    /// просто значение").  It biases the auto-exposure target, so it works in AUTO and does NOT drop to
    /// manual on touch (phone's `dragExitsAuto: false`).  0.1-EV steps, phone's `%+.1f` display.
    private var evControl: some View {
        CompactValueDrag(label: "EV", value: $exposureBias,
                         range: Double(min(caps.evBiasMin, caps.evBiasMax))...Double(max(caps.evBiasMin, caps.evBiasMax)),
                         step: 0.1,
                         display: { abs($0) < 0.05 ? "0.0" : String(format: "%+.1f", $0) },
                         accent: exposureAuto && abs(exposureBias) > 0.05,
                         active: exposureAuto) { v in channel.send(.setExposureBias(Float(v))) }
    }

    private var exposureSection: some View {
        ControlSection(title: "Exposure", auto: exposureAuto,
                       onAuto: { on in exposureAuto = on; channel.send(.setExposureAuto(on)) },
                       accessory: AnyView(evControl), fillHeight: true) {
            VStack(spacing: Spacing.sm) {
                ParamStrip(label: "ISO", values: ladders.iso, value: $iso, display: { "\(Int($0))" },
                           auto: exposureAuto, presets: isoPresets, onExitAuto: exitExposureAuto) { v in
                    channel.send(.setISO(Float(v)))
                }
                ParamStrip(label: "Shutter", values: ladders.shutter, value: $shutterDenom, display: { "1/\(Int($0))" },
                           auto: exposureAuto, presets: shutterPresets, onExitAuto: exitExposureAuto) { v in
                    channel.send(.setShutter(Float(v)))
                }
            }
        }
    }

    private var whiteBalanceSection: some View {
        ControlSection(title: "White balance", auto: whiteBalanceAuto,
                       onAuto: { on in whiteBalanceAuto = on; channel.send(.setWhiteBalanceAuto(on)) },
                       fillHeight: true) {
            VStack(spacing: Spacing.sm) {
                ParamStrip(label: "Temperature", values: ladders.temperature, value: $wbKelvin, display: { "\(Int($0))K" },
                           auto: whiteBalanceAuto, presets: tempPresets,
                           onPresetTap: { temp in                       // phone sets BOTH temp + its paired tint
                               guard let t = wbTint(forTemp: temp) else { return }
                               if whiteBalanceAuto { exitWhiteBalanceAuto() }
                               wbKelvin = temp; tint = t
                               channel.send(.setWB(Float(temp)))
                               channel.send(.setTint(Float(t)))
                           },
                           presetActive: { temp in                     // lit only when BOTH match (phone's presetIsActive)
                               guard let t = wbTint(forTemp: temp) else { return false }
                               return abs(wbKelvin - temp) < 50 && abs(tint - t) < 1
                           },
                           onExitAuto: exitWhiteBalanceAuto) { v in channel.send(.setWB(Float(v))) }
                ParamStrip(label: "Tint", values: ladders.tint, value: $tint,
                           display: { let i = Int($0); return i > 0 ? "+\(i)" : "\(i)" },
                           auto: whiteBalanceAuto, onExitAuto: exitWhiteBalanceAuto) { v in
                    channel.send(.setTint(Float(v)))
                }
            }
        }
    }

    private var focusSection: some View {
        ControlSection(title: "Focus", auto: focusAuto,
                       onAuto: { on in focusAuto = on; channel.send(.setFocusAuto(on)) },
                       fillHeight: true) {
            VStack(spacing: Spacing.sm) {
                ParamStrip(label: "Focus", values: ladders.focus, value: $focus, display: { String(format: "%.3f", $0) },
                           auto: focusAuto, onExitAuto: exitFocusAuto) { v in
                    channel.send(.setFocusPosition(Float(v)))
                }
                // "Digital Zoom", not "Zoom": the camera captures from ONE physical lens at a time
                // (ultra-wide, wide and telephoto are separate devices, and changing lens changes
                // device), so this only crops the active sensor - no glass moves. The LENS tiles are
                // the optical choice; naming this one honestly is what tells the two apart. It does
                // not mean "degraded": on the 48 MP main sensor the 2x crop is native, not upscaled.
                ParamStrip(label: "Digital Zoom", values: ladders.zoom, value: $zoom,
                           display: { String(format: "%.1f×", $0) },
                           auto: false) { v in
                    channel.send(.setZoom(Float(v)))
                }
            }
        }
    }

    private var lookSection: some View {
        // ISO compensation is a switch in the header, like AUTO on the other sections, so every row
        // below is a dropdown of one fixed width (operator, 2026-10-30).
        ControlSection(title: "Look", accessory: AnyView(
            HeaderToggleChip(title: "ISO COMP", isOn: isoCompensation) {
                isoCompensation.toggle()
                channel.send(.setIsoCompensation(isoCompensation))
            }
            .help("ISO compensation")
        ), fillHeight: true) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Colour space — SELECTABLE, above the LUT, SAME boxed dropdown.  Data-driven,
                // NOT gated on a "colorSpace" cap (this camera advertises its spaces via `capabilities`,
                // not a separate flag).  Readback-driven: a camera that refuses just re-broadcasts the
                // unchanged value.  No toggle → an equal-width spacer keeps its box aligned with the LUT.
                lookBoxRow(label: "Color space",
                           value: channel.remote?.colorSpace ?? "—", isPlaceholder: false,
                           options: colorSpaceOptions, enabled: !colorSpaceOptions.isEmpty) { v in
                    channel.send(.setColorSpace(v))   // EXACT raws (a wrong spelling silently no-ops)
                }
                lutRow
                // Shown only when the camera supports it (it affects the pictured video).
                if hasStabilization { stabilizationRow }
            }
            .frame(maxWidth: .infinity, minHeight: Self.sectionBodyHeight, alignment: .topLeading)
        }
    }

    /// Standard Apple colour spaces (a fixed enum) — the fallback when the camera doesn't broadcast
    /// its own `capabilities.colorSpaces`.  EXACT raw strings the camera's `ColorSpaceMode` decodes;
    /// "HLG BT.2020" (the old wrong spelling) would silently no-op, so keep "Rec.2020 HLG".
    private var colorSpaceOptions: [String] {
        caps.colorSpaces.isEmpty ? ["Rec.709", "P3 D65", "Rec.2020 HLG", "Apple Log"] : caps.colorSpaces
    }

    /// The narrowest the label column gets — no label may run under its dropdown.  Sized for the longest label ("Stabilization", ≈ 80 pt at 12 pt
    /// medium) plus air.
    private static let lookLabelWidth: CGFloat = 96
    /// One width for every Look dropdown, pinned to the card's right edge under the header chip
    /// (the free space goes between label and box, never after the box).  Fits a typical LUT name (~30 characters) with room to
    /// spare, so the boxes are not sized to whichever item happens to be picked; a longer name
    /// keeps its start and end and loses the middle.  A narrower card shrinks them together.
    private static let lookFieldWidth: CGFloat = 240

    /// Look row = fixed label + our shared `Dropdown` (boxed trigger + styled popover list, NOT the
    /// native NSMenu), at the camera panel's own type size and the app's 28 pt control height.
    private func lookBoxRow(label: String, value: String, isPlaceholder: Bool, options: [String],
                            enabled: Bool, onPick: @escaping (String) -> Void) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textSecondary)
                .frame(minWidth: Self.lookLabelWidth, maxWidth: .infinity, alignment: .leading)
                .opacity(enabled ? 1 : 0.5)         // match the Dropdown's own disabled dim (below)
            Dropdown(items: options,
                     selection: options.contains(value) ? value : nil,
                     displayText: value,
                     isPlaceholder: isPlaceholder,
                     isEnabled: enabled,
                     triggerHeight: ControlMetrics.pillHeight,
                     onSelect: onPick)
                .frame(maxWidth: Self.lookFieldWidth)
        }
    }

    /// The camera's REAL LUT — burns into the operator's preview + the wire + the Rec-to-Clip bake, NOT a
    /// receiver-side "preview LUT".  Hence the label "Camera LUT".  A new camera (cap "lut") lists its
    /// QUICK-ACCESS LUTs (`caps.availableLuts`); a legacy camera just carries its current `lutName`.
    /// CONTRACT: "None" = nothing.  A LUT turns on ONLY by an explicit pick from the list, and off by
    /// picking None - the list is the whole control (the on/off toggle beside it was removed,
    /// operator 2026-10-30: None already says "off").
    private var lutRow: some View {
        let name = channel.remote?.lutName                       // the camera's ACTUAL loaded LUT (nil = None)
        let quickList = channel.hasCap("lut") ? caps.availableLuts : []
        // Keep the camera's current LUT in the option list even if it isn't a quick-LUT, so the field and
        // the checkmark can never desync (the field showed the name while ✓ sat on None).
        var options = ["None"] + quickList
        if let name, !options.contains(name) { options.append(name) }
        let usable = options.count > 1 || name != nil
        let active = lutEnabled && name != nil                   // "on" only when a LUT is really selected
        let shown = active ? (name ?? "None") : "None"           // SINGLE source → drives display AND ✓
        return lookBoxRow(label: "Camera LUT", value: shown, isPlaceholder: shown == "None",
                          options: options, enabled: usable) { picked in
            if picked == "None" {
                lutEnabled = false; channel.send(.setLUT(name: "", enabled: false))
            } else {
                lutEnabled = true; channel.send(.setLUT(name: picked, enabled: true))
            }
        }
    }

    // MARK: Stabilization — the one capture control the wire honours (shown only if the camera has it)

    /// True when this phone advertises a stabilization capability with modes to pick.
    private var hasStabilization: Bool { channel.hasCap("stabilization") && !caps.stabilizations.isEmpty }

    /// Video stabilization mode, as a Look row.  Unlike fps/resolution (local-recording only,
    /// removed), this is a runtime connection-property change the camera applies mid-take, and it
    /// DOES affect the stabilized picture the wire carries.  EXACT raws from `caps.stabilizations`.
    private var stabilizationRow: some View {
        let cur = stabSel.isEmpty ? (channel.remote?.stabilization ?? "—") : stabSel
        return lookBoxRow(label: "Stabilization", value: cur, isPlaceholder: cur == "—",
                          options: caps.stabilizations, enabled: true) { v in
            stabSel = v
            channel.send(.setStabilization(v))     // EXACT raws from caps
        }
    }

    // MARK: Output delay (jitter-buffer latency) — per channel, in BOTH modes

    // Delivery mode (Video+Control / Control-only) lived here — REMOVED: standalone control-only
    // is a duplicate of the dedicated "Screen Mirroring + Remote Control" channel type (which
    // pairs AirPlay video + ARLV control), so it only confused the panel.  Use that channel for
    // the video-via-AirPlay + control case.

    /// Touching a manual value while AUTO is on drops the camera into manual (mirrors the camera
    /// app: grab a dial → leave auto).  Locally flips the toggle so the amber readback turns white
    /// immediately; the camera re-confirms in its next snapshot.
    private func exitExposureAuto() {
        guard exposureAuto else { return }
        exposureAuto = false
        channel.send(.setExposureAuto(false))
    }
    private func exitWhiteBalanceAuto() {
        guard whiteBalanceAuto else { return }
        whiteBalanceAuto = false
        channel.send(.setWhiteBalanceAuto(false))
    }
    private func exitFocusAuto() {
        guard focusAuto else { return }
        focusAuto = false
        channel.send(.setFocusAuto(false))
    }

    // MARK: - Seeding from readback

    /// Copy the camera's reported values into our local slider state.
    ///
    /// Called on appear and on every new snapshot — the iPhone re-broadcasts
    /// state after each confirmed change and at ~1 Hz auto-readback, so this
    /// keeps the labels / slider rest positions honest without us polling.  A
    /// drag is reported on editing-END only, so an in-flight drag isn't
    /// clobbered mid-gesture by a stale snapshot.
    private func seed(from snapshot: StateSnapshot?) {
        guard let s = snapshot else { return }
        iso = Double(s.iso)
        shutterDenom = Double(s.shutterDenom)
        wbKelvin = Double(s.wbKelvin)
        tint = Double(s.tint)
        focus = Double(s.focusPosition)
        zoom = Double(s.zoom)
        exposureBias = Double(s.exposureBias)
        stabSel = s.stabilization
        exposureAuto = s.exposureAuto
        whiteBalanceAuto = s.whiteBalanceAuto
        focusAuto = s.focusAuto
        isoCompensation = s.isoCompensation
        lutEnabled = s.lutEnabled
    }
}

// MARK: - Camera control SECTION

/// The camera-control block for ONE tile.  Shows the control panel when the channel owns a
/// back-channel — an Airlive camera, or a combined "Screen Mirroring + Remote Control" channel
/// (whose ARLV control side drives it) — otherwise a hint (plain Screen Mirroring / capture have
/// no remote control).
struct CameraControlSection: View {
    @ObservedObject var channel: BridgeChannel

    var body: some View {
        if channel.kind == .screenMirroringPlusControl {
            // Combined channel: its TWO transports connect separately, so show the
            // two-step how-to until BOTH are up, with the control panel below.
            VStack(alignment: .leading, spacing: Spacing.md) {
                if !(channel.isConnected && channel.controlConnected) { combinedConnectHint }
                ControlPanel(c: channel)     // owns a back-channel (ARLV)
            }
        } else if channel.kind == .airlive {
            ControlPanel(c: channel)         // owns a back-channel (ARLV)
        } else if !channel.isConnected {
            connectHint                                           // not connected yet → HOW to connect
        }
        // Connected Screen Mirroring / capture: nothing to control, nothing to say.
    }

    /// Connect steps for the combined channel.  Video is the NATIVE AirPlay mirror —
    /// the phone runs no second encode, the thermally-coolest way to get its picture
    /// here — and the Airlive Camera app connects control-only on top of it.  Each
    /// step shows its own state, so the operator sees which half is still missing.
    private var combinedConnectHint: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel(text: "Connect")
            stepLine(done: channel.isConnected,
                     text: "Video: iPhone → Control Center → Screen Mirroring → “\(channel.name)”.")
            stepLine(done: channel.controlConnected,
                     text: "Control: Airlive Camera → Live → “\(channel.name)”.")
            Text("Video rides the native AirPlay mirror - no second encode, the phone stays cool. The Airlive link carries control only.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One connect step with its live state: green check = this transport is up.
    private func stepLine(done: Bool, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundColor(done ? Theme.previewGreen : Theme.textFaint)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A short HOW-TO for the kinds without remote control — useful (the connect steps)
    /// instead of a complaint, and only while nothing is connected.  Quiet hint styling.
    private var connectHint: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel(text: "Connect")
            Text(channel.kind == .capture
                 ? "Plug the HDMI / USB capture device in - the picture appears automatically."
                 : "iPhone → Control Center → Screen Mirroring → “\(channel.name)”.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The control panel for ONE back-channel-owning channel, with the connected / operator-revoked
/// gating.  A STRUCT (not a method) so its `@ObservedObject` subscribes to `c` — the
/// `disabled`/`opacity` gating then reacts to THAT channel's `isConnected` /
/// `remoteControlAllowed`, even when `c` is a bound Remote-Control channel different from the
/// tile being shown (the parent only observes the video tile, not its control channel).
private struct ControlPanel: View {
    @ObservedObject var c: BridgeChannel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // The gate lives INSIDE the panel, on the camera commands themselves.  Disabling from
            // out here could only ever disable everything at once, which is how the operator used
            // to lose the settings that are this Mac's own and were never the phone's to gate.
            CameraControlPanel(channel: c)
                .id(c.id)   // reset the panel's local @State when the controlled channel changes
            if c.remoteControlConnected && !c.remoteControlAllowed { remoteControlDisabledNote }
        }
    }

    private var remoteControlDisabledNote: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "hand.raised.slash").font(.system(size: 12)).foregroundColor(Theme.textFaint)
            Text("Operator turned remote control off on the phone.")
                .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
        }
    }
}
