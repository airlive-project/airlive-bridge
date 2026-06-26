// Components.swift — the shared themed view vocabulary for Bridge.
//
// One place for every repeated UI piece, so a control looks identical in the
// Channels rail, the center panel, and the Outputs rail with no copy-paste
// drift.  Theme.swift tokens (colour / spacing / radius / control sizes) are the
// single source of truth — nothing here hardcodes a hex or a magic dimension.
//
// Discipline carried from Studio's StudioDesign: FLAT surfaces (no gradients),
// 1 pt low-contrast strokes, depth from brightness steps + borders only.  Two
// rules this kit enforces that the previous revision violated:
//
//   • NO native NSSlider.  `Slider` on macOS draws stray white tick marks under
//     its track in dark mode; the custom `StyledSlider` here is a track + knob +
//     drag gesture with nothing else, so there is no AppKit chrome to leak.
//   • EQUAL-width segments.  `SegmentedBar` lays its segments out with
//     `frame(maxWidth: .infinity)` inside one HStack, so they share the row
//     evenly and can never overflow it — the old `.segmented` Picker rendered
//     uneven, crooked widths.
//
// ─────────────────────────────────────────────────────────────────────────────
// Public component vocabulary (what the zone views consume):
//
//   Card { … }                         rounded panel container
//   SectionLabel(text:)                small uppercase muted caption (no rule)
//   PillToggle(title:isOn:onChange:)   clear on/off pill (accent fill when on)
//   SegmentedBar(selection:options:)   equal-width segmented control
//   StyledSlider(value:in:step:onChange:)  custom dark slider, no tick artifacts
//   QuickTile(title:subtitle:selected:action:)  card-style quick-select tile
//   TileRow(items:) { … }              evenly-spaced row of tiles
//
// Retained helpers (used across the rails — kept stable, internals upgraded):
//   .cardSurface() / .panelSurface()   card surface modifier (alias kept)
//   .bridgeButton(selected:accent:)    standard inline button look
//   StatusPill / ConnectionDot         LIVE/OFF pill + connection dot
//   SliderRow(…)                       label + readback + StyledSlider row
//   AutoToggle(…)                      AE/AWB/AF toggle (wraps PillToggle)
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import AppKit   // NSApp — resign first responder so inline edits always exit

// MARK: - Inline editable text (THE one renameable / editable field)

/// One design-system element for every editable value (channel name, output name, stream
/// URL) so they all behave identically:
///   • resting state is a LABEL in a field-styled box → nothing auto-grabs focus on launch;
///   • a SINGLE click turns it into a focused field (blue stroke);
///   • it commits on Return OR when focus leaves — clicking another field, or the empty
///     rail (the rails call `resignInlineEditing()` on an empty click / row select) — so it
///     can NEVER get stuck focused with no way out;
///   • Esc cancels.
/// The component keeps its own edit draft and hands back the trimmed string via `onCommit`.
/// `allowEmpty` lets config fields clear; names reject empty (keep the old value).
struct InlineEditable: View {
    let placeholder: String
    let value: String
    var font: Font = .system(size: 13, weight: .medium)
    var allowEmpty: Bool = false
    let onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .foregroundColor(Theme.textPrimary)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }              // Esc cancels
                    .onChange(of: focused) { if !$0 { commit() } }  // focus loss commits
            } else {
                Text(value.isEmpty ? placeholder : value)
                    .foregroundColor(value.isEmpty ? Theme.textFaint : Theme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { begin() }                       // single click → edit
            }
        }
        .font(font)
        .padding(.horizontal, Spacing.sm)
        .frame(height: ControlMetrics.pillHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Theme.bgApp)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .stroke(editing ? Theme.accentBlue : Theme.stroke, lineWidth: 1)
        )
    }

    private func begin() {
        draft = value
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard editing else { return }   // ignore the focus-loss that follows our own exit
        editing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowEmpty || !trimmed.isEmpty { onCommit(trimmed) }
    }
}

/// Drop keyboard focus from any inline edit — the rails call this on an empty-area click
/// or when selecting another row, so a field never stays stuck focused.
func resignInlineEditing() { NSApp.keyWindow?.makeFirstResponder(nil) }

// MARK: - Card (rounded panel container)

/// A flat card: panel-tier fill, 1 pt stroke, panel radius, consistent inner
/// padding.  This is the standard container for any grouped block of controls —
/// the center control panel, the output cards.  Padding lives INSIDE the card so
/// every call site gets the same inner rhythm for free.
struct Card<Content: View>: View {
    var corner: CGFloat = Radius.panel
    var padding: CGFloat = Spacing.md
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(corner: corner)
    }
}

/// The card SURFACE as a modifier (fill + stroke, no padding) for places that
/// must control their own padding — e.g. a card whose content already manages
/// edge-to-edge sections.  `Card` is preferred; this is the escape hatch.
struct CardSurface: ViewModifier {
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
    /// Apply the card surface (fill + 1 pt stroke) without padding.
    func cardSurface(corner: CGFloat = Radius.panel) -> some View {
        modifier(CardSurface(corner: corner))
    }

