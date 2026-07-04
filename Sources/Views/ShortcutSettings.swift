// ShortcutSettings.swift — the "Shortcuts" window (menu bar → Shortcuts → Customize…, ⌘K).
//
// TWO columns so the window stays a normal height no matter how many channels exist
// (a single stacked list overflowed the screen with no way to scroll):
//   LEFT  — the fixed set: GENERAL switches, SWITCHER (Cut / Remove), LENSES (6).
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
    @ObservedObject var shortcuts: ShortcutCenter
    @ObservedObject var bindings: ShortcutBindings
    @ObservedObject var model: BridgeModel

    /// One shared chip width — every key chip in the window sits on the same grid.
    private let chipWidth: CGFloat = 88
    private let columnWidth: CGFloat = 320

    var body: some View {
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
    }

    // MARK: - LEFT: the fixed set

    private var leftColumn: some View {
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

            HStack {
                sectionLabel("SWITCHER")
                Spacer()
                Button("Reset all") { bindings.resetAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .help("Reset every key to its default")
            }
            .padding(.top, Spacing.md)
            fixedRow(ShortcutAction(kind: .cut, index: 0), title: "Cut")
            fixedRow(ShortcutAction(kind: .removeChannel, index: 0), title: "Remove Selected Channel")

            sectionLabel("LENSES").padding(.top, Spacing.md)
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
            Toggle("", isOn: isOn)
                .toggleStyle(.switch).controlSize(.small).tint(Theme.accentBlue)
                .labelsHidden()
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
        recording = true
        heldModifiers = ""
        shortcuts.isRecording = true   // mute the live engines while capturing
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
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false
        heldModifiers = ""
        shortcuts.isRecording = false
    }
}
