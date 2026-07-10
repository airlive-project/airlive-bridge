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
//   • NO native NSSlider.  Manual values use `ParamStrip` (a bounded value tape you
//     scrub), not a slider — no AppKit chrome to leak stray tick marks in dark mode.
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
//   SegmentedBar(selection:options:)   equal-width segmented control
//   ParamStrip(…)                      one control row: label · value · chips · slim scrub tape
//   ControlSection(title:auto:…) { … } titled card grouping rows, one section-level AUTO
//   QuickTile(title:subtitle:selected:action:)  card-style quick-select tile
//   TileRow(items:) { … }              evenly-spaced row of tiles
//
// Retained helpers (used across the rails — kept stable, internals upgraded):
//   .cardSurface() / .panelSurface()   card surface modifier (alias kept)
//   .bridgeButton(selected:accent:)    standard inline button look
//   StatusPill / ConnectionDot         LIVE/OFF pill + connection dot
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
    /// When true, the field's stroke goes red — a caller flashes this to explain
    /// why an action was refused (e.g. toggling SRT on with no destination).
    var errorFlash: Bool = false
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
                .stroke(errorFlash ? Theme.accentRed : (editing ? Theme.accentBlue : Theme.stroke),
                        lineWidth: errorFlash ? 1.5 : 1)
        )
        // The red flashes ON instantly (the refusal must register) and FADES OUT
        // smoothly (0.35 s ease-out) when the caller clears it — never a hard snap.
        .animation(.easeOut(duration: 0.35), value: errorFlash)
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

// MARK: - Non-restorable window marker

/// Marks the hosting NSWindow as NOT part of macOS state restoration.  Auxiliary
/// windows (Shortcuts, the multiview wall) must not silently reopen on the next
/// launch just because the app quit while they were up — the operator opens them
/// deliberately.  Attach as `.background(NonRestorableWindow())`.
struct NonRestorableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.isRestorable = false }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.isRestorable = false }
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

// MARK: - Parameter strip (one control row: label · value · chips · slim scrub tape)

/// One parameter ROW inside a `ControlSection`: the label, the big current VALUE (the hero — yellow
/// while its section reads AUTO), optional quick-pick CHIPS, and a slim scrub tape below.  The tape's
/// marker sits at the value's position in the ladder, so far-left = the floor and far-right = the
/// ceiling (the "can I still go lower?" question, answered visually).  Dragging the tape scrubs the
/// real stops; the chips jump to standard values; both drop out of AUTO on touch.
struct ParamStrip: View {
    let label: String
    let values: [Double]                 // ascending ladder — the whole reachable range
    @Binding var value: Double
    let display: (Double) -> String
    /// The section's AUTO state — colours the value yellow while auto reads live.
    var auto: Bool = false
    /// Quick-pick presets (standard stops).  Empty → no chips (Tint / Focus / Zoom).
    var presets: [Double] = []
    /// Custom chip tap — WB presets set temperature AND tint together (the phone's lighting pairs).
    /// nil → tapping a chip just jumps this strip to that value.
    var onPresetTap: ((Double) -> Void)? = nil
    /// Custom chip active-check — WB: highlighted only when BOTH temp and tint match the pair.
    /// nil → active when the strip's value equals the preset.
    var presetActive: ((Double) -> Bool)? = nil
    /// Touching the tape / a chip while AUTO is on drops the section to manual.
    var onExitAuto: (() -> Void)? = nil
    var onCommit: (Double) -> Void

    @State private var dragging = false

    static let rowHeight: CGFloat = 46

    /// Nearest ladder index to the current value (value can be off-ladder while AUTO reads live).
    private var selIdx: Int {
        var best = 0, bestD = Double.infinity
        for (i, v) in values.enumerated() where abs(v - value) < bestD { bestD = abs(v - value); best = i }
        return best
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Text(display(value))
                    .font(.system(size: 19, weight: .medium).monospacedDigit())
                    .foregroundColor(auto ? Theme.accentYellow : Theme.textPrimary)
                Spacer(minLength: 8)
                if !presets.isEmpty { presetChips }
            }
            slimTape
        }
        .frame(height: Self.rowHeight)
    }

    /// Quick-pick chips (standard stops).  Tap to jump; the active one glows yellow.
    private var presetChips: some View {
        HStack(spacing: 5) {
            ForEach(presets, id: \.self) { p in
                let active = presetActive?(p) ?? (abs(value - p) < 0.0001)
                Button { if let onPresetTap { onPresetTap(p); tick() } else { jump(to: p) } } label: {
                    Text(display(p))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(active ? Theme.accentYellow : Theme.textSecondary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bgHover))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(active ? Theme.accentYellow.opacity(0.6) : Theme.strokeDivider, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Slim scrub tape: even ticks + a yellow marker at the value's position in the ladder.  Drag to
    /// scrub (snaps to stops); left edge = the floor, right edge = the ceiling.
    private var slimTape: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = values.count > 1 ? CGFloat(selIdx) / CGFloat(values.count - 1) : 0
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    let midY = size.height / 2
                    var x: CGFloat = 0
                    while x <= size.width {
                        ctx.fill(Path(CGRect(x: x, y: midY - 3, width: 1, height: 6)),
                                 with: .color(Theme.strokeDivider.opacity(0.6)))
                        x += 13
                    }
                }
                Capsule()
                    .fill(Theme.accentYellow)
                    .frame(width: 3, height: 15)
                    .offset(x: Swift.max(0, Swift.min(w - 3, frac * w)))
            }
            .frame(height: 15)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
            .gesture(scrub(width: w))
        }
        .frame(height: 15)
    }

    /// Ladder value at finger x.  Used by BOTH onChanged and onEnded so the COMMITTED value comes from
    /// the GESTURE, never from a `value` that a mid-drag re-seed may have clobbered (the seed-vs-drag
    /// race — a 1 Hz / post-commit snapshot landing in the sliver before mouse-up).
    private func valueAt(x: CGFloat, width w: CGFloat) -> Double {
        guard w > 0, values.count > 1 else { return value }
        let frac = Double(Swift.min(w, Swift.max(0, x)) / w)
        let idx = Swift.min(values.count - 1, Swift.max(0, Int((frac * Double(values.count - 1)).rounded())))
        return values[idx]
    }

    private func scrub(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard w > 0, values.count > 1 else { return }
                if !dragging { dragging = true; if auto { onExitAuto?() } }
                let next = valueAt(x: g.location.x, width: w)
                if next != value { value = next; tick() }
            }
            .onEnded { g in
                guard dragging else { return }
                dragging = false
                let final = valueAt(x: g.location.x, width: w)   // from the gesture, not a reseeded `value`
                value = final
                onCommit(final)
            }
    }

    /// Tap a chip → jump there (dropping out of auto), commit once.
    private func jump(to v: Double) {
        if auto { onExitAuto?() }
        value = v
        onCommit(v)
        tick()
    }

    private func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - Control section (titled card with one optional section-level AUTO)

