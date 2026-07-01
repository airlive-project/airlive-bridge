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

/// An inversion-safe slider range from device-read capability bounds.  `DeviceCapabilities.init(from:)`
/// is deliberately partial-tolerant (`decodeIfPresent ?? default`), so a sender that supplies ONE bound
/// while its pair falls back to a default can yield lower > upper (e.g. isoMin=5000 with isoMax=3200
/// default).  `lower...upper` traps with a fatalError on that — which would CRASH the Bridge from any
/// non-conforming/hostile camera on the LAN.  min/max keeps it a valid (possibly single-point) range.
private func capRange(_ a: Double, _ b: Double) -> ClosedRange<Double> {
    Swift.min(a, b)...Swift.max(a, b)
}

struct CameraControlPanel: View {
    @ObservedObject var channel: BridgeChannel
    /// Hide the LENS card where a lens picker already sits above the panel (the multiview
    /// quick-row) — avoids the duplicate.  Solo has no top row, so it keeps the card.
    var showLens: Bool = true

    // Local slider state — seeded from `remote`, committed on drag-end.
    @State private var iso: Double = 400
    @State private var shutterDenom: Double = 50
    @State private var wbKelvin: Double = 5600
    @State private var tint: Double = 0
    @State private var focus: Double = 0.5
    @State private var zoom: Double = 1

    // Toggle mirrors (the auto pills grey out their matching sliders).
    @State private var exposureAuto = true
    @State private var whiteBalanceAuto = true
    @State private var focusAuto = true
    @State private var isoCompensation = false
    @State private var lutEnabled = false

    /// Canonical iPhone lens ladder — used only when the camera hasn't reported
    /// its own `availableLenses` yet, so the picker always has tiles to show.
    private static let fallbackLenses = ["0.5x", "1x", "2x", "3x", "5x"]

