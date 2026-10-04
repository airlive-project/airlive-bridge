// AutoSwitchButton.swift - the AUTO control in the multiview top bar, and its settings panel.
//
// One split capsule, two jobs: the left half runs the rotation and shows the countdown, the right
// half opens the settings. The gear stays live even when the rotation cannot - an operator with
// one camera connected should still be able to set the range for later, and a control that greys
// out the thing you came to press is a small cruelty.

import SwiftUI

struct AutoSwitchButton: View {
    @ObservedObject var auto: AutoSwitcher
    @ObservedObject private var presenter = DropdownPresenter.shared
    @State private var panelID = UUID()
    @State private var anchor: CGRect = .zero

    var body: some View {
        HStack(spacing: 0) {
            Button { auto.toggle() } label: {
                HStack(spacing: 6) {
                    Text("AUTO")
                        .font(.system(size: 11, weight: .medium))
                    // Fixed slot + tabular digits: `0:07` and `12:40` occupy the same width, so the
                    // capsule never breathes and CUT beside it never shifts.
                    Text(auto.display)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                        .foregroundColor(auto.isOn ? .white : Theme.textFaint)
                }
                .padding(.horizontal, Spacing.sm)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(auto.isOn ? .white : Theme.textPrimary)
            .disabled(!auto.canRun && !auto.isOn)
            .opacity((auto.canRun || auto.isOn) ? 1 : 0.4)
            .help(auto.canRun || auto.isOn
                  ? "Cut to another camera on a random interval"
                  : "Needs 2+ connected cameras")

            Rectangle()
                .fill(auto.isOn ? Color.white.opacity(0.2) : Theme.strokeDivider)
                .frame(width: 1, height: 22)

            Button { openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundColor(auto.isOn ? Color.white.opacity(0.8) : Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Auto cut settings")
        }
        .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .fill(auto.isOn ? Theme.accentBlue : Theme.bgSelected.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .stroke(auto.isOn ? Color.clear : Theme.stroke, lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: auto.isOn)
        // The shared reader, like every other trigger: it keeps an open panel pinned to the button
        // across a window resize, and ignores the sub-pixel jitter that would rewrite state per frame.
        .background(anchorReader($anchor, id: panelID))
        .onDisappear { if presenter.active?.id == panelID { presenter.close() } }
    }

    /// Opens on the app's OWN overlay host, not a system popover: `ContentView` mounts one so
    /// every floating surface wears our radius and shadow instead of AppKit's chrome.
    private func openSettings() {
        let panel = AutoCutSettings(auto: auto) { DropdownPresenter.shared.close() }
        presenter.toggle(.init(id: panelID, anchor: anchor, rows: [], fitContent: true,
                               panel: AnyView(panel), panelSize: AutoCutSettings.size))
    }
}

// MARK: - Settings panel

/// The range, and nothing else, set by CLICKING. Each bound is an `MM:SS` timer with an arrow
/// above and below every digit (operator's design, 2026-10-04): any value from 0:01 to 60:00 is a
/// handful of clicks, where a single stepper needed hundreds to reach ten minutes.
///
/// No text entry, deliberately, and that is an operator decision (2026-10-04) after a live
/// failure: 1.4.0 shipped a typed `M:SS` box that took the keyboard for itself, and on a long
/// show the camera shortcuts stopped working altogether. A switcher's keyboard belongs to the
/// switcher - Space and the digits must cut whatever panel is open - so this panel holds no
/// keyboard focus at any moment.
private struct AutoCutSettings: View {
    /// Read once and written on Apply - NOT observed. Observing it would rebuild the open panel on
    /// every tick of the countdown for a number the panel never shows.
    let auto: AutoSwitcher
    let close: () -> Void

    /// Sized FROM the two timers: the panel is as wide as they are side by side, and the text wraps
    /// to fit them rather than the panel stretching to fit the text.
    static let size = CGSize(width: 2 * DigitTimer.width + Spacing.lg + 2 * Spacing.md, height: 256)

    @State private var lo: Int
    @State private var hi: Int

    /// Seeded here rather than in `onAppear`, so the panel draws the stored range from its first frame.
    init(auto: AutoSwitcher, close: @escaping () -> Void) {
        self.auto = auto
        self.close = close
        _lo = State(initialValue: auto.minSeconds)
        _hi = State(initialValue: auto.maxSeconds)
    }

    private var orderWrong: Bool { hi < lo }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Auto cut")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textPrimary)
            Text("Needs 2+ connected cameras.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textFaint)
                .padding(.top, 4)

            Text("Hold each camera between")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 14)

            HStack(alignment: .top, spacing: Spacing.lg) {
                bound("From", $lo, bad: false)
                bound("To", $hi, bad: orderWrong)
            }
            .padding(.top, 10)

            Text(orderWrong ? "The second value cannot be smaller than the first."
                            : "A fresh random value inside the range before every cut.")
                .font(.system(size: 11))
                .foregroundColor(orderWrong ? Theme.accentRed : Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Spacer(minLength: 0)
            Rectangle().frame(height: 1).foregroundColor(Theme.stroke)
                .padding(.horizontal, -Spacing.md)

            HStack(spacing: Spacing.xs) {
                Spacer()
                Button("Cancel") { close() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                                    .fill(Theme.bgSelected.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                                .stroke(Theme.stroke, lineWidth: 1))
                Button("Apply") { apply() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                                    .fill(Theme.accentBlue))
                    .opacity(orderWrong ? 0.35 : 1)
                    .disabled(orderWrong)
            }
            .padding(.top, Spacing.sm)
        }
        .padding(Spacing.md)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    /// One bound: the app's section label above its timer, the same pairing the side rails use.
    private func bound(_ title: String, _ value: Binding<Int>, bad: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title)
            DigitTimer(seconds: value, bad: bad)
        }
    }

    private func apply() {
        guard hi >= lo else { return }
        auto.minSeconds = lo
        auto.maxSeconds = hi
        close()
    }
}

/// `MM:SS` with an arrow above and below each digit. A click moves that one digit up or down,
/// wrapping inside its own range (minute tens 0-6, second tens 0-5, ones 0-9) without carrying, the
/// way a digit wheel does; the result is then held inside 0:01-60:00. Plain buttons only - nothing
/// here can take keyboard focus.
///
/// Built from the design system: the value face is the camera panel's readout (19 pt medium,
/// tabular digits), the box is the dropdown trigger's surface, and the arrows stay faint until the
/// pointer is on them, so the time reads first and the controls second.
private struct DigitTimer: View {
    @Binding var seconds: Int
    let bad: Bool

    /// Place value of each digit in seconds, and how many values it cycles through.
    private static let digits: [(weight: Int, base: Int)] = [(600, 7), (60, 10), (10, 6), (1, 10)]
    private static let face = Font.system(size: 19, weight: .medium).monospacedDigit()

    var body: some View {
        HStack(spacing: 0) {
            column(0); column(1)
            // The separator sits on the digit row, between the arrow rows, so it lines up with the
            // numbers rather than with the middle of the whole column.
            // Fixed width on the spacers too: a bare `Color.clear` is flexible and swallowed every
            // spare point of the panel, stretching the box.
            VStack(spacing: 0) {
                Color.clear.frame(width: Self.colonWidth, height: Arrow.height)
                Text(":")
                    .font(Self.face)
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: Self.colonWidth, height: Self.digitHeight)
                    .offset(y: -1)
                Color.clear.frame(width: Self.colonWidth, height: Arrow.height)
            }
            column(2); column(3)
        }
        .padding(.horizontal, Self.sidePadding)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Theme.bgSelected))
        .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .stroke(bad ? Theme.accentRed : Theme.strokeDivider, lineWidth: 1))
        .fixedSize()   // hug the digits, never stretch to the panel
    }

    private static let digitHeight: CGFloat = 24
    private static let digitWidth: CGFloat = 18
    private static let colonWidth: CGFloat = 10
    private static let sidePadding: CGFloat = 6
    /// The box's whole width - the settings panel sizes itself from it.
    static let width = 4 * digitWidth + colonWidth + 2 * sidePadding

    private func digit(_ i: Int) -> Int {
        let d = Self.digits[i]
        return (seconds / d.weight) % d.base
    }

    private func column(_ i: Int) -> some View {
        VStack(spacing: 0) {
            Arrow(up: true) { nudge(i, by: 1) }
            Text("\(digit(i))")
                .font(Self.face)
                .foregroundColor(Theme.textPrimary)
                .frame(width: Self.digitWidth, height: Self.digitHeight)
            Arrow(up: false) { nudge(i, by: -1) }
        }
    }

    private func nudge(_ i: Int, by delta: Int) {
        let d = Self.digits[i]
        let current = digit(i)
        let next = (current + delta + d.base) % d.base
        let value = seconds + (next - current) * d.weight
        seconds = min(max(value, AutoSwitcher.minAllowed), AutoSwitcher.maxAllowed)
    }

    /// A small chevron that brightens and gets the hover surface under the pointer.
    private struct Arrow: View {
        static let height: CGFloat = 16
        let up: Bool
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                Image(systemName: up ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(hovered ? Theme.textPrimary : Theme.textFaint)
                    .frame(width: 18, height: Self.height)
                    .background(RoundedRectangle(cornerRadius: 4).fill(hovered ? Theme.bgHover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
    }
}
