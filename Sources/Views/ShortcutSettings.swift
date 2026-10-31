// ShortcutSettings.swift - the Shortcuts section of the Settings window. It is opened from the
// window's section list and from the menu bar (Shortcuts > Customize Shortcuts…), which lands on
// this section; there is no separate Shortcuts window (operator, 2026-10-16: one place).
//
// One column of the window's groups: General switches, Switcher (Cut, Auto Cut), Lenses (6), then
// Channels - one row per channel with BOTH bus chips side by side (Preview = plain digit, Program =
// ⌘digit), so the two-bus switcher model reads as two columns, like the buses themselves.
// Stream Deck has its own section (Integrations).
//
// Click a chip to record (held modifiers build up live as "⌘+…"; Esc cancels);
// right-click a chip to reset that key.  A refused conflict shows a red ring +
// tooltip.  Global mode uses the SAME keys — no modifier prefix (the OBS model).
// Keys act at once, not on Apply: a key is recorded when it is pressed.

import SwiftUI
import AppKit

struct ShortcutSettings: View {
    @ObservedObject var shortcuts: ShortcutCenter
    @ObservedObject var bindings: ShortcutBindings
    @ObservedObject var model: BridgeModel

    /// One shared chip width — every key chip sits on the same grid.
    private let chipWidth: CGFloat = 88

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            generalSection
            switcherSection
            lensesSection
            channelsSection
            // It resets every key on the page (switcher, lenses, channels), so it sits under all
            // of them, not inside one card (operator, 2026-10-07). Left-aligned, away from the
            // window's Apply below on the right, so one is never hit for the other. The switches are
            // not keys and are left alone.
            HStack {
                Button { confirmResetAll() } label: {
                    Text("Reset All Keys")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, Spacing.md)
                        .frame(height: 26)
                }
                .bridgeButton()
                .help("Put every key back to its default")
                .disabled(!shortcuts.enabled)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(shortcuts.enabled ? 1 : 0.85)
    }

    /// Asks first: on a live show, a layout of thirty keys gone at once means wrong cuts until it
    /// is rebuilt.
    private func confirmResetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all keys to their defaults?"
        alert.informativeText = "Every key you assigned on this page goes back to its default."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { bindings.resetAll() }
    }

    private var generalSection: some View {
        SettingsGroup(title: "General") {
            SettingsRow(title: "Enable shortcuts") { SettingsSwitch(isOn: $shortcuts.enabled) }
            SettingsDivider()
            SettingsRow(title: "Show key hints on buttons") { SettingsSwitch(isOn: $shortcuts.showHints) }
                .disabled(!shortcuts.enabled)
            SettingsDivider()
            SettingsRow(title: "Work in other apps",
                        note: "The same keys work while another app is in front.") {
                SettingsSwitch(isOn: $shortcuts.global)
            }
            .disabled(!shortcuts.enabled)
            permissionWarning
        }
    }

    // Only the KEY-ASSIGNMENT sections grey out when shortcuts are off.  The disable MUST NOT
    // wrap the GENERAL rows: it used to sit on the whole column, which disabled the very "Enable
    // shortcuts" switch that turns them back on — once off, there was no way back from the UI.

    private var switcherSection: some View {
        SettingsGroup(title: "Switcher") {
            fixedRow(ShortcutAction(kind: .cut, index: 0), title: "Cut")
            SettingsDivider()
            fixedRow(ShortcutAction(kind: .autoCut, index: 0), title: "Auto Cut")
        }
        .disabled(!shortcuts.enabled)
    }

    private var lensesSection: some View {
        SettingsGroup(title: "Lenses") {
            ForEach(0 ..< 6, id: \.self) { i in
                if i > 0 { SettingsDivider() }
                fixedRow(ShortcutAction(kind: .lens, index: i), title: "Lens \(i + 1)")
            }
        }
        .disabled(!shortcuts.enabled)
    }

    /// Title flush left, chip flush right.
    private func fixedRow(_ action: ShortcutAction, title: String) -> some View {
        SettingsRow(title: title) {
            BindingChip(shortcuts: shortcuts, bindings: bindings, action: action, width: chipWidth)
        }
    }

    // MARK: - Per-channel keys (one row = both buses)

    private var channelsSection: some View {
        SettingsGroup(title: "Channels") {
            if model.channels.isEmpty {
                Text("Add a channel to assign its keys.")
                    .font(.system(size: 13)).foregroundColor(Theme.textFaint)
                    .settingsCell()
            } else {
                // Bus headers, aligned over their chip columns.
                HStack(spacing: Spacing.sm) {
                    Spacer(minLength: Spacing.sm)
                    busHeader("Preview")
                    busHeader("Program")
                }
                .padding(.top, Spacing.sm)
                ForEach(Array(model.channels.prefix(9).enumerated()), id: \.element.id) { pair in
                    if pair.offset > 0 { SettingsDivider() }
                    channelRow(index: pair.offset, name: pair.element.name)
                }
            }
        }
        .disabled(!shortcuts.enabled)
    }

    private func busHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11)).foregroundColor(Theme.textFaint)
            .frame(width: chipWidth)
    }

    /// One channel's row: name · [→ Preview chip] · [→ Program chip].
    private func channelRow(index: Int, name: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(name)
                .font(.system(size: 13)).foregroundColor(Theme.textPrimary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: Spacing.sm)
            BindingChip(shortcuts: shortcuts, bindings: bindings,
                        action: ShortcutAction(kind: .camera, index: index), width: chipWidth)
            BindingChip(shortcuts: shortcuts, bindings: bindings,
                        action: ShortcutAction(kind: .programCut, index: index), width: chipWidth)
        }
        .settingsCell()
    }

    // MARK: - Shared bits

    @ViewBuilder
    private var permissionWarning: some View {
        if shortcuts.enabled && shortcuts.global && !shortcuts.hasPermission {
            SettingsDivider()
            HStack(spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundColor(Theme.accentYellow)
                Text("Needs Input Monitoring")
                    .font(.system(size: 12)).foregroundColor(Theme.accentYellow)
                Spacer()
                // Label sized INSIDE the button — an outer .frame() after the style
                // squeezed the pill and clipped the text to "Grant...".
                Button { shortcuts.requestPermission() } label: {
                    Text("Grant Access…")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, Spacing.sm)
                        .frame(height: 26)
                }
                .bridgeButton(selected: true, corner: Radius.control)
            }
            .settingsCell()
        }
    }
}

