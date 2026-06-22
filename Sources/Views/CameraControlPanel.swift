// CameraControlPanel.swift — remote camera control for the selected channel.
//
// The Blackmagic-style control surface: AE / AWB / AF toggles (which grey out
// their manual sliders), then ISO / shutter / WB / tint / focus sliders, a lens
// picker, a zoom slider, and a LUT toggle.  Every knob sends a `ControlMessage`
// to the iPhone via `channel.send(_:)`; every value LABEL reads back from
// `channel.remote` (the camera's reported StateSnapshot).
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

    // Auto-mode mirrors (the toggles grey out the matching sliders).
    @State private var exposureAuto = true
    @State private var whiteBalanceAuto = true
    @State private var focusAuto = true
    @State private var lutEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            SectionLabel(text: "Camera control")
            if channel.remote == nil {
                waitingNotice
            } else {
                content
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
        .onAppear { seed(from: channel.remote) }
        // Re-seed when a NEW snapshot lands so labels + slider rest positions
        // track the camera's auto-readback / our own confirmed commands.
        .onChange(of: channel.remote) { newValue in
            seed(from: newValue)
        }
    }

    private var waitingNotice: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "wifi.slash")
                .foregroundColor(Theme.textFaint)
            Text("Connect an iPhone to control its camera.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            autoTogglesRow
            Divider().background(Theme.strokeDivider)
            exposureControls
            Divider().background(Theme.strokeDivider)
            whiteBalanceControls
            Divider().background(Theme.strokeDivider)
            focusControls
            Divider().background(Theme.strokeDivider)
            lensControls
            Divider().background(Theme.strokeDivider)
            lutControl
        }
    }

    // MARK: Auto toggles

    private var autoTogglesRow: some View {
        HStack(spacing: Spacing.sm) {
            AutoToggle(title: "AE", isAuto: $exposureAuto) { on in
                channel.send(.setExposureAuto(on))
            }
            AutoToggle(title: "AWB", isAuto: $whiteBalanceAuto) { on in
                channel.send(.setWhiteBalanceAuto(on))
            }
            AutoToggle(title: "AF", isAuto: $focusAuto) { on in
                channel.send(.setFocusAuto(on))
            }
        }
    }

    // MARK: Exposure (ISO + shutter) — greyed while AE on

    private var exposureControls: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
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

    // MARK: White balance (kelvin + tint) — greyed while AWB on

    private var whiteBalanceControls: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SliderRow(label: "White balance",
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

    private var tintLabel: String {
        let v = Int(tint)
        return v > 0 ? "+\(v)" : "\(v)"
    }

    // MARK: Focus — greyed while AF on

    private var focusControls: some View {
        SliderRow(label: "Focus",
                  valueText: focusLabel,
                  value: $focus,
                  range: 0...1,
                  enabled: !focusAuto) { v in
            channel.send(.setFocusPosition(Float(v)))
        }
    }

    private var focusLabel: String {
        // 0 = near, 1 = far — show a percentage so the operator has a feel for
        // the rack without inventing a fake distance the camera didn't report.
        "\(Int(focus * 100))%"
    }

    // MARK: Lens + zoom

    private var lensControls: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            lensPicker
            SliderRow(label: "Zoom",
                      valueText: String(format: "%.1f×", zoom),
                      value: $zoom,
                      range: 1...10,
                      step: 0.1,
                      enabled: true) { v in
                channel.send(.setZoom(Float(v)))
            }
        }
    }

    private var lensPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Lens")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textPrimary)
            HStack(spacing: Spacing.sm) {
                ForEach(lensLadder, id: \.self) { label in
                    lensPill(label)
                }
                if lensLadder.isEmpty {
                    Text("No lenses reported")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textFaint)
                }
            }
        }
    }

    private var lensLadder: [String] {
        channel.remote?.availableLenses ?? []
    }

    private func lensPill(_ label: String) -> some View {
        let selected = channel.remote?.lens == label
        return Button {
            channel.send(.setLens(label))
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 44)
                .frame(height: 32)
                .padding(.horizontal, Spacing.sm)
        }
        .bridgeButton(selected: selected)
    }

    // MARK: LUT

    private var lutControl: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preview LUT")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Text(channel.remote?.lutName ?? "None loaded")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textFaint)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { lutEnabled },
                set: { newValue in
                    lutEnabled = newValue
                    channel.send(.setLUT(name: channel.remote?.lutName,
                                         enabled: newValue))
                }
            ))
            .toggleStyle(.switch)
            .tint(Theme.accentBlue)
            .labelsHidden()
            .disabled(channel.remote?.lutName == nil)
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
        lutEnabled = s.lutEnabled
    }
}
