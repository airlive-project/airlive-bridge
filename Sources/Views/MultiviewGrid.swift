// MultiviewGrid.swift — the Multiview monitor (adaptive 4 / 8 / 12 / 16).
//
// A grid of EVERY channel's live preview.  This is pure layout of the channels'
// existing `AVSampleBufferDisplayLayer`s (each cell hosts one via PreviewView),
// so it costs the same as the same number of solo previews — there is NO
// compositing here.  (The composited PROGRAM buffer that goes to NDI/SRT/RTSP is
// a separate, Phase-2 concern.)
//
// The grid capacity steps 4 → 8 → 12 → 16 with the channel count (BridgeModel
// .multiviewCapacity), unlike Studio's fixed 8.  Clicking a cell selects that
// channel (Phase 2: picks it as the solo PROGRAM source).

import SwiftUI

struct MultiviewGrid: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        let capacity = model.multiviewCapacity()
        let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.sm),
                            count: model.multiviewColumns())
        ScrollView {
            LazyVGrid(columns: columns, spacing: Spacing.sm) {
                ForEach(0 ..< capacity, id: \.self) { index in
                    if index < model.channels.count {
                        let channel = model.channels[index]
                        MultiviewCell(channel: channel,
                                      selected: channel.id == model.selectedID,
                                      onSelect: { model.select(channel.id) })
                    } else {
                        emptyCell
                    }
                }
            }
            .padding(Spacing.lg)
        }
    }

    /// A dark placeholder for an unfilled grid slot.
    private var emptyCell: some View {
        RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
            .fill(Color.black)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textFaint.opacity(0.35))
            )
    }
}

// MARK: - One multiview cell

private struct MultiviewCell: View {
    @ObservedObject var channel: BridgeChannel
    @ObservedObject private var tally = TallyStore.shared
    let selected: Bool
    let onSelect: () -> Void

    private var cue: TallyState { tally.state(for: channel.id) }

    var body: some View {
        ZStack {
            if channel.previewEnabled {
                PreviewView(channel: channel)
                if channel.latestFrame == nil { offlineOverlay }
            } else {
                offlineOverlay
            }
            VStack { Spacer(); nameBar }
            cueBadge
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private var nameBar: some View {
        HStack(spacing: Spacing.xs) {
            ConnectionDot(connected: channel.isConnected)
            Text(channel.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var offlineOverlay: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: channel.isConnected ? "hourglass" : "wifi.slash")
                .font(.system(size: 18))
                .foregroundColor(Theme.textFaint)
            Text(channel.isConnected ? "Waiting for video" : "No camera")
                .font(.system(size: 10))
                .foregroundColor(Theme.textFaint)
        }
    }

    @ViewBuilder
    private var cueBadge: some View {
        if cue != .off {
            VStack {
                HStack {
                    Spacer()
                    Text(cue == .program ? "ON AIR" : "PVW")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(cue.accent))
                        .padding(Spacing.xs)
                }
                Spacer()
            }
        }
    }

    private var borderColor: Color {
        if cue == .program { return Theme.accentRed }
        if cue == .preview { return Theme.accentYellow }
        return selected ? Theme.accentBlue : Theme.stroke
    }

    private var borderWidth: CGFloat { (cue != .off || selected) ? 2.5 : 1 }
}