// MARK: - One key chip (record on click, reset via right-click)

/// A single binding chip.  Click = record (held modifiers show live as "⌘+…", a real
/// key completes the chord, Esc cancels).  Right-click → Reset to Default.  A refused
/// conflict = red ring + tooltip naming the clashing action.
private struct BindingChip: View {
    let shortcuts: ShortcutCenter
    @ObservedObject var bindings: ShortcutBindings
    let action: ShortcutAction
    let width: CGFloat

    @State private var recording = false
    @State private var monitor: Any?
    @State private var conflict: String?
    @State private var heldModifiers = ""

    var body: some View {
        Button { recording ? finish() : start() } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold).monospaced())
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: width, height: 28)
        }
        .bridgeButton(selected: recording)
        .overlay {
            if conflict != nil {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .stroke(Theme.accentRed, lineWidth: 1)
            }
        }
        .help(conflict.map { "Key already used by “\($0)”" }
              ?? "Click to record a new key · right-click to reset")
        .contextMenu {
            Button("Reset to Default") { bindings.reset(action); conflict = nil }
                .disabled(!bindings.isCustomized(action))
        }
        // If the section closes mid-recording, the NSEvent monitor and the
        // isRecording mute would leak forever — release them when the chip goes away.
        .onDisappear { if recording { finish() } }
    }

    /// The bound chord normally; while recording, held modifiers build up live
    /// ("⌘+…") until a real key completes the chord.
    private var label: String {
        guard recording else { return bindings.chord(for: action).display }
        return heldModifiers.isEmpty ? "Press key…" : "\(heldModifiers)+…"
    }

    private func start() {
        shortcuts.endActiveRecording?()   // finish any OTHER chip mid-record first
        recording = true
        heldModifiers = ""
        shortcuts.isRecording = true   // mute the live engines while capturing
        shortcuts.endActiveRecording = { finish() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {               // live "⌘+…" build-up
                var parts: [String] = []
                if event.modifierFlags.contains(.shift) { parts.append("⇧") }
                if event.modifierFlags.contains(.command) { parts.append("⌘") }
                heldModifiers = parts.joined(separator: "+")
                return event                                // don't swallow modifier state
            }
            if event.keyCode == 53 {                       // Esc cancels
                finish(); return nil
            }
            let chord = KeyChord(event: event)
            if let clash = bindings.set(chord, for: action) {
                conflict = clash.title                     // refused; red ring + tooltip
            } else {
                conflict = nil
            }
            finish()
            return nil                                     // swallow the captured key
        }
    }

    private func finish() {
        guard recording else { return }   // ignore a stale onDisappear after another chip took over
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false
        heldModifiers = ""
        shortcuts.isRecording = false
        shortcuts.endActiveRecording = nil
    }
}
