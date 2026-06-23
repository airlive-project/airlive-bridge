// MultiviewGrid.swift — the Multiview switcher monitor.
//
// Broadcast-style layout (like a vMix / ATEM multiview):
//   • TWO big 16:9 windows on top — PREVIEW (staged) and PROGRAM (on air).
//   • Below, the cameras as 16:9 thumbnails in rows of FOUR; the row grows a
//     whole 4-up at a time (1–4 cams = one row, 5–8 = two rows, …), empty slots
//     dark.
//
// All of this is pure layout of the channels' live frames — each MirrorVideoView
// points its own CALayer at the channel's latest decoded buffer, so a camera shows
// live in its thumbnail AND (when staged / live) in the big Preview / Program
// window at the same time, with zero extra decodes.  No compositing here; the
// composited PROGRAM buffer that goes to NDI/SRT/RTSP is Phase 2.
//
// Interaction: click a thumbnail to STAGE it in Preview; "CUT" (or double-click a
// thumbnail) sends it live to Program.

import SwiftUI

struct MultiviewGrid: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.md) {
                bigRow
                cutBar
                thumbnails
            }
            .padding(Spacing.lg)
        }
    }

    // MARK: Preview + Program (the two big windows)

    private var bigRow: some View {
        HStack(spacing: Spacing.md) {
            BigPane(title: "PREVIEW", accent: Theme.accentBlue, channel: model.previewChannel())
            BigPane(title: "PROGRAM", accent: Theme.accentRed, channel: model.programChannel())
        }
    }

    private var cutBar: some View {
        HStack {
            Spacer()
            Button { model.take() } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("CUT  →  PROGRAM").font(.system(size: 13, weight: .bold))
                }
                .frame(width: 240, height: 40)
            }
            .bridgeButton(selected: model.previewChannel() != nil, accent: Theme.accentRed)
            .disabled(model.previewChannel() == nil)
            .opacity(model.previewChannel() == nil ? 0.5 : 1)
            Spacer()
        }
    }

    // MARK: Camera thumbnails (rows of 4)

    private var thumbnails: some View {
        let count = model.channels.count
        let capacity = max(1, (count + 3) / 4) * 4   // whole rows of 4
        let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 4)
        return LazyVGrid(columns: columns, spacing: Spacing.sm) {
            ForEach(0 ..< capacity, id: \.self) { index in
                if index < count {
                    let channel = model.channels[index]
                    ThumbCell(channel: channel,
                              isProgram: channel.id == model.programID,
                              isPreview: channel.id == model.previewID,
                              onStage: { model.stage(channel.id) },
                              onTake: { model.stage(channel.id); model.take() })
                } else {
                    emptyThumb
                }
            }
        }
    }

    private var emptyThumb: some View {
        RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
            .fill(Color.black)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
            .overlay(
                Image(systemName: "plus").font(.system(size: 13))
                    .foregroundColor(Theme.textFaint.opacity(0.3))
            )
    }
}

// MARK: - Big Preview / Program window

private struct BigPane: View {
    let title: String
    let accent: Color
    let channel: BridgeChannel?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let channel {
                    LivePane(channel: channel)
                } else {
                    placeholder
                }
            }
            label
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .stroke(accent, lineWidth: 2.5)
        )
    }

    private var label: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .tracking(1)
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(accent))
            .padding(Spacing.sm)
    }

    private var placeholder: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 22)).foregroundColor(Theme.textFaint)
            Text("No source").font(.system(size: 11)).foregroundColor(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A live channel surface + name + offline overlay, shared by big panes and
/// thumbnails.
private struct LivePane: View {
    @ObservedObject var channel: BridgeChannel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if channel.previewEnabled {
                MirrorVideoView(channel: channel)
                if channel.latestFrame == nil { offline }
            } else {
                offline
            }
            nameBar
        }
    }

    private var nameBar: some View {
        HStack(spacing: Spacing.xs) {
            ConnectionDot(connected: channel.isConnected)
            Text(channel.name).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.65)],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var offline: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: channel.isConnected ? "hourglass" : "wifi.slash")
                .font(.system(size: 18)).foregroundColor(Theme.textFaint)
            Text(channel.isConnected ? "Waiting for video" : "No camera")
                .font(.system(size: 10)).foregroundColor(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Thumbnail

private struct ThumbCell: View {
    @ObservedObject var channel: BridgeChannel
    let isProgram: Bool
    let isPreview: Bool
    let onStage: () -> Void
    let onTake: () -> Void

    var body: some View {
        LivePane(channel: channel)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onTake() }
            .onTapGesture { onStage() }
            .help(isProgram ? "On air" : "Click to stage in Preview · double-click to cut to Program")
    }

    private var borderColor: Color {
        if isProgram { return Theme.accentRed }
        if isPreview { return Theme.accentBlue }
        return Theme.stroke
    }
    private var borderWidth: CGFloat { (isProgram || isPreview) ? 2.5 : 1 }
}

/// Tiny dummy ObservableObject so `BigPane` can hold an `@ObservedObject` even in
/// the nil-channel case without optional-observed gymnastics.
private final class NoChannelSentinel: ObservableObject { static let shared = NoChannelSentinel() }
