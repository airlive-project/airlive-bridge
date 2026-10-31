// SettingsPanes.swift - the sections of the Settings window, one view each. The window's frame and
// the pieces these are built from (PaneHeader, SettingsGroup, SettingsRow...) are in
// SettingsWindow.swift; which settings wait for Apply is decided in SettingsDraft.

import SwiftUI
import Sparkle

// MARK: - General

struct GeneralPane: View {
    let updater: SPUUpdater
    @StateObject private var updates: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        self.updater = updater
        _updates = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "General")
            // Label left, value or control right, one fact per row - no explanations (operator,
            // 2026-10-07).
            SettingsGroup(title: "Airlive Bridge") {
                SettingsRow(title: "Version") {
                    Text(version)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundColor(Theme.textSecondary)
                }
                SettingsDivider()
                SettingsRow(title: "Updates") {
                    RowButton(title: "Check for Updates…") { checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
            }
        }
    }

    /// Settings first, then the check: while this window is modal, the updater's own window would
    /// open but take no clicks until Settings closed (review, 2026-10-07). Leaving asks about
    /// unapplied changes first.
    private func checkForUpdates() {
        SettingsPresenter.shared.leave { updater.checkForUpdates() }
    }
}

// MARK: - Cameras

/// The latency buffer acts at once, exactly like the rail's row: it is raised on air when a camera
/// starts stuttering (operator, 2026-10-07), so it does not wait for Apply.
struct CamerasPane: View {
    @ObservedObject var model: BridgeModel
    /// The SAME key as the lock on the Channels rail footer: one lock, two places to see it.
    @AppStorage(SettingsDraft.latencyLockKey) private var locked = false
    @State private var showPasswordSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Cameras")
            SettingsGroup(title: "Latency buffer") {
                latencyHeader
                SettingsDivider()
                latencyChips
            }
            SettingsGroup(title: "Security") {
                SettingsRow(title: "Airlive receiver password",
                            note: model.hasPassword
                                ? "Set. An Airlive Camera enters it to connect."
                                : "Not set. Any Airlive Camera on this network can connect.") {
                    RowButton(title: model.hasPassword ? "Change…" : "Set…") { showPasswordSheet = true }
                }
            }
        }
        .sheet(isPresented: $showPasswordSheet) {
            PasswordSheet(model: model, isPresented: $showPasswordSheet)
        }
    }

    private var latencyHeader: some View {
        SettingsRow(title: "Every camera channel", note: LatencyPreset.explainer) {
            Button { locked.toggle() } label: {
                Image(systemName: locked ? "lock.fill" : "lock.open")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(locked ? "Unlock to change" : "Lock so it can't be changed by accident")
        }
    }

    /// All five rungs at once, name over figure, the way the rail's list shows them.
    private var latencyChips: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(LatencyPreset.allCases) { preset in
                let isOn = preset == model.latencyBuffer
                Button { model.latencyBuffer = preset } label: {
                    VStack(spacing: 2) {
                        Text(preset.name)
                            .font(.system(size: 11, weight: .medium))
                        Text("\(preset.ms) ms")
                            .font(.system(size: 10).monospacedDigit())
                            .opacity(isOn ? 0.85 : 0.6)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: ControlMetrics.tileHeight)
                }
                .bridgeButton(selected: isOn, corner: Radius.control)
            }
        }
        .opacity(locked ? 0.4 : 1)
        .disabled(locked)
        .settingsCell()
    }
}

// MARK: - Multiview

/// How the multiview behaves for the director: what a click does, and the frame guide over
/// Preview and Program. Its own section because a multiview setting is not where anyone looks for
/// it under General (operator, 2026-10-07), and more are coming.
struct MultiviewPane: View {
    @ObservedObject var draft: SettingsDraft
    @AppStorage(SettingsDraft.previewClickCutsKey) private var storedPreviewClickCuts = true
    @AppStorage(FrameGuide.storageKey) private var storedGuide: FrameGuide = .off
    @AppStorage(FrameGuideStyle.storageKey) private var storedStyle: FrameGuideStyle = .solid