/// A titled section card grouping related parameter rows.  The header carries the section's ONE AUTO
/// toggle — exposure-auto governs ISO + Shutter, WB-auto governs Temp + Tint, focus-auto governs Focus
/// — so AUTO lives ONCE per section, not once per row (which is how the camera's auto modes actually
/// work).  `onAuto` nil → no AUTO (the Look section).
struct ControlSection<Content: View>: View {
    let title: String
    var auto: Bool = false
    var onAuto: ((Bool) -> Void)? = nil
    /// Optional compact control shown in the header, LEFT of the AUTO toggle (e.g. EV compensation).
    var accessory: AnyView? = nil
    /// Stretch the card to fill its offered height — set on both cards of a two-column row (with the
    /// row `.fixedSize(vertical:)` + each section `.frame(maxHeight:.infinity)`) so their bottoms line
    /// up even when one has more rows or a taller header (AUTO) than the other.
    var fillHeight: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        Card(padding: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .medium)).tracking(0.6)
                        .foregroundColor(Theme.textFaint)
                    Spacer()
                    if let accessory { accessory }
                    if let onAuto { autoToggle(onAuto) }
                }
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        }
    }

    private func autoToggle(_ action: @escaping (Bool) -> Void) -> some View {
        Button { action(!auto) } label: {
            Text("AUTO")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(auto ? Theme.accentYellow : Theme.textSecondary)
                .padding(.horizontal, 11).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(auto ? Theme.accentYellow.opacity(0.16) : Theme.bgHover))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(auto ? Theme.accentYellow.opacity(0.55) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compact draggable value (a value you scrub, NOT a slider)

/// A small `label · value` pill you DRAG to scrub in `step` units — no track, no tape.  Used for EV
/// compensation beside the Exposure AUTO: it mirrors the phone's value and lets you nudge it.  Grab
/// cursor + per-step haptic; commits on release (one control packet, not one per pixel).
struct CompactValueDrag: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.1
    let display: (Double) -> String
    /// Value goes accent-yellow when this is true (e.g. EV ≠ 0) — else quiet.
    var accent: Bool = false
    /// ACTIVE → sits IN a box at full opacity (reads "live").  INACTIVE → no box, semi-transparent —
    /// still editable (you can pre-set it), but signalled as not-currently-doing-anything.  For EV:
    /// active while auto-exposure is ON (EV biases the auto target); dimmed in manual.
    var active: Bool = true
    var onCommit: (Double) -> Void

    @State private var dragStart: Double?

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.textFaint)
            Text(display(value))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundColor(accent ? Theme.accentYellow : Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.bgHover : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(active ? Theme.strokeDivider : Color.clear, lineWidth: 1))
        .opacity(active ? 1 : 0.45)
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { g in
                    if dragStart == nil { dragStart = value }
                    let next = valueFrom(start: dragStart ?? value, translationWidth: g.translation.width)
                    if abs(next - value) > step / 2 {
                        value = next
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                }
                // Commit the value computed from the GESTURE (frozen `dragStart` + final translation),
                // never a `value` a mid-drag re-seed may have clobbered (the seed-vs-drag race).
                .onEnded { g in
                    guard let start = dragStart else { return }
                    dragStart = nil
                    let final = valueFrom(start: start, translationWidth: g.translation.width)
                    value = final
                    onCommit(final)
                }
        )
    }

    /// Value after dragging `dx` points from a frozen `start` — one step per ~10 pt; snapped + clamped.
    private func valueFrom(start: Double, translationWidth dx: CGFloat) -> Double {
        let raw = start + Double(dx) / 10 * step
        let snapped = (raw / step).rounded() * step
        return Swift.min(range.upperBound, Swift.max(range.lowerBound, snapped))
    }
}
