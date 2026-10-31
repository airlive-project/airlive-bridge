// SettingsWindow.swift - the Bridge-wide settings window: its frame, section list and action bar,
// and the small pieces every pane is built from. The panes themselves are in SettingsPanes.swift.
// Shown as an app-modal window by SettingsPresenter.
//
// A list of sections on the left, the chosen section on the right (operator design, 2026-10-05).
// It holds only what belongs to the whole Bridge. A setting of one camera or one output stays in
// that item's row in the rails (operator, 2026-10-06): it lives beside the thing it changes.
//
// Like OBS's settings: most changes are held in `SettingsDraft` until Apply, and Cancel drops them
// (SettingsDraft lists the few that act at once). The values themselves are the SAME state the
// rails and the AUTO panel use, so once applied a change shows everywhere,
// and every existing way in keeps working as before.
//
// No `Dropdown` / `MenuButton` in this window. Their list is drawn by the one `DropdownOverlay` in
// the main window, and a second overlay on the shared presenter swallows clicks across windows (see
// AirliveBridgeApp). A choice here is a row of chips, which also shows every option at once.

import SwiftUI
import Sparkle

/// The sections, in sidebar order.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, cameras, multiview, outputs, autoCut, integrations, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:      return "General"
        case .cameras:      return "Cameras"
        case .multiview:    return "Multiview"
        case .outputs:      return "Outputs"
        case .autoCut:      return "Auto Cut"
        case .integrations: return "Integrations"
        case .shortcuts:    return "Shortcuts"
        }
    }

    var icon: String {
        switch self {
        case .general:      return "gearshape"
        case .cameras:      return "video"
        case .multiview:    return "rectangle.split.2x2"
        case .outputs:      return "dot.radiowaves.left.and.right"
        case .autoCut:      return "shuffle"
        case .integrations: return "puzzlepiece.extension"
        case .shortcuts:    return "keyboard"
        }
    }
}

struct SettingsWindow: View {
    @ObservedObject var model: BridgeModel
    @ObservedObject var shortcuts: ShortcutCenter
    @ObservedObject var control: ControlServer
    let updater: SPUUpdater
    /// Owned by SettingsPresenter, so the close button and Check for Updates can ask about it.
    @ObservedObject var draft: SettingsDraft

    /// Remembered, so the window reopens where the operator left it.
    static let sectionKey = "settings.section"
    @AppStorage(SettingsWindow.sectionKey) private var section: SettingsSection = .general

    /// Fixed size: room for the widest pane (the Auto Cut timers) and the Shortcuts cards.
    private static let size = CGSize(width: 720, height: 520)
    private static let sidebarWidth: CGFloat = 190
    /// One fixed width for both bar buttons, so "Cancel" turning into "Close" moves nothing.
    private static let barButtonWidth: CGFloat = 80

    // Layered like the main window and like OBS's settings: the window's background, two panels on
    // it (the section list and the open section), and each group of settings inside the panel.
    // No full-length divider lines: the panels' own edges separate the parts.
    var body: some View {
        VStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                sidebar
                ScrollView {
                    pane
                        .padding(Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .settingsPanel()
            }
            actionBar
        }
        // Tight under the title bar: the bar already ends in its own margin (operator, 2026-10-07).
        .padding([.horizontal, .bottom], Spacing.md)
        .padding(.top, Spacing.xxs)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.bgApp)
    }

    // MARK: - Cancel / Apply (OBS's bar, without OK - operator, 2026-10-07)

    private var actionBar: some View {
        HStack(spacing: Spacing.xs) {
            Spacer()
            // "Cancel" while there is something to throw away, "Close" once everything is applied -
            // a Cancel after Apply read as if it would undo the Apply (operator, 2026-10-07).
            Button { SettingsPresenter.shared.discardAndClose() } label: {
                barLabel(draft.hasChanges ? "Cancel" : "Close", color: Theme.textPrimary)
            }
            .bridgeButton()

            // Blue only when there is something to apply; a disabled blue read as a broken button.
            Button { draft.apply(model: model) } label: {
                barLabel("Apply", color: draft.canApply ? .white : Theme.textFaint)
            }
            .bridgeButton(selected: draft.canApply)
            .disabled(!draft.canApply)
        }
    }

    /// The whole button takes the click, not just its word.
    private func barLabel(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundColor(color)
            .frame(width: Self.barButtonWidth, height: ControlMetrics.pillHeight)
            .contentShape(Rectangle())
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(SettingsSection.allCases) { item in
                SidebarRow(item: item, selected: item == section,
                           // Apply is held back by an invalid range here; say where, on every pane.
                           flagged: item == .autoCut && draft.autoCut?.isValid == false) { section = item }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.sm)
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .settingsPanel()
    }

    // MARK: - Panes

    @ViewBuilder private var pane: some View {
        switch section {
        case .general:      GeneralPane(updater: updater)
        case .cameras:      CamerasPane(model: model)
        case .multiview:    MultiviewPane(draft: draft)
        case .outputs:      OutputsPane(model: model, recorder: model.programRecorder, draft: draft)
        case .autoCut:      AutoCutPane(auto: model.autoSwitcher, draft: draft)
        case .integrations: IntegrationsPane(control: control)
        case .shortcuts:
            VStack(alignment: .leading, spacing: 0) {
                PaneHeader(title: "Shortcuts")
                ShortcutSettings(shortcuts: shortcuts, bindings: shortcuts.bindings, model: model)
            }
        }
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let item: SettingsSection
    let selected: Bool
    var flagged = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: item.icon)
                    .font(.system(size: 12))
                    .foregroundColor(selected ? Theme.accentBlue : nil)
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
                if flagged {
                    Circle().fill(Theme.accentRed).frame(width: 6, height: 6)
                }
            }
            .foregroundColor(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .frame(height: ControlMetrics.segmentHeight)
            .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                            .fill(selected ? Theme.bgSelected : (hovering ? Theme.bgHover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Pieces the panes are built from

extension View {
    /// The two big panels on the window background: the rails' fill, edge and radius.
    fileprivate func settingsPanel() -> some View {
        frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).fill(Theme.bgRail))
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1))
    }

    /// Anything in a group's box that is not a `SettingsRow` (a row of chips, the Auto Cut timers):
    /// the same height and padding as a row, so the hairlines between them fall evenly.
    func settingsCell() -> some View {
        padding(.vertical, SettingsMetric.rowPadding)
            .frame(maxWidth: .infinity, minHeight: SettingsMetric.rowHeight, alignment: .leading)
    }
}

