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

/// The range, and nothing else. Two duration fields whose readout matches the countdown on the
/// button, so what you set is what you read back there.
private struct AutoCutSettings: View {
    /// Read once and written on Apply - NOT observed. Observing it would rebuild the open panel on
    /// every tick of the countdown for a number the panel never shows.
    let auto: AutoSwitcher
    let close: () -> Void

    static let size = CGSize(width: 330, height: 172)

    @State private var lo: Int
    @State private var hi: Int
    /// Which box has the keyboard, so the panel can ring it.
    @State private var editing: Field?
    private enum Field { case lo, hi }

    /// Seeded here rather than in `onAppear`: the boxes are built with the stored range, instead
    /// of first drawing `0:00` and being corrected a moment later.
    init(auto: AutoSwitcher, close: @escaping () -> Void) {
        self.auto = auto
        self.close = close
        _lo = State(initialValue: auto.minSeconds)
        _hi = State(initialValue: auto.maxSeconds)
    }

    /// Checked live, and that is right for THIS field: every keystroke leaves a complete
    /// duration behind (`0:06`, `1:00`, `6:00`), never a half-typed one, so there is no
    /// unfinished state to be tactful about. Suppressing it while the box had focus meant the
    /// warning never appeared at all - the operator sits in the field the whole time - and left
    /// Apply looking pressable while it silently refused.
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

            HStack(spacing: Spacing.sm) {
                Text("Hold a camera")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: Spacing.sm)
                Text("from").font(.system(size: 11)).foregroundColor(Theme.textFaint)
                field($lo, focus: .lo, bad: false)
                Text("to").font(.system(size: 11)).foregroundColor(Theme.textFaint)
                field($hi, focus: .hi, bad: orderWrong)
            }
            .padding(.top, 14)

            Text(orderWrong ? "The second value cannot be smaller than the first."
                            : "A fresh random value inside the range before every cut.")
                .font(.system(size: 11))
                .foregroundColor(orderWrong ? Theme.accentRed : Theme.textFaint)
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
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                                    .fill(Theme.accentBlue))
                    .opacity(orderWrong ? 0.35 : 1)
                    .disabled(orderWrong)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, Spacing.sm)
        }
        .padding(Spacing.md)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    private func field(_ value: Binding<Int>, focus: Field, bad: Bool) -> some View {
        DurationField(seconds: value,
                      onFocusChange: { focused in editing = focused ? focus : (editing == focus ? nil : editing) },
                      onSubmit: { apply() },
                      onCancel: { close() })
            .frame(width: 62, height: 26)
            .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Theme.bgSelected))
            .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .stroke(bad ? Theme.accentRed
                                    : (editing == focus ? Theme.accentBlue : Theme.strokeDivider),
                                lineWidth: 1))
    }

    private func apply() {
        guard hi >= lo else { return }
        auto.minSeconds = lo
        auto.maxSeconds = hi
        close()
    }
}
