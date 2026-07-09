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


    // ── Real camera ladders ──────────────────────────────────────────────────────────────────────
    // Bridge mirrors the phone's OWN ISO / shutter ladders (AirliveCameraApp/VerticalParamPanel) so
    // the operator only ever lands on a value the sensor actually offers — no invented `1/268`.  These
    // are standard cinema stops filtered by the capability ranges the camera ALREADY sends, so they
    // reproduce the phone's picker with NO new wire field.
    private static let isoCinema: [Double] = [
        32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320,
        400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400
    ]
    /// ISO 1/3-stop stops within [isoMin, isoMax], KEEPING the true endpoints so a max that falls
    /// between cinema stops stays reachable (matches ISOPanel.stops).
    private var isoLadder: [Double] {
        let lo = Double(caps.isoMin).rounded(), hi = Double(caps.isoMax).rounded()
        guard hi > lo + 0.5 else { return [lo] }
        var s = Self.isoCinema.filter { $0 > lo + 0.5 && $0 < hi - 0.5 }
        s.insert(lo, at: 0); s.append(hi)
        return s
    }

    private static let shutterCinema: [Double] = [
        24, 25, 30, 48, 50, 60, 100, 120, 180, 250, 500, 1000, 2000, 3000, 4000, 6000, 8000
    ]
    /// Shutter denominators = cinema stops ∪ fps-relative quick picks (1/fps, 1/2fps, 1/4fps, 1/50),
    /// clamped to [max(minDenom, fps), maxDenom] — the slowest shutter can't exceed one frame, so the
    /// floor is the current fps (matches ShutterPanel.stops; kills the invented `1/268`).
    private var shutterLadder: [Double] {
        let fps = Double(channel.remote?.fps ?? 30)
        let lo = max(Double(caps.shutterMinDenom), fps)
        let hi = Double(caps.shutterMaxDenom)
        guard hi > lo else { return [lo] }
        let quick: [Double] = [fps, 50, fps * 2, fps * 4]
        let all = Set(Self.shutterCinema + quick).filter { $0 >= lo - 0.5 && $0 <= hi + 0.5 }
        return all.isEmpty ? [lo] : all.sorted()
    }

    /// WB temperature — 100 K stops across the device envelope (matches WBPanel.stops).
    private var tempLadder: [Double] {
        let lo = Double(caps.wbTempMin), hi = Double(caps.wbTempMax)
        guard hi > lo else { return [lo] }
        return Array(stride(from: lo, through: hi, by: 100))
    }
    /// Tint — ±1 stops across the device envelope (matches TintPanel.stops).
    private var tintLadder: [Double] {
        let lo = Double(caps.wbTintMin), hi = Double(caps.wbTintMax)
        guard hi > lo else { return [lo] }
        return Array(stride(from: lo, through: hi, by: 1))
    }
    /// Focus — 0.000…1.000 in 0.01 steps (101 stops, matches FocusPanel.stops).
    private static let focusLadder: [Double] = Array(stride(from: 0.0, through: 1.0, by: 0.01))
    /// Zoom — up to THIS device's real max (`caps.zoomMax` = `videoMaxZoomFactor`); 0 from an older
    /// camera → the 1–10 fallback.  0.1× steps to 10×, 0.5× above (zoom is CONTINUOUS on the phone —
    /// any value is valid; the coarser high-end step just keeps a 100×+ ladder scrubbable).
    private var zoomLadder: [Double] {
        let maxZ = caps.zoomMax > 1 ? Double(caps.zoomMax) : 10.0
        var out = Array(stride(from: 1.0, through: Swift.min(maxZ, 10.0), by: 0.1))
        if maxZ > 10 { out += Array(stride(from: 10.5, through: maxZ, by: 0.5)) }
        return out
    }

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

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionLabel(text: "Camera control")
            if channel.remote == nil {
                waitingNotice
            } else {
                content
            }
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
                exposureSection.frame(maxWidth: .infinity)
                whiteBalanceSection.frame(maxWidth: .infinity)
            }
            HStack(alignment: .top, spacing: Spacing.md) {
                focusSection.frame(maxWidth: .infinity)
                lookSection.frame(maxWidth: .infinity)
            }
            HStack(alignment: .top, spacing: Spacing.md) {
                // Stabilization shows only when the camera supports it (it affects the pictured video);
                // otherwise Output delay takes the whole row.  fps / resolution were removed — they only
                // change the phone's LOCAL recording master, never the fixed 1080p/30 monitoring wire.
                if hasStabilization { stabilizationSection.frame(maxWidth: .infinity) }
                delaySection.frame(maxWidth: .infinity)
            }
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
                       accessory: AnyView(evControl)) {
            VStack(spacing: Spacing.sm) {
                ParamStrip(label: "ISO", values: isoLadder, value: $iso, display: { "\(Int($0))" },
                           auto: exposureAuto, presets: isoPresets, onExitAuto: exitExposureAuto) { v in
                    channel.send(.setISO(Float(v)))
                }
                ParamStrip(label: "Shutter", values: shutterLadder, value: $shutterDenom, display: { "1/\(Int($0))" },
                           auto: exposureAuto, presets: shutterPresets, onExitAuto: exitExposureAuto) { v in
                    channel.send(.setShutter(Float(v)))
                }
            }
        }
    }

    private var whiteBalanceSection: some View {
        ControlSection(title: "White balance", auto: whiteBalanceAuto,
                       onAuto: { on in whiteBalanceAuto = on; channel.send(.setWhiteBalanceAuto(on)) }) {
            VStack(spacing: Spacing.sm) {
                ParamStrip(label: "Temperature", values: tempLadder, value: $wbKelvin, display: { "\(Int($0))K" },
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
                ParamStrip(label: "Tint", values: tintLadder, value: $tint,
                           display: { let i = Int($0); return i > 0 ? "+\(i)" : "\(i)" },
                           auto: whiteBalanceAuto, onExitAuto: exitWhiteBalanceAuto) { v in
                    channel.send(.setTint(Float(v)))
                }
            }
        }
    }

    private var focusSection: some View {
        ControlSection(title: "Focus", auto: focusAuto,
                       onAuto: { on in focusAuto = on; channel.send(.setFocusAuto(on)) }) {
            VStack(spacing: Spacing.sm) {
                ParamStrip(label: "Focus", values: Self.focusLadder, value: $focus, display: { String(format: "%.3f", $0) },
                           auto: focusAuto, onExitAuto: exitFocusAuto) { v in
                    channel.send(.setFocusPosition(Float(v)))
                }
                ParamStrip(label: "Zoom", values: zoomLadder, value: $zoom, display: { String(format: "%.1f×", $0) },
                           auto: false) { v in
                    channel.send(.setZoom(Float(v)))
                }
            }
        }
    }

    private var lookSection: some View {
        ControlSection(title: "Look") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // ISO compensation — label left, on/off toggle far right (aligns with the LUT toggle).
                lookToggleRow("ISO compensation", isOn: isoCompensation) {
                    isoCompensation.toggle()
                    channel.send(.setIsoCompensation(isoCompensation))
                }
                // Colour space — SELECTABLE, above the LUT, SAME full-width boxed dropdown.  Data-driven,
                // NOT gated on a "colorSpace" cap (this camera advertises its spaces via `capabilities`,
                // not a separate flag).  Readback-driven: a camera that refuses just re-broadcasts the
                // unchanged value.  No toggle → an equal-width spacer keeps its box aligned with the LUT.
                lookBoxRow(label: "Colour space",
                           value: channel.remote?.colorSpace ?? "—", isPlaceholder: false,
                           options: colorSpaceOptions, enabled: !colorSpaceOptions.isEmpty, toggle: nil) { v in
                    channel.send(.setColorSpace(v))   // EXACT raws (a wrong spelling silently no-ops)
                }
                lutRow
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

    private static let lookLabelWidth: CGFloat = 92
    private static let lookRowHeight: CGFloat = 34

    /// Look row: label left, on/off toggle far right (ISO compensation).  Toggle aligns with the LUT's.
    private func lookToggleRow(_ title: String, isOn: Bool, onToggle: @escaping () -> Void) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.textPrimary)
            Spacer(minLength: Spacing.sm)
            PowerToggle(state: isOn ? .on : .off, action: onToggle)
        }
        .frame(height: Self.lookRowHeight)
    }

    /// Look row = fixed label + a FULL-WIDTH boxed dropdown (value left-aligned, chevron right) + a
    /// trailing on/off toggle (or an equal-width spacer so every box lines up).  This is the reference
    /// card style: the box spans the block, so different names never shift the control's position.
    private func lookBoxRow(label: String, value: String, isPlaceholder: Bool, options: [String],
                            enabled: Bool, toggle: AnyView?, onPick: @escaping (String) -> Void) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.textPrimary)
                .frame(width: Self.lookLabelWidth, alignment: .leading)
            // Menu whose LABEL *is* the full box.  `.buttonStyle(.plain)` (NOT `.borderlessButton`) is
            // what BOTH stretches the label to full width AND keeps it clickable — verified by rendering
            // the layout.  borderlessButton content-sized the label (collapsed / uneven boxes); an
            // invisible overlay-Menu rendered the box but never received the click.
            Menu {
                ForEach(options, id: \.self) { o in Button(o) { onPick(o) } }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Text(value)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isPlaceholder ? Theme.textFaint : Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, Spacing.sm)
                .frame(maxWidth: .infinity)
                .frame(height: Self.lookRowHeight)
                .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Theme.bgSelected))
                .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).stroke(Theme.strokeDivider, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(!enabled)
            // Toggle slot (= PowerToggle width): the LUT's on/off, or an empty spacer for Colour space,
            // so both boxes end at the same x.
            ZStack { if let toggle { toggle } }.frame(width: ControlMetrics.chipWidth)
        }
        .opacity(enabled ? 1 : 0.5)
    }

    /// Preview-LUT: a full-width boxed dropdown (matching Colour space) + on/off toggle.  A new camera
    /// (cap "lut") lists its QUICK-ACCESS LUTs (`caps.availableLuts`, re-broadcast on change); a legacy
    /// camera falls back to the current `lutName`.  "None" = LUT off, mirrored by the toggle.
    private var lutRow: some View {
        let name = channel.remote?.lutName
        let quickList = channel.hasCap("lut") ? caps.availableLuts : []
        let base = quickList.isEmpty ? (name.map { [$0] } ?? []) : quickList
        let usable = !base.isEmpty || name != nil
        let shown = lutEnabled ? (name ?? "None") : "None"
        let toggle = AnyView(
            PowerToggle(state: lutEnabled ? .on : .off) {
                guard usable else { return }
                lutEnabled.toggle()
                let target = lutEnabled ? (name ?? base.first ?? "") : ""
                channel.send(.setLUT(name: target, enabled: lutEnabled))
            }
            .disabled(!usable)
        )
        return lookBoxRow(label: "LUT", value: shown, isPlaceholder: shown == "None",
                          options: ["None"] + base, enabled: usable, toggle: toggle) { picked in
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

    /// Video stabilization mode.  Unlike fps/resolution (local-recording only, removed), this is a
    /// runtime connection-property change the camera applies mid-take, and it DOES affect the
    /// stabilized picture the wire carries.  EXACT raws "Standard"/"High" from `caps.stabilizations`.
    private var stabilizationSection: some View {
        ControlSection(title: "Stabilization") {
            HStack(spacing: Spacing.sm) {
                formatMenu(title: "Mode",
                           value: stabSel.isEmpty ? (channel.remote?.stabilization ?? "—") : stabSel,
                           options: caps.stabilizations, display: { $0 }) { v in
                    stabSel = v
                    channel.send(.setStabilization(v))
                }
                .help("Video stabilization — Standard / High (safe mid-take)")
                Spacer()
            }
        }
    }

    /// One format dropdown chip — same look as the LUT dropdown (chip + chevron, menu on click).
    /// Generic over the option type (Double fps, String resolution) so the chip style lives ONCE.
    private func formatMenu<T: Hashable>(title: String, value: String, options: [T],
                                         display: @escaping (T) -> String,
                                         onPick: @escaping (T) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.self) { o in
                Button(display(o)) { onPick(o) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.textFaint)
                Text(value).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundColor(Theme.textSecondary)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundColor(Theme.textFaint)
            }
            .padding(.horizontal, 9).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bgHover))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.strokeDivider, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Output delay (jitter-buffer latency) — per channel, in BOTH modes

    /// This channel's playout latency (jitter buffer).  A receiver-side Bridge setting, so
    /// it lives with camera control and shows in Solo AND Multiview.  (A precise ms field is
    /// roadmapped alongside these presets — see ROADMAP.md.)
    private var delaySection: some View {
        ControlSection(title: "Output delay (ms)") {
            SegmentedBar(
                selection: Binding(
                    get: { channel.delay },
                    set: { channel.delay = $0 }
                ),
                options: LatencyPreset.allCases,
                label: { delayShortLabel($0) }
            )
        }
    }

    private func delayShortLabel(_ preset: LatencyPreset) -> String {
        switch preset {
        case .lowest: return "Lowest +0"
        case .normal: return "Normal +120"
        case .smooth: return "Smooth +200"
        case .safe:   return "Safe +400"
        }
    }

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
            Text("Video rides the native AirPlay mirror — no second encode, the phone stays cool. The Airlive link carries control only.")
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
                 ? "Plug the HDMI / USB capture device in — the picture appears automatically."
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
            CameraControlPanel(channel: c)
                .id(c.id)   // reset the panel's local @State when the controlled channel changes
                // `remoteControlConnected` = the ARLV control side for a combined channel, else
                // the single connection — so the panel enables on CONTROL, not on AirPlay video.
                .disabled(!c.remoteControlConnected || !c.remoteControlAllowed)
                .opacity((c.remoteControlConnected && c.remoteControlAllowed) ? 1.0 : 0.4)
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
