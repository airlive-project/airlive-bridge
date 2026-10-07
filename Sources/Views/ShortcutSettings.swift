// ShortcutSettings.swift — the "Shortcuts" window (menu bar → Shortcuts → Customize…, ⌘K).
//
// TWO columns so the window stays a normal height no matter how many channels exist
// (a single stacked list overflowed the screen with no way to scroll):
//   LEFT  — the fixed set: GENERAL switches, STREAM DECK, SWITCHER (Cut, Auto Cut), LENSES (6).
//   RIGHT — per-channel keys, ONE ROW per channel with BOTH bus chips side by side
//           (PREVIEW = plain digit, PROGRAM = ⌘digit) — the two-bus switcher model
//           reads as two columns, exactly like the buses themselves.
//
// Click a chip to record (held modifiers build up live as "⌘+…"; Esc cancels);
// right-click a chip to reset that key.  A refused conflict shows a red ring +
// tooltip.  Global mode uses the SAME keys — no modifier prefix (the OBS model).

import SwiftUI
import AppKit

struct ShortcutSettings: View {
    /// The window's scene id: the menu (⌘K) and the Settings window both open it by this.
    static let windowID = "bridge-shortcuts"

    @ObservedObject var shortcuts: ShortcutCenter
    @ObservedObject var bindings: ShortcutBindings
    @ObservedObject var model: BridgeModel
    @ObservedObject var control: ControlServer

    /// Where it is shown. The same keys, switches and chips either way; only the arrangement differs.
    enum Layout {
        /// Its own window (⌘K): two columns, so the window keeps a normal height.
        case window
        /// The Shortcuts section of the Settings window: one column of cards inside the pane's
        /// scroll, and no STREAM DECK block, because Stream Deck has its own section there.
        case settingsPane
    }
    var layout: Layout = .window

    /// One shared chip width — every key chip in the window sits on the same grid.
    private let chipWidth: CGFloat = 88
    private let columnWidth: CGFloat = 320

    var body: some View {
        switch layout {
        case .window:
            HStack(alignment: .top, spacing: Spacing.xl) {
                leftColumn.frame(width: columnWidth)
                Rectangle().fill(Theme.stroke).frame(width: 1)
                rightColumn.frame(width: columnWidth)
            }
            .padding(Spacing.xl)
            .fixedSize(horizontal: false, vertical: true)   // window height = the TALLER column
            .background(Theme.bgPanel)
            .background(NonRestorableWindow())   // never auto-reopens on the next launch
            .opacity(shortcuts.enabled ? 1 : 0.85)
        case .settingsPane:
            paneSections
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(shortcuts.enabled ? 1 : 0.85)
        }
    }

    // MARK: - LEFT: the fixed set

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            generalSection
            if layout == .window { streamDeckSection.padding(.top, Spacing.md) }
            switcherSection.padding(.top, Spacing.md)
            lensesSection.padding(.top, Spacing.md)
        }
    }

    /// The Settings section: the same sections, each in its own card.
    private var paneSections: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            generalSection.settingsCard()
            switcherSection.settingsCard()
            lensesSection.settingsCard()
            rightColumn.settingsCard()
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
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionLabel("GENERAL")
            switchRow("Enable shortcuts", isOn: $shortcuts.enabled)
            switchRow("Show key hints on buttons", isOn: $shortcuts.showHints)
                .disabled(!shortcuts.enabled)
            switchRow("Work in other apps",
                      subtitle: "Same keys fire while another app is focused",
                      isOn: $shortcuts.global)
                .disabled(!shortcuts.enabled)
            permissionWarning
        }
    }

    /// Independent of the keyboard switches: turning keys off must not take the Stream Deck down
    /// with them.
    private var streamDeckSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionLabel("STREAM DECK")
            switchRow("Allow Stream Deck control",
                      subtitle: "Apps on this Mac can switch cameras",
                      isOn: $control.enabled)
            controlWarning
        }
    }

    // Only the KEY-ASSIGNMENT sections grey out when shortcuts are off.  The disable MUST NOT
    // wrap the GENERAL rows: it used to sit on the whole column, which disabled the very "Enable
    // shortcuts" switch that turns them back on — once off, there was no way back from the UI.

    private var switcherSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                sectionLabel("SWITCHER")
                Spacer()
                // In the ⌘K window it stays where it always was; the Settings section puts it under
                // all the cards instead (see paneSections).
                if layout == .window {
                    Button("Reset All Keys") { bindings.resetAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .help("Reset every key to its default")
                }
            }
            fixedRow(ShortcutAction(kind: .cut, index: 0), title: "Cut")
            fixedRow(ShortcutAction(kind: .autoCut, index: 0), title: "Auto Cut")
        }
        .disabled(!shortcuts.enabled)
    }

    private var lensesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionLabel("LENSES")
            ForEach(0 ..< 6, id: \.self) { i in
                fixedRow(ShortcutAction(kind: .lens, index: i), title: "Lens \(i + 1)")
            }
        }
        .disabled(!shortcuts.enabled)
    }

    /// Left-column row: title flush left, chip flush right.
    private func fixedRow(_ action: ShortcutAction, title: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(title)
                .font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: Spacing.sm)
            BindingChip(shortcuts: shortcuts, bindings: bindings, action: action, width: chipWidth)
        }
        .frame(height: 30)
    }

    // MARK: - RIGHT: per-channel keys (one row = both buses)

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionLabel("CHANNELS")
            if model.channels.isEmpty {
                Text("Add a channel to assign its keys.")
                    .font(.system(size: 12)).foregroundColor(Theme.textFaint)
                    .padding(.top, Spacing.xxs)
            } else {
                // Bus mini-headers, aligned over their chip columns.
                HStack(spacing: Spacing.sm) {
                    Spacer(minLength: Spacing.sm)
                    Text("PREVIEW")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                        .foregroundColor(Theme.textFaint)
                        .frame(width: chipWidth)
                    Text("PROGRAM")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                        .foregroundColor(Theme.textFaint)
                        .frame(width: chipWidth)
                }
                ForEach(Array(model.channels.prefix(9).enumerated()), id: \.element.id) { pair in
                    channelRow(index: pair.offset, name: pair.element.name)
                }
            }
        }
        .disabled(!shortcuts.enabled)
    }

    /// One channel's row: name · [→ Preview chip] · [→ Program chip].
    private func channelRow(index: Int, name: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(name)
                .font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: Spacing.sm)
            BindingChip(shortcuts: shortcuts, bindings: bindings,
                        action: ShortcutAction(kind: .camera, index: index), width: chipWidth)
            BindingChip(shortcuts: shortcuts, bindings: bindings,
                        action: ShortcutAction(kind: .programCut, index: index), width: chipWidth)
        }
        .frame(height: 30)
    }

    // MARK: - Shared bits

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
            .foregroundColor(Theme.textFaint)
    }

    private func switchRow(_ title: String, subtitle: String? = nil,
                           isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13)).foregroundColor(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11)).foregroundColor(Theme.textFaint)
                }
            }
            Spacer(minLength: Spacing.sm)
            SettingsSwitch(isOn: isOn)
        }
    }

    @ViewBuilder
    private var controlWarning: some View {
        if control.enabled, let failure = control.failure {
            ControlFailureLine(text: failure)
        }
    }

    @ViewBuilder
    private var permissionWarning: some View {
        if shortcuts.enabled && shortcuts.global && !shortcuts.hasPermission {
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
        // If the window closes mid-recording, the NSEvent monitor and the
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
