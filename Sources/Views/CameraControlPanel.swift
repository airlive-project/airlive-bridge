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

    // Toggle mirrors (the auto pills grey out their matching sliders).
    @State private var exposureAuto = true
    @State private var whiteBalanceAuto = true
    @State private var focusAuto = true
    @State private var isoCompensation = false
    @State private var lutEnabled = false

    /// Canonical iPhone lens ladder — used only when the camera hasn't reported
    /// its own `availableLenses` yet, so the picker always has tiles to show.
    private static let fallbackLenses = ["0.5x", "1x", "2x", "3x", "5x"]

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
        .onChange(of: channel.remote) { _, newValue in
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
            lensCard
            exposureCard
            whiteBalanceCard
            focusCard
            framingCard
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
                    PillToggle(title: exposureAuto ? "Auto" : "Manual",
                               isOn: $exposureAuto,
                               accent: Theme.accentBlue) { on in
                        channel.send(.setExposureAuto(on))
                    }
                    .frame(width: 96)
                }

                // ISO compensation rides above the manual sliders — it only
                // biases the camera's auto-exposure, so it lives with exposure
                // but stays usable whether AE is on or off.
                PillToggle(title: "ISO compensation",
                           isOn: $isoCompensation,
                           accent: Theme.accentYellow) { on in
                    channel.send(.setIsoCompensation(on))
                }

                SliderRow(label: "ISO",
                          valueText: "\(Int(iso))",
                          value: $iso,
                          range: 25...6400,
                          step: 1,
                          enabled: !exposureAuto) { v in
                    channel.send(.setISO(Float(v)))
                }
                SliderRow(label: "Shutter",
                          valueText: "1/\(Int(shutterDenom))",
                          value: $shutterDenom,
                          range: 24...8000,
                          step: 1,
                          enabled: !exposureAuto) { v in
                    channel.send(.setShutter(Float(v)))
                }
            }
        }
    }

    // MARK: White balance (AWB-gated kelvin / tint)

    private var whiteBalanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    SectionLabel(text: "White balance")
                    Spacer()
                    PillToggle(title: whiteBalanceAuto ? "Auto" : "Manual",
                               isOn: $whiteBalanceAuto,
                               accent: Theme.accentBlue) { on in
                        channel.send(.setWhiteBalanceAuto(on))
                    }
                    .frame(width: 96)
                }
                SliderRow(label: "Temperature",
                          valueText: "\(Int(wbKelvin))K",
                          value: $wbKelvin,
                          range: 2500...10000,
                          step: 50,
                          enabled: !whiteBalanceAuto) { v in
                    channel.send(.setWB(Float(v)))
                }
                SliderRow(label: "Tint",
                          valueText: tintLabel,
                          value: $tint,
                          range: -150...150,
                          step: 1,
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
                    PillToggle(title: focusAuto ? "Auto" : "Manual",
                               isOn: $focusAuto,
                               accent: Theme.accentBlue) { on in
                        channel.send(.setFocusAuto(on))
                    }
                    .frame(width: 96)
                }
                SliderRow(label: "Focus",
                          valueText: focusLabel,
                          value: $focus,
                          range: 0...1,
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