    /// Device-read capability ranges for THIS camera (slider bounds adapt to the phone instead
    /// of hardcoded tables).  Falls back to the wire defaults when an old camera sends none.
    private var caps: DeviceCapabilities { channel.remote?.capabilities ?? DeviceCapabilities() }

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
        Card {
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
            if channel.kind == .airlive { deliveryCard }
            delayCard
            if showLens { lensCard }
            exposureCard
            whiteBalanceCard
            focusCard
            framingCard
        }
    }

    // MARK: Output delay (jitter-buffer latency) — per channel, in BOTH modes

    /// This channel's playout latency (jitter buffer).  A receiver-side Bridge setting, so
    /// it lives with camera control and shows in Solo AND Multiview.  (A precise ms field is
    /// roadmapped alongside these presets — see ROADMAP.md.)
    private var delayCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionLabel(text: "Output delay (ms)")
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
    }

    private func delayShortLabel(_ preset: LatencyPreset) -> String {
        switch preset {
        case .lowest: return "Lowest +0"
        case .normal: return "Normal +120"
        case .smooth: return "Smooth +200"
        case .safe:   return "Safe +400"
        }
    }

    // MARK: Delivery mode (Airlive only)

    /// Request Video+Control vs Control-only.  The SELECTION reflects the camera's
    /// CONFIRMED state (`videoActive`), NOT our request: we send `setDeliveryMode` and the
    /// camera re-broadcasts the real `videoActive` in its next snapshot (the request is
    /// never assumed true).  Disabled with the rest of the panel when the operator has
    /// revoked remote control.
    private var deliveryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionLabel(text: "Delivery")
                SegmentedBar(
                    selection: Binding(
                        get: { channel.videoActive ? DeliveryMode.videoAndControl : .controlOnly },
                        set: { channel.send(.setDeliveryMode($0)) }
                    ),
                    options: DeliveryMode.allCases,
                    label: { $0 == .videoAndControl ? "Video + Control" : "Control only" }
                )
                Text(channel.videoActive
                     ? "Sending its own Airlive video."
                     : "Encoder off — control + tally only (video via AirPlay).")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Lens (top)

    private var lensCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionLabel(text: "Lens")
                TileRow {
                    ForEach(lensLadder, id: \.self) { label in
                        QuickTile(title: label,
                                  selected: channel.remote?.lens == label) {
                            channel.send(.setLens(label))
                        }
                    }
                }
            }
        }
    }

    private var lensLadder: [String] {
        let reported = channel.remote?.availableLenses ?? []
        return reported.isEmpty ? Self.fallbackLenses : reported
    }

    // MARK: Exposure (ISO comp + AE-gated ISO / shutter)

    private var exposureCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    SectionLabel(text: "Exposure")
                    Spacer()
                    PillToggle(title: "Auto",
                               isOn: $exposureAuto,
                               accent: Theme.accentYellow,
                               onText: Theme.bgApp) { on in
                        channel.send(.setExposureAuto(on))
                    }
                    .frame(width: 88)
                }

                SliderRow(label: "ISO",
                          valueText: "\(Int(iso))",
                          value: $iso,
                          range: capRange(Double(caps.isoMin), Double(caps.isoMax)),   // device-read, inversion-safe
                          step: 10,            // drag snaps to 10
                          arrowStep: 50,       // arrows jump ±50
                          enabled: !exposureAuto) { v in
                    channel.send(.setISO(Float(v)))
                }
                SliderRow(label: "Shutter",
                          valueText: "1/\(Int(shutterDenom))",
                          value: $shutterDenom,
                          range: capRange(Double(caps.shutterMinDenom), Double(caps.shutterMaxDenom)),
                          step: 1,
                          arrowStep: 10,
                          enabled: !exposureAuto) { v in
                    channel.send(.setShutter(Float(v)))
                }

                // ISO compensation sits UNDER the parameters as a compact check
                // — it biases auto-exposure, so it stays usable in either mode.
                checkbox("ISO compensation", isOn: $isoCompensation) { on in
                    channel.send(.setIsoCompensation(on))
                }
            }
        }
    }

    /// Compact left-aligned checkbox (yellow tick when on) for boolean options
    /// that don't warrant a full-width pill.
    private func checkbox(_ title: String, isOn: Binding<Bool>,
                          onChange: @escaping (Bool) -> Void) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            onChange(isOn.wrappedValue)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(isOn.wrappedValue ? Theme.accentYellow : Theme.textFaint)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: White balance (AWB-gated kelvin / tint)

    private var whiteBalanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    SectionLabel(text: "White balance")
                    Spacer()
                    PillToggle(title: "Auto",
                               isOn: $whiteBalanceAuto,
                               accent: Theme.accentYellow,
                               onText: Theme.bgApp) { on in
                        channel.send(.setWhiteBalanceAuto(on))
                    }
                    .frame(width: 88)
                }
                SliderRow(label: "Temperature",
                          valueText: "\(Int(wbKelvin))K",
                          value: $wbKelvin,
                          range: capRange(Double(caps.wbTempMin), Double(caps.wbTempMax)),   // device-read, inversion-safe
                          step: 50,
                          arrowStep: 100,
                          enabled: !whiteBalanceAuto) { v in
                    channel.send(.setWB(Float(v)))
                }
                SliderRow(label: "Tint",
                          valueText: tintLabel,
                          value: $tint,
                          range: capRange(Double(caps.wbTintMin), Double(caps.wbTintMax)),
                          step: 1,
                          arrowStep: 5,
                          enabled: !whiteBalanceAuto) { v in
                    channel.send(.setTint(Float(v)))
                }
            }
        }
    }

    private var tintLabel: String {
        let v = Int(tint)
        return v > 0 ? "+\(v)" : "\(v)"
    }

    // MARK: Focus (AF-gated focus position)

    private var focusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    SectionLabel(text: "Focus")
                    Spacer()
                    PillToggle(title: "Auto",
                               isOn: $focusAuto,
                               accent: Theme.accentYellow,
                               onText: Theme.bgApp) { on in
                        channel.send(.setFocusAuto(on))
                    }
                    .frame(width: 88)
                }
                SliderRow(label: "Focus",
                          valueText: focusLabel,
                          value: $focus,
                          range: 0...1,
                          arrowStep: 0.05,
                          enabled: !focusAuto) { v in
                    channel.send(.setFocusPosition(Float(v)))
                }
            }
        }
    }

    private var focusLabel: String {
        // 0 = near, 1 = far — show a percentage so the operator has a feel for
        // the rack without inventing a fake distance the camera didn't report.
        "\(Int(focus * 100))%"
    }

    // MARK: Framing (zoom + preview LUT)

    private var framingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SectionLabel(text: "Framing")
                SliderRow(label: "Zoom",
                          valueText: String(format: "%.1f×", zoom),
                          value: $zoom,
                          range: 1...10,
                          step: 0.1,
                          arrowStep: 0.5,
                          enabled: true) { v in
                    channel.send(.setZoom(Float(v)))
                }
                lutRow
            }
        }
    }

    private var lutRow: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Preview LUT")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Text(channel.remote?.lutName ?? "None loaded")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textFaint)
                    .lineLimit(1)
            }
            Spacer()
            PillToggle(title: lutEnabled ? "On" : "Off",
                       isOn: $lutEnabled,
                       accent: Theme.accentBlue) { on in
                channel.send(.setLUT(name: channel.remote?.lutName, enabled: on))
            }
            .frame(width: 72)
            .opacity(channel.remote?.lutName == nil ? 0.45 : 1)
            .allowsHitTesting(channel.remote?.lutName != nil)
        }
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
    /// Hide the LENS card where a lens quick-row already sits above (multiview).
    var showLens: Bool = true

    var body: some View {
        if channel.kind == .airlive || channel.kind == .screenMirroringPlusControl {
            ControlPanel(c: channel, showLens: showLens)         // owns a back-channel (ARLV)
        } else {
            noControlHint                                         // plain Screen Mirroring / capture
        }
    }

    private var noControlHint: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionLabel(text: "Camera control")
            HStack(spacing: Spacing.sm) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 14)).foregroundColor(Theme.textFaint)
                Text("Screen Mirroring has no remote control. Add a “Screen Mirroring + Remote Control” channel instead.")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The control panel for ONE back-channel-owning channel, with the connected / operator-revoked
/// gating.  A STRUCT (not a method) so its `@ObservedObject` subscribes to `c` — the
/// `disabled`/`opacity` gating then reacts to THAT channel's `isConnected` /
/// `remoteControlAllowed`, even when `c` is a bound Remote-Control channel different from the
/// tile being shown (the parent only observes the video tile, not its control channel).
private struct ControlPanel: View {
    @ObservedObject var c: BridgeChannel
    var showLens: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            CameraControlPanel(channel: c, showLens: showLens)
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