    var body: some View {
        let guide = draft.binding(\.frameGuide, stored: storedGuide)
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Multiview")
            SettingsGroup(title: "Cameras") {
                SettingsRow(title: "Click a camera in Preview to cut it to Program") {
                    SettingsSwitch(isOn: draft.binding(\.previewClickCuts, stored: storedPreviewClickCuts))
                }
            }
            frameGuidePicker(guide: guide)
        }
    }

    /// The operator's layout (Figma, 2026-10-31): ratios down the left, the sample in the middle,
    /// styles down the right - both columns exactly as tall as the sample. No box.
    private func frameGuidePicker(guide: Binding<FrameGuide>) -> some View {
        let style = draft.binding(\.frameGuideStyle, stored: storedStyle)
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Monitoring frame guide")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            // Above the choices: read BEFORE clicking on air, not found below the fold.
            SettingsNote(text: "Outputs and recordings stay clean.")
            HStack(alignment: .top, spacing: Spacing.md) {
                labelled("Frames") {
                    pickColumn(FrameGuide.allCases, selection: guide, label: \.label)
                }
                .frame(width: Self.pickColumnWidth)
                labelled("Preview & Program view", centered: true) {
                    FrameGuideSample(guide: guide.wrappedValue, style: style.wrappedValue)
                }
                labelled("Display mode") {
                    pickColumn(FrameGuideStyle.allCases, selection: style, label: \.title)
                }
                .frame(width: Self.pickColumnWidth)
                .opacity(guide.wrappedValue == .off ? 0.4 : 1)
                .disabled(guide.wrappedValue == .off)
            }
            // The sample's height sets the row; the columns' buttons then stretch to fill it.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Spacing.xxs)
        }
        .padding(.bottom, Spacing.xl)
    }

    /// Width of each side column: room for "2.35:1" and "Display mode" with air.
    private static let pickColumnWidth: CGFloat = 80

    /// A column's small caption over it, then the column filling the rest of the row's height.
    private func labelled<Content: View>(_ title: String, centered: Bool = false,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Theme.textFaint)
                .lineLimit(1)
            content()
        }
    }

    /// A column of equal buttons sharing the row's height, the selected one filled.
    private func pickColumn<Option: Hashable>(_ options: [Option], selection: Binding<Option>,
                                              label: KeyPath<Option, String>) -> some View {
        VStack(spacing: Spacing.xs) {
            ForEach(options, id: \.self) { option in
                Button { selection.wrappedValue = option } label: {
                    Text(option[keyPath: label])
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .bridgeButton(selected: option == selection.wrappedValue, corner: Radius.control)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Outputs

/// One row per program output with its resolution. The virtual camera's can be a choice (1080p /
/// 1440p / 4K, VirtualCameraResolution), parked at 1080p for now (`isSelectable`); every other
/// output sends the 1080p program as it is.
struct OutputsPane: View {
    @ObservedObject var model: BridgeModel
    @ObservedObject var recorder: ProgramRecorder
    @ObservedObject var draft: SettingsDraft
    @AppStorage(VirtualCameraResolution.storageKey) private var storedVcam: VirtualCameraResolution = .hd1080

    /// The line under an output's name: what it is called or where it goes OUTSIDE the Bridge,
    /// never its own name or kind a second time (operator, 2026-10-07).
    static func reach(of output: VideoOutput) -> String? {
        switch output.kind {
        case .vcam: return kVCamDeviceName                       // the name camera lists show
        case .hdmi: return HDMIOutput.resolveScreen(output.config)?.localizedName ?? "No display"
        case .srt:  return output.config.isEmpty ? nil : output.config
        case .rtsp: return "Port \((output as? RTSPOutput)?.port ?? RTSPOutput.defaultPort)"
        case .ndi:
            // The label IS the name receivers see; only the kind is new information.
            return output.label == output.kind.displayName ? nil : output.kind.displayName
        }
    }

    var body: some View {
        let folder = draft.binding(\.recordFolder, stored: recorder.folder)
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Outputs")
            SettingsGroup(title: "Output resolution") {
                if model.programOutputs.isEmpty {
                    Text("No outputs yet.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textFaint)
                        .settingsCell()
                }
                ForEach(model.programOutputs, id: \.id) { output in
                    if output.id != model.programOutputs.first?.id { SettingsDivider() }
                    SettingsRow(title: output.label.isEmpty ? output.kind.displayName : output.label,
                                subtitle: Self.reach(of: output)) {
                        if output.kind == .vcam && VirtualCameraResolution.isSelectable {
                            ChoiceChips(options: VirtualCameraResolution.allCases,
                                        selection: draft.binding(\.vcamResolution, stored: storedVcam),
                                        title: \.title)
                                .frame(width: 210)
                        } else {
                            Text("1080p")
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }
            }
            // The same folder as the rail's folder button, through Apply like the rest.
            SettingsGroup(title: "Recording") {
                SettingsRow(title: "Save recordings to",
                            subtitle: (folder.wrappedValue.path as NSString).abbreviatingWithTildeInPath) {
                    RowButton(title: "Choose…") {
                        if let url = RecordingFolderPicker.choose(startingAt: folder.wrappedValue) {
                            folder.wrappedValue = url
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Auto Cut

/// The same FROM / TO timers as the AUTO panel (AutoCutRangeEditor). The range waits for Apply.
struct AutoCutPane: View {
    let auto: AutoSwitcher
    @ObservedObject var draft: SettingsDraft

    var body: some View {
        let range = draft.binding(\.autoCut,
                                  stored: .init(lo: auto.minSeconds, hi: auto.maxSeconds))
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Auto Cut", subtitle: "Needs 2+ connected cameras.")
            // No box here (operator, 2026-10-31): the timers are already framed, a box around them
            // is a box in a box.
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Hold each camera between")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textPrimary)
                AutoCutRangeEditor(lo: range.lo, hi: range.hi)
                // The same line as the top-bar popover: the hint, replaced by the error while wrong.
                let wrong = !range.wrappedValue.isValid
                Text(wrong ? "The second value cannot be smaller than the first."
                           : "A fresh random value inside the range before every cut.")
                    .font(.system(size: 11))
                    .foregroundColor(wrong ? Theme.accentRed : Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Integrations

/// Third-party control surfaces and apps, one group each (operator, 2026-10-07: a section per
/// product would not scale). Stream Deck is the first; Companion, MIDI and the like join here.
struct IntegrationsPane: View {
    /// The switch acts at once, not on Apply (operator, 2026-10-07).
    @ObservedObject var control: ControlServer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Integrations")
            SettingsGroup(title: "Stream Deck") {
                SettingsRow(title: "Allow Stream Deck control",
                            note: "Apps on this Mac can switch cameras.") {
                    SettingsSwitch(isOn: $control.enabled)
                }
                if control.enabled, let failure = control.failure {
                    SettingsDivider()
                    ControlFailureLine(text: failure).settingsCell()
                }
            }
        }
    }
}
