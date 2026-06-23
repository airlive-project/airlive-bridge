// ShortcutSettings.swift — popover from the title-bar key icon.
//
// Enable shortcuts, choose in-app vs global, grant Input Monitoring (only needed
// for global), and a small legend of the bindings.

import SwiftUI

struct ShortcutSettings: View {
    @ObservedObject var shortcuts: ShortcutCenter

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Shortcuts")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            Toggle(isOn: $shortcuts.enabled) {
                Text("Enable shortcuts")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            }
            .toggleStyle(.switch).tint(Theme.accentBlue)

            Toggle(isOn: $shortcuts.global) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Work in other apps")
                        .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    Text("⌃⌥ + key globally (e.g. while focused on OBS)")
                        .font(.system(size: 10)).foregroundColor(Theme.textFaint)
                }
            }
            .toggleStyle(.switch).tint(Theme.accentBlue)
            .disabled(!shortcuts.enabled)

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

            Rectangle().fill(Theme.stroke).frame(height: 1)
            legend
        }
        .padding(Spacing.md)
        .frame(width: 290)
        .background(Theme.bgPanel)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            legendRow(shortcuts.global ? "⌃⌥Space" : "Space", "Cut Preview → Program")
            legendRow(shortcuts.global ? "⌃⌥1–9" : "1–9", "Camera → Program")
            legendRow(shortcuts.global ? "⌃⌥⇧1–6" : "⇧1–6", "Lens (focused camera)")
        }
        .opacity(shortcuts.enabled ? 1 : 0.45)
    }

    private func legendRow(_ key: String, _ desc: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(key)
                .font(.system(size: 11, weight: .semibold).monospaced())
                .foregroundColor(Theme.textPrimary)
                .frame(width: 72, alignment: .leading)
            Text(desc).font(.system(size: 11)).foregroundColor(Theme.textFaint)
            Spacer()
        }
    }
}
