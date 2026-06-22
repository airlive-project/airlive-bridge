// CenterPane.swift — CENTER zone: the selected channel.
//
// Top to bottom, inside one ScrollView so the full control stack fits any window
// size without overflow: the 16:9 preview (tally border + ON AIR / PREVIEW badge
// + hide-preview eye), the Tally row (Off / Preview / Program — sends `setCue`),
// the Output-delay row (LatencyPreset), then the camera CONTROL panel
// (CameraControlPanel).  Everything here drives one channel; when no channel is
// selected it shows a quiet empty state.
//
// Tally and Output-delay use the kit `SegmentedBar` so their segments are EQUAL
// width and aligned (the old native `.segmented` Picker rendered crooked).
//
// Readback vs control: value labels come from `channel.remote` (the camera's
// reported StateSnapshot); every knob sends a `ControlMessage` via
// `channel.send(_:)`.  The two are deliberately separate — the operator turns a
// knob, the command goes to the iPhone, and the iPhone's next snapshot confirms
// the new value back into the labels.

import SwiftUI

struct CenterPane: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        Group {
            if let channel = model.selectedChannel {
                ChannelDetail(channel: channel)
                    // Re-create the detail subtree per channel so its local
                    // @State (preview pane sizing, slider drafts) resets cleanly
                    // when the selection changes.
                    .id(channel.id)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgApp)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundColor(Theme.textFaint)
            Text("No channel selected")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("Create or select a channel on the left.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textFaint)
        }
    }
}

// MARK: - One channel's detail

private struct ChannelDetail: View {
    @ObservedObject var channel: BridgeChannel
    @ObservedObject private var tally = TallyStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                previewSection
                tallyRow
                delayRow
                // Camera control commands the iPhone — pointless (and a source of
                // stale-state bugs) with no camera attached.  Dim + disable it
                // until connected; it lights up the moment the phone joins.
                CameraControlPanel(channel: channel)
                    .disabled(!channel.isConnected)
                    .opacity(channel.isConnected ? 1.0 : 0.4)
            }
            // Tight top padding; generous-but-compact around the rest.  The
            // ScrollView lets the stack grow past the window without overflow.
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xl)
        }
    }

    // MARK: Preview

    /// The camera reports a clockwise rotation hint (Option B vertical stream);
    /// 90/270 means the operator is shooting portrait, so the preview goes 9:16.
    private var isPortrait: Bool {
        let r = channel.remote?.outputRotation ?? 0
        return r == 90 || r == 270
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                SectionLabel(text: channel.name)
                Spacer()
                hidePreviewToggle
            }
            previewPane
        }
    }

    private var hidePreviewToggle: some View {
        Button {
            channel.previewEnabled.toggle()
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: channel.previewEnabled ? "eye" : "eye.slash")
                    .font(.system(size: 11))
                Text(channel.previewEnabled ? "Hide preview" : "Show preview")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: 26)
        }
        .bridgeButton(selected: !channel.previewEnabled)
        .help("Stop rendering this preview to save GPU/CPU while it isn't being watched.")
    }

    private var previewPane: some View {
        ZStack {
            if channel.previewEnabled {
                PreviewView(channel: channel)
                if channel.latestFrame == nil {
                    noSignalOverlay
                }
            } else {
                hiddenPlaceholder
            }
            tallyBadge
        }
        // Adapt to the camera's orientation: a vertical (Option B) stream reports
        // a 90/270 rotation, so the pane itself becomes 9:16 and the portrait
        // frame fills it instead of letterboxing inside a wide 16:9 box.
        .aspectRatio(isPortrait ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .stroke(tallyBorderColor, lineWidth: tallyBorderWidth)
        )
    }

    private var noSignalOverlay: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: channel.isConnected ? "hourglass" : "wifi.slash")
                .font(.system(size: 26))
                .foregroundColor(Theme.textFaint)
            Text(channel.isConnected ? "Connected — waiting for video"
                                     : "Waiting for camera to connect")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var hiddenPlaceholder: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "eye.slash")
                .font(.system(size: 26))
                .foregroundColor(Theme.textFaint)
            Text("Preview hidden — saving GPU")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("Frames are still received and published downstream.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPanel)
    }

    // MARK: Tally badge / border

    private var currentTally: TallyState { tally.state(for: channel.id) }

    @ViewBuilder
    private var tallyBadge: some View {
        if currentTally != .off {
            VStack {
                HStack {
                    HStack(spacing: Spacing.xs) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 6, height: 6)
                        Text(currentTally == .program ? "ON AIR" : "PREVIEW")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.5)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(
                        Capsule(style: .continuous).fill(currentTally.accent)
                    )
                    Spacer()
                }
                Spacer()
            }
            .padding(Spacing.md)
        }
    }

    private var tallyBorderColor: Color {
        currentTally == .off ? Theme.stroke : currentTally.accent
    }

    private var tallyBorderWidth: CGFloat {
        currentTally == .off ? 1 : 3
    }

    // MARK: Tally (equal-width segmented bar)

    private var tallyRow: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionLabel(text: "Tally")
                SegmentedBar(
                    selection: Binding(
                        get: { currentTally },
                        set: { setTally($0) }
                    ),
                    options: TallyState.allCases,
                    label: { $0.label },
                    // Program red, Preview yellow, Off neutral blue.
                    accent: { $0 == .off ? Theme.accentBlue : $0.accent }
                )
            }
        }
    }

    /// Record the cue locally (so both surfaces agree) and ship it to the iPhone.
    private func setTally(_ state: TallyState) {
        tally.set(state, for: channel.id)
        channel.send(.setCue(state.rawValue))
    }

    // MARK: Output delay (equal-width segmented bar)

    private var delayRow: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionLabel(text: "Output delay (ms)")
                SegmentedBar(
                    selection: Binding(
                        get: { channel.delay },
                        set: { channel.delay = $0 }
                    ),
                    options: LatencyPreset.allCases,
                    // The +ms value is the point of this control — show it next to
                    // the name on each segment (the unit rides in the section label).
                    label: { delayShortLabel($0) }
                )
            }
        }
    }

    /// Compact, segment-friendly label for a latency preset (the full label is
    /// long; equal segments need a tight string).
    private func delayShortLabel(_ preset: LatencyPreset) -> String {
        switch preset {
        case .lowest: return "Lowest +0"
        case .normal: return "Normal +120"
        case .smooth: return "Smooth +200"
        case .safe:   return "Safe +400"
        }
    }
}

// (Security moved to a single GLOBAL control in the Channels rail footer —
// see SecurityFooter in ChannelsRail.swift. One password gates every channel.)
