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
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bgApp)
    }

    @ViewBuilder
    private var content: some View {
        if model.mode == .multiview {
            MultiviewGrid(model: model)
        } else if let channel = model.selectedChannel {
            ChannelDetail(channel: channel)
                // Re-create the detail subtree per channel so its local @State
                // (preview pane sizing, slider drafts) resets cleanly on change.
                .id(channel.id)
        } else {
            emptyState
        }
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
                // Camera control.  For a Screen-Mirroring tile this leads with the
                // "Remote control" dropdown (attach an Airlive connection); for a normal
                // channel it's the control panel directly.  Dim/disabled-until-connected +
                // operator-revoked disclosure live inside CameraControlSection.
                CameraControlSection(channel: channel, showLens: true)
            }
            // Tight top padding; generous-but-compact around the rest.  The
            // ScrollView lets the stack grow past the window without overflow.
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xl)
        }
    }

    // MARK: Preview

    /// Hard ceiling on the preview viewport height.  The detail stack lives in a
    /// vertical ScrollView, which offers UNBOUNDED height — without this cap a tall
    /// (portrait) or oddly-shaped source makes `height = width / aspect` balloon and
    /// pushes the layout off-screen.  Width still fills; the video aspect-fits inside.
    private let maxPreviewHeight: CGFloat = 460

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    SectionLabel(text: channel.name)
                    // Camera-side operator name (Settings → Live), when reported.
                    if !channel.cameraDeviceName.isEmpty {
                        Text(channel.cameraDeviceName)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textFaint)
                    }
                }
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
        // Video in an OVERLAY over a sized black Rectangle — same robust pattern as the
        // multiview LivePane (Studio's VideoRegion).  The overlay inherits the Rectangle's
        // size so the hosted layer always fills; a bare ZStack would collapse to the
        // NSView's tiny intrinsic size.
        Rectangle()
            .fill(Color.black)
            .overlay {
                ZStack {
                    // ⚠️ Key off camera-CONFIRMED videoActive, never a requested mode.
                    if !channel.videoActive {
                        controlOnlyOverlay
                    } else if channel.previewEnabled {
                        MirrorVideoView(channel: channel)
                        if channel.latestFrame == nil { noSignalOverlay }
                    } else {
                        hiddenPlaceholder
                    }
                    tallyBadge
                }
            }
            // Keep the live source's real shape (AirPlay portrait / Airlive landscape /
            // Option-B 9:16) but BOUND it: fill the width, cap the height at
            // `maxPreviewHeight` so the viewport can never overflow the scrolling stack.
            .aspectRatio(CGFloat(channel.displayAspect), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: maxPreviewHeight)
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                    .stroke(tallyBorderColor, lineWidth: tallyBorderWidth)
            )
    }

    private var noSignalOverlay: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: channel.anyConnected ? "hourglass" : "wifi.slash")
                .font(.system(size: 26))
                .foregroundColor(Theme.textFaint)
            Text(channel.anyConnected ? "Connected — waiting for video"
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

    /// Camera confirmed Control-only (encoder off): no Airlive video on this link —
    /// not a frozen frame, not a disconnect.  Video, if any, arrives via AirPlay.
    private var controlOnlyOverlay: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "video.slash")
                .font(.system(size: 26))
                .foregroundColor(Theme.textFaint)
            Text("CONTROL ONLY — no Airlive video")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("Encoder off; remote control + tally only.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // Hidden when the phone operator turned their tally light OFF — the camera ignores
    // cues, so don't offer a control that does nothing (disclosure, like the W1 invariant).
    @ViewBuilder
    private var tallyRow: some View {
        if channel.tallyAllowed {
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
    }

    /// Record the cue locally (so both surfaces agree) and ship it to the iPhone.
    private func setTally(_ state: TallyState) {
        tally.set(state, for: channel.id)
        channel.send(.setCue(state.rawValue))
    }
}

// (Security moved to a single GLOBAL control in the Channels rail footer —
// see SecurityFooter in ChannelsRail.swift. One password gates every channel.)