    /// Back-compat alias — existing call sites use `.panelSurface()`.  Same
    /// surface as `cardSurface`; kept so the rails compile unchanged.
    func panelSurface(corner: CGFloat = Radius.panel) -> some View {
        modifier(CardSurface(corner: corner))
    }
}

// MARK: - Section label (no underline divider)

/// A small uppercase muted caption titling a group of controls.  Deliberately
/// has NO trailing rule / divider — section grouping is carried by spacing and
/// the card edge, not by a line under the caption.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.0)
            .foregroundColor(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Pill toggle (clear on/off)

/// A clear on/off pill with an obvious active state.  ON = accent fill + white
/// text; OFF = quiet outlined neutral chip.  Used for AE / AWB / AF and the
/// ISO-compensation toggle.  `accent` defaults to blue; tally-style callers can
/// pass red / yellow.
///
/// The whole pill is one tap target (`contentShape`), so the padded area around
/// the label is live, not just the glyph.
struct PillToggle: View {
    let title: String
    @Binding var isOn: Bool
    var accent: Color = Theme.accentBlue
    /// Text colour when on — pass a dark colour for light accents (yellow!),
    /// where white text would be the worst contrast. Defaults to white (blue/red).
    var onText: Color = .white
    /// Called with the new value after the toggle flips — the moment to send a
    /// control command (commit, not per-keystroke).
    var onChange: (Bool) -> Void = { _ in }

    @State private var hovering = false

    var body: some View {
        Button {
            isOn.toggle()
            onChange(isOn)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isOn ? onText : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: ControlMetrics.pillHeight)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .stroke(isOn ? Color.clear : Theme.stroke, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.control,
                                               style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isOn)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var fill: Color {
        if isOn { return accent }
        return hovering ? Theme.bgHover : Theme.bgSelected.opacity(0.6)
    }
}

// MARK: - Segmented bar (equal-width segments)

/// A clean segmented control whose segments are EQUAL width and never overflow
/// their row.  Each segment is `frame(maxWidth: .infinity)` inside one HStack on
/// a tracked background, so the row divides evenly however many options it holds
/// — no crooked, ragged widths.  Used for Tally and Output delay.
///
/// `Option` is anything `Hashable & Identifiable`; the caller supplies a label
/// for each.  The selected segment gets the accent fill (per-option accent is
/// supported so a Program segment can read red while Preview reads yellow).
struct SegmentedBar<Option: Hashable & Identifiable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    /// Per-segment accent for the selected fill; defaults to blue for every
    /// option.  Pass a closure to colour Program red / Preview yellow.
    var accent: (Option) -> Color = { _ in Theme.accentBlue }
    var onChange: (Option) -> Void = { _ in }

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: Radius.control + Spacing.xxs,
                             style: .continuous)
                .fill(Theme.bgApp)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control + Spacing.xxs,
                             style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option == selection
        let tint = accent(option)
        return Button {
            selection = option
            onChange(option)
        } label: {
            Text(label(option))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isSelected ? .white : Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: ControlMetrics.segmentHeight)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(isSelected ? tint : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.control,
                                               style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

// MARK: - Styled slider (custom, no tick-mark artifacts)

/// A custom horizontal slider: filled track + round knob, nothing else.  Renders
/// cleanly on macOS in dark mode — there is NO native NSSlider involved, so none
/// of the stray white tick lines AppKit draws under `Slider` in a dark theme.
///
/// Binds to a `Double` with `min...max` and an optional `step`.  `onChange` (if
/// supplied) fires on the editing-END (mouse-up) only — a drag sends ONE value,
/// not one per pixel — matching the cheap-control-packet rule.
struct StyledSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var tint: Color = Theme.accentBlue
    /// Called once when the drag ends, with the final (stepped) value.
    var onChange: (Double) -> Void = { _ in }

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let knob = ControlMetrics.sliderKnob
            let usable = max(0, geo.size.width - knob)
            let fraction = normalizedFraction()
            let knobX = usable * fraction

            ZStack(alignment: .leading) {
                // Empty track — full width, centred vertically.
                Capsule()
                    .fill(Theme.bgApp)
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                    .frame(height: ControlMetrics.sliderTrack)

                // Filled portion up to the knob centre.
                Capsule()
                    .fill(tint)
                    .frame(width: knobX + knob / 2, height: ControlMetrics.sliderTrack)

                // Knob.
                Circle()
                    .fill(Theme.textPrimary)
                    .overlay(Circle().stroke(tint, lineWidth: dragging ? 2 : 1))
                    .frame(width: knob, height: knob)
                    .offset(x: knobX)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())   // whole row is draggable, not just the knob
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        update(toX: g.location.x, usable: usable, knob: knob)
                    }
                    .onEnded { _ in
                        dragging = false
                        onChange(value)
                    }
            )
        }
        .frame(height: ControlMetrics.sliderKnob)   // GeometryReader needs a height
    }

    /// Where the knob sits, 0...1, clamped.
    private func normalizedFraction() -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    /// Translate a drag x-position into a (stepped, clamped) value.
    private func update(toX x: CGFloat, usable: CGFloat, knob: CGFloat) {
        guard usable > 0 else { return }
        let clampedX = min(max(0, x - knob / 2), usable)
        let fraction = Double(clampedX / usable)
        let span = range.upperBound - range.lowerBound
        var raw = range.lowerBound + fraction * span
        if step > 0 {
            raw = (raw / step).rounded() * step
        }
        value = min(range.upperBound, max(range.lowerBound, raw))
    }
}

