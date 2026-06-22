// Components.swift — shared themed view vocabulary.
//
// One place for the small, repeated UI pieces every zone uses: the flat panel
// surface, the inline button style, the labelled slider row, the status pill,
// the connection dot.  Keeping them here means a button looks identical in the
// Channels rail and the Outputs rail with no copy-paste drift, and the theme
// (Theme.swift tokens) is the single source of truth for colour/spacing.
//
// Discipline carried from Studio's StudioDesign: FLAT surfaces (no gradients),
// 1 pt low-contrast strokes, depth from brightness steps + borders only.

import SwiftUI

// MARK: - Panel surface

/// A flat card: panel-tier fill, 1 pt stroke, panel radius.  Used to lift the
/// center control panel and the output cards off the canvas.
struct PanelSurface: ViewModifier {
    var corner: CGFloat = Radius.panel

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Theme.bgPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

extension View {
    func panelSurface(corner: CGFloat = Radius.panel) -> some View {
        modifier(PanelSurface(corner: corner))
    }
}

// MARK: - Inline button

/// The app's standard button look: flat neutral fill that brightens on hover,
/// switches to the supplied accent when `selected`.  `accent` defaults to blue
/// (the primary-action accent); tally buttons pass red / yellow.
struct BridgeButtonStyle: ButtonStyle {
    var selected: Bool = false
    var accent: Color = Theme.accentBlue
    var corner: CGFloat = Radius.button

    func makeBody(configuration: Configuration) -> some View {
        BridgeButtonBody(configuration: configuration,
                         selected: selected,
                         accent: accent,
                         corner: corner)
    }

    /// Separate body view so we can host an `@State` hover flag (ButtonStyle's
    /// `makeBody` can't hold view state directly).
    private struct BridgeButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let accent: Color
        let corner: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundColor(selected ? .white : Theme.textPrimary)
                .background(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .stroke(selected ? accent.opacity(0.0) : Theme.stroke,
                                lineWidth: 1)
                )
                .opacity(configuration.isPressed ? 0.85 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: selected)
        }

        private var fill: Color {
            if selected { return accent }
            return hovering ? Theme.bgHover : Theme.bgSelected.opacity(0.6)
        }
    }
}

extension View {
    /// Convenience: wrap any tappable label in the standard Bridge button look.
    func bridgeButton(selected: Bool = false,
                      accent: Color = Theme.accentBlue,
                      corner: CGFloat = Radius.button) -> some View {
        buttonStyle(BridgeButtonStyle(selected: selected,
                                      accent: accent,
                                      corner: corner))
    }
}

// MARK: - Status pill

/// A small rounded LIVE / OFF (or any state) pill.  `on` paints it in `accent`
/// with white text; off is a quiet outlined neutral chip.
struct StatusPill: View {
    let text: String
    var on: Bool
    var accent: Color = Theme.accentRed

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundColor(on ? .white : Theme.textFaint)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(on ? accent : Color.clear)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(on ? Color.clear : Theme.stroke, lineWidth: 1)
            )
    }
}

// MARK: - Connection dot

/// Small filled circle: green-ish (we use blue accent) when connected, faint
/// grey when not.  A faint ring keeps it visible against any surface.
struct ConnectionDot: View {
    let connected: Bool

    var body: some View {
        Circle()
            .fill(connected ? Theme.accentBlue : Theme.textFaint)
            .frame(width: 8, height: 8)
            .overlay(
                Circle().stroke(Theme.bgApp, lineWidth: 1)
            )
    }
}

// MARK: - Section header

/// A small uppercase faint label that titles a group of controls.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.0)
            .foregroundColor(Theme.textFaint)
    }
}

// MARK: - Labelled slider row

/// One manual-control row: a leading label, a trailing read-back value, and a
/// slider underneath.  Greys out + disables when `enabled` is false (the AE /
/// AWB / AF auto modes drive this — manual sliders go inert while auto is on).
///
/// The slider commits CONTINUOUSLY via `onChange` is avoided — instead it
/// reports on editing-end so we don't flood the control channel with a packet
/// per pixel of drag (cheap-control-packet rule: commit, not per-keystroke).
struct SliderRow: View {
    let label: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var enabled: Bool = true
    /// Called once when the operator finishes dragging (mouse-up), with the
    /// final value — this is the moment to send a control command.
    var onCommit: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(enabled ? Theme.textPrimary : Theme.textFaint)
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, weight: .regular).monospacedDigit())
                    .foregroundColor(enabled ? Theme.textSecondary : Theme.textFaint)
            }
            slider
        }
        .opacity(enabled ? 1 : 0.45)
    }

    @ViewBuilder
    private var slider: some View {
        if step > 0 {
            Slider(value: $value, in: range, step: step) { editing in
                if !editing { onCommit(value) }
            }
            .tint(Theme.accentBlue)
            .disabled(!enabled)
        } else {
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit(value) }
            }
            .tint(Theme.accentBlue)
            .disabled(!enabled)
        }
    }
}

// MARK: - Auto toggle chip

/// A compact AUTO / MANUAL toggle for exposure / white-balance / focus.  When
/// `isAuto` the chip reads AUTO in the accent; manual is a quiet neutral chip.
struct AutoToggle: View {
    let title: String
    @Binding var isAuto: Bool
    var onChange: (Bool) -> Void

    var body: some View {
        Button {
            isAuto.toggle()
            onChange(isAuto)
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(isAuto ? "AUTO" : "MANUAL")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: 26)
            .frame(maxWidth: .infinity)
        }
        .bridgeButton(selected: isAuto)
    }
}
