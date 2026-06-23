// ShortcutSettings.swift — popover from the title-bar key icon.
//
// Enable shortcuts, choose in-app vs global, grant Input Monitoring (global only),
// and REASSIGN each action's key.  Click a key chip to record a new key (Esc to
// cancel); the global ⌃⌥ prefix is shown but fixed (it's the activator that keeps
// global hotkeys from hijacking plain typing in other apps).

import SwiftUI
import AppKit

struct ShortcutSettings: View {
    @ObservedObject var shortcuts: ShortcutCenter
    @ObservedObject var bindings: ShortcutBindings

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            toggles
            permissionWarning
            Rectangle().fill(Theme.stroke).frame(height: 1)
            bindingList
        }
        .padding(Spacing.md)
        .frame(width: 320)
        .background(Theme.bgPanel)
    }

    private var header: some View {
        HStack {
            Text("Shortcuts")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button("Reset all") { bindings.resetAll() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Toggle(isOn: $shortcuts.enabled) {
                Text("Enable shortcuts")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            }
            .toggleStyle(.switch).tint(Theme.accentBlue)

            Toggle(isOn: $shortcuts.global) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Work in other apps")
                        .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    Text("Adds ⌃⌥ to every key globally (e.g. while focused on OBS)")
                        .font(.system(size: 10)).foregroundColor(Theme.textFaint)
                }
            }
            .toggleStyle(.switch).tint(Theme.accentBlue)
            .disabled(!shortcuts.enabled)
        }
    }

    @ViewBuilder
    private var permissionWarning: some View {
        if shortcuts.enabled && shortcuts.global && !shortcuts.hasPermission {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundColor(Theme.accentYellow)
                Text("Needs Input Monitoring")
                    .font(.system(size: 11)).foregroundColor(Theme.accentYellow)
                Spacer()
                Button("Grant…") { shortcuts.requestPermission() }
                    .bridgeButton(selected: true)
                    .frame(height: 26)
            }
        }
    }

    // MARK: - Reassignable list

    private var bindingList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                rows(for: .cut, title: nil)
                rows(for: .camera, title: "CAMERAS")
                rows(for: .lens, title: "LENSES")
            }
        }
        .frame(maxHeight: 300)
        .opacity(shortcuts.enabled ? 1 : 0.45)
        .disabled(!shortcuts.enabled)
    }

    @ViewBuilder
    private func rows(for kind: ShortcutAction.Kind, title: String?) -> some View {
        if let title {
            Text(title)
                .font(.system(size: 9, weight: .bold)).tracking(0.6)
                .foregroundColor(Theme.textFaint)
                .padding(.top, Spacing.xs)
        }
        ForEach(ShortcutAction.all.filter { $0.kind == kind }) { action in
            BindingRow(shortcuts: shortcuts, bindings: bindings, action: action,
                       global: shortcuts.global)
        }
    }
}

/// One action's row: title · (recordable) key chip · reset.
private struct BindingRow: View {
    let shortcuts: ShortcutCenter
    @ObservedObject var bindings: ShortcutBindings
    let action: ShortcutAction
    let global: Bool

    @State private var recording = false
    @State private var monitor: Any?
    @State private var conflict: String?

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(action.title)
                .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                .frame(width: 78, alignment: .leading)

            if let conflict {
                Text(conflict).font(.system(size: 10)).foregroundColor(Theme.accentRed)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: Spacing.xs)

            Button { recording ? cancel() : start() } label: {
                Text(recording ? "Press a key…" : chipLabel)
                    .font(.system(size: 11, weight: .semibold).monospaced())
                    .frame(minWidth: 64, minHeight: 24)
                    .padding(.horizontal, Spacing.sm)
            }
            .bridgeButton(selected: recording)

            Button { bindings.reset(action); conflict = nil } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.textFaint)
            .opacity(bindings.isCustomized(action) ? 1 : 0)
            .disabled(!bindings.isCustomized(action))
            .help("Reset to default")
        }
        // If the popover is dismissed mid-recording, the NSEvent monitor and the
        // isRecording mute would leak forever — release them when the row goes away.
        .onDisappear { if recording { finish() } }
    }

    /// What the chip shows: the base chord, with the ⌃⌥ prefix in global mode.
    private var chipLabel: String {
        (global ? "⌃⌥" : "") + bindings.chord(for: action).display
    }

    private func start() {
        recording = true
        shortcuts.isRecording = true   // mute the live engines while capturing
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {                       // Esc cancels
                self.finish(); return nil
            }
            let chord = KeyChord(event: event)
            if let clash = self.bindings.set(chord, for: self.action) {
                self.conflict = "= \(clash.title)"         // refused; show the clash
            } else {
                self.conflict = nil
            }
            self.finish()
            return nil                                     // swallow the captured key
        }
    }

    private func cancel() { finish() }

    private func finish() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false
        shortcuts.isRecording = false
    }
}