// MARK: - Quick tile + tile row (card-style quick-select)

/// A card-style quick-select tile: a title (and optional subtitle) on a small
/// rounded card.  Tap to select; the selected tile gets an accent border + a
/// faint accent-tinted fill.  Used for the lens picker.
struct QuickTile: View {
    let title: String
    var subtitle: String? = nil
    var selected: Bool = false
    var accent: Color = Theme.accentBlue
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xxs) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(selected ? .white : Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(selected ? .white.opacity(0.8)
                                                  : Theme.textFaint)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: ControlMetrics.tileHeight)
            .background(
                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .stroke(selected ? accent : Theme.stroke,
                            lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.tile,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var fill: Color {
        if selected { return accent.opacity(0.18) }
        return hovering ? Theme.bgHover : Theme.bgSelected.opacity(0.5)
    }
}

/// An evenly-spaced row of quick tiles.  Each child shares the row width via the
/// tile's own `maxWidth: .infinity`, so a row of N tiles divides evenly and
/// never overflows.  Caller supplies the tiles as content.
struct TileRow<Content: View>: View {
    var spacing: CGFloat = Spacing.sm
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: spacing) {
            content()
        }
    }
}

// MARK: - Inline button (standard tappable look)

/// The app's standard button look: flat neutral fill that brightens on hover,
/// switches to the supplied accent when `selected`.  `accent` defaults to blue;
/// tally buttons pass red / yellow.  Kept stable for the rails / center pane.
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
                        .stroke(selected ? Color.clear : Theme.stroke,
                                lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: corner,
                                               style: .continuous))
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

/// Small filled circle: accent-blue when connected, faint grey when not.  A
/// faint ring keeps it visible against any surface.
struct ConnectionDot: View {
    let connected: Bool

    var body: some View {
        Circle()
            .fill(connected ? Theme.accentBlue : Theme.textFaint)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Theme.bgApp, lineWidth: 1))
    }
}

// MARK: - Labelled slider row

/// One manual-control row: a leading label, a trailing read-back value, and a
/// `StyledSlider` underneath.  Greys out + disables when `enabled` is false (the
/// AE / AWB / AF auto modes drive this — manual sliders go inert while auto is
/// on).
///
/// The slider commits on editing-END via `onCommit` — a drag sends ONE packet,
/// not one per pixel (cheap-control-packet rule).
struct SliderRow: View {
    let label: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    /// How much the ◀ / ▶ stepper arrows add or subtract per click.  0 falls
    /// back to `step` (or 1/20 of the range when there's no step), so callers
    /// only set this when the arrows should jump in coarser units than the drag.
    var arrowStep: Double = 0
    var enabled: Bool = true
    /// Called once when the operator finishes dragging (mouse-up) OR taps an
    /// arrow, with the final value — the moment to send a control command.
    var onCommit: (Double) -> Void

    private var stepAmount: Double {
        if arrowStep > 0 { return arrowStep }
        if step > 0 { return step }
        return Swift.max((range.upperBound - range.lowerBound) / 20, 0.01)
    }

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
            HStack(spacing: Spacing.sm) {
                arrow("chevron.left") { adjust(by: -stepAmount) }
                StyledSlider(value: $value,
                             range: range,
                             step: step,
                             onChange: { v in if enabled { onCommit(v) } })
                    .allowsHitTesting(enabled)
                arrow("chevron.right") { adjust(by: stepAmount) }
            }
        }
        .opacity(enabled ? 1 : 0.45)
    }

    /// A compact stepper-arrow button flanking the slider.
    private func arrow(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: ControlMetrics.sliderKnob)
        }
        .bridgeButton(corner: Radius.control)
        .disabled(!enabled)
    }

    /// Step the value by `delta`, clamped to the range, and commit it.
    private func adjust(by delta: Double) {
        guard enabled else { return }
        let next = Swift.min(range.upperBound, Swift.max(range.lowerBound, value + delta))
        value = next
        onCommit(next)
    }
}

// MARK: - Auto toggle (AE / AWB / AF)

/// A compact auto toggle for exposure / white-balance / focus, wrapping
/// `PillToggle`.  ON = accent (auto active); OFF = quiet neutral (manual).
/// Signature kept stable for CameraControlPanel.
struct AutoToggle: View {
    let title: String
    @Binding var isAuto: Bool
    var onChange: (Bool) -> Void

    var body: some View {
        PillToggle(title: title, isOn: $isAuto, onChange: onChange)
    }
}