/// The grouped-form measures, as in the system's own settings window: a group title in the body
/// font above a rounded box that hugs its rows and fills the width, rows split by inset hairlines
/// (operator, 2026-10-31: the caps micro-labels on a bare panel read as messy).
enum SettingsMetric {
    static let rowHeight: CGFloat = 40      // a row with a switch or a button, like the system's
    static let rowPadding: CGFloat = 8
    static let boxInset: CGFloat = 12       // row content and hairlines start here
}

/// A pane's title, and an optional line under it.
struct PaneHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textFaint)
            }
        }
        .padding(.bottom, Spacing.md)
    }
}

/// A group: its title, a box holding its rows (put a `SettingsDivider` between two rows), and an
/// optional note under the box. Every pane is built from these, Shortcuts included.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                // Flush with the box's edge, on the pane title's line: a pane can mix boxed groups
                // with unboxed ones (the frame guide), and an inset title there gave two left
                // edges (operator, 2026-10-31).
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, SettingsMetric.boxInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                                .fill(Theme.bgPanel))
                .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1))
            if let footer {
                SettingsNote(text: footer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Spacing.xl)
    }
}

/// The hairline between two rows of a group's box, inset like the rows' content.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1)
    }
}

/// The row's title line: the control is centred on the TITLE, not on title + the lines under it
/// (operator, 2026-10-31: the title is the row, the note is extra) - as in the system's settings.
extension VerticalAlignment {
    private enum SettingsTitle: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let settingsTitle = VerticalAlignment(SettingsTitle.self)
}

/// A row: title on the left, the control on the right. Under the title either a `subtitle` (a
/// value: a path, a port, a device name) or a `note` (what the setting does, with the ⓘ mark).
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    var note: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .settingsTitle, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textPrimary)
                    .alignmentGuide(.settingsTitle) { $0[VerticalAlignment.center] }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note { SettingsNote(text: note) }
            }
            Spacer(minLength: Spacing.sm)
            control
        }
        .settingsCell()
    }
}

/// A short explanation, written out under its title the way the system's settings do (no popover
/// to open). The ⓘ mark is part of the TEXT, so a second line starts under the mark, not under the
/// first word (operator, 2026-10-31).
struct SettingsNote: View {
    let text: String

    var body: some View {
        (Text(Image(systemName: "info.circle")) + Text(" " + text))
            .font(.system(size: 11))
            .foregroundColor(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The on/off switch every settings row uses.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch).controlSize(.small).tint(Theme.accentBlue)
            .labelsHidden()
    }
}

/// Why the Stream Deck control channel is not listening, under its switch in Integrations.
struct ControlFailureLine: View {
    let text: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundColor(Theme.accentYellow)
            Text(text)
                .font(.system(size: 12)).foregroundColor(Theme.accentYellow)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Bridge's standard button, padded for a settings row.
struct RowButton: View {
    let title: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(destructive ? Theme.accentRed : Theme.textPrimary)
                .padding(.horizontal, Spacing.md)
                .frame(height: 26)   // a step below the row, so the button sits inside it
        }
        .bridgeButton()
    }
}

/// One row of equal chips, the selected one filled - the window's single-choice control (see the
/// file header for why not a dropdown).
struct ChoiceChips<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: KeyPath<Option, String>

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(option[keyPath: title])
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: ControlMetrics.pillHeight)
                }
                .bridgeButton(selected: option == selection, corner: Radius.control)
            }
        }
    }
}
