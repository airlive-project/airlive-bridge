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
import AppKit   // NSApp.keyWindow.toggleFullScreen

struct MultiviewGrid: View {
    @ObservedObject var model: BridgeModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.md) {
                topBar
                // True 1px grid (vMix-style): the tiles sit on a stroke-coloured backing
                // with a 1px GAP between them, so every seam is exactly ONE 1px line —
                // never doubled (no two borders stacking), never missing (no z-order
                // cover-up).  Tally tiles (PVW green / PGM red / staged) draw their accent
                // border at the tile edge; neutral tiles have none (the gap separates them).
                VStack(spacing: 1) {
                    bigRow
                    thumbnails
                }
                .background(Theme.stroke)
                cameraControl
            }
            .padding(Spacing.lg)
        }
    }

    // MARK: Top bar — lenses (over Preview, left) · CUT (center) · Fullscreen (right)

    private var topBar: some View {
        // CUT must sit on the TRUE center (the PVW/PGM seam), not between the lens row
        // and Fullscreen (the lens row is wider, which pushed it left).  ZStack centers
        // CUT in the full bar width; the edges (lenses left, Fullscreen right) overlay.
        ZStack {
            HStack(spacing: Spacing.sm) {
                lensQuickRow                   // above PREVIEW (left)
                Spacer(minLength: Spacing.sm)
                HStack(spacing: Spacing.xs) {  // right
                    fullScreenButton
                    detachButton
                }
            }
            cutButton                          // dead-center over the PVW/PGM seam
        }
    }

    /// Quick lens picker for the STAGED (Preview) camera — pick the look before you
    /// cut it to air.  Labels are the camera's reported ladder (0.5x / 1x / 2x …),
    /// falling back to the canonical iPhone ladder until it reports.
    @ViewBuilder
    private var lensQuickRow: some View {
        if let preview = model.previewChannel() {
            HStack(spacing: Spacing.xs) {
                ForEach(lensLadder(preview), id: \.self) { label in
                    Button { preview.send(.setLens(label)) } label: {
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                            .frame(height: 26)
                            .padding(.horizontal, Spacing.sm)
                    }
                    .bridgeButton(selected: preview.remote?.lens == label)
                    .disabled(!preview.isConnected)
                }
            }
            .opacity(preview.isConnected ? 1 : 0.4)
        } else {
            Text("Stage a camera to pick its lens")
                .font(.system(size: 11)).foregroundColor(Theme.textFaint)
        }
    }

    private func lensLadder(_ channel: BridgeChannel) -> [String] {
        let reported = channel.remote?.availableLenses ?? []
        return reported.isEmpty ? ["0.5x", "1x", "2x", "3x", "5x"] : reported
    }

    /// CUT preview → program (also Space, handled centrally by ShortcutCenter so it
    /// works globally — no per-button shortcut, to avoid a double cut).  Moved to the
    /// top-center; the old full-width bar under the panes is gone.
    private var cutButton: some View {
        Button { model.take() } label: {
            Text("CUT  (Space)")
                .font(.system(size: 11, weight: .medium))
                .frame(height: 26)
                .padding(.horizontal, Spacing.sm)
        }
        .bridgeButton()
        .disabled(model.previewChannel() == nil)
        .opacity(model.previewChannel() == nil ? 0.5 : 1)
        .help("Cut the Preview camera to Program (Space)")
    }

    /// Full-Screen the window.  ROADMAP: a CLEAN multiview-only full-screen (hide the
    /// rails + controls, just the PVW/PGM + wall).  For now it's the native window
    /// full-screen so the button is live.
    private var fullScreenButton: some View {
        Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                Text("Full-Screen").font(.system(size: 11, weight: .medium))
            }
            .frame(height: 26)
            .padding(.horizontal, Spacing.sm)
        }
        .bridgeButton()
        .help("Full-screen this window")
    }

    /// Detach: pop the multiview into its own window (drag to a second screen).
    private var detachButton: some View {
        Button { openWindow(id: MultiviewWall.windowID) } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "rectangle.on.rectangle")
                Text("Detach").font(.system(size: 11, weight: .medium))
            }
            .frame(height: 26)
            .padding(.horizontal, Spacing.sm)
        }
        .bridgeButton()
        .help("Open the multiview in its own window")
    }

    // MARK: Preview + Program (the two big windows)
    // Studio colours: PREVIEW = broadcast green, PROGRAM = broadcast red.

    private var bigRow: some View {
        HStack(spacing: 1) {   // 1px gap = the grid line between PVW and PGM
            BigPane(title: "PREVIEW", accent: Theme.previewGreen, channel: model.previewChannel())
            BigPane(title: "PROGRAM", accent: Theme.accentRed, channel: model.programChannel())
        }
    }

    // Camera control for the STAGED (Preview) camera, kept under the multiview —
    // lens-first (the panel leads with the lens picker), no tally here.
    @ViewBuilder
    private var cameraControl: some View {
        if let preview = model.previewChannel() {
            CameraControlPanel(channel: preview)
                .disabled(!preview.isConnected)
                .opacity(preview.isConnected ? 1.0 : 0.4)
        }
    }

    // MARK: Camera thumbnails (rows of 4)

    private var thumbnails: some View {
        let count = model.channels.count
        let capacity = max(1, (count + 3) / 4) * 4   // whole rows of 4
        let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 4)
        return LazyVGrid(columns: columns, spacing: 1) {
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
        Rectangle()
            .fill(Color.black)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(
                Image(systemName: "plus").font(.system(size: 13))
                    .foregroundColor(Theme.textFaint.opacity(0.3))
            )
    }
}

// MARK: - Big Preview / Program window
//
// Square (no rounding), a SUBTLE 2pt accent border that just hints what's
// selected, and the PREVIEW / PROGRAM label as a small semi-transparent chip at
// the BOTTOM (Studio / vMix style), not a big coloured badge on top.

private struct BigPane: View {
    let title: String
    let accent: Color
    let channel: BridgeChannel?

    var body: some View {
        Group {
            if let channel {
                LivePane(channel: channel, showName: false)
            } else {
                placeholder
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipped()
        // strokeBorder draws INSIDE the cell so touching tiles never double up.
        .overlay(Rectangle().strokeBorder(accent, lineWidth: 1))
        // White label (the coloured border already signals preview/program).
        .overlay(alignment: .bottom) { bottomChip(title) }
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

/// A small dark semi-transparent label chip pinned to the bottom of a tile.
private func bottomChip(_ text: String, color: Color = .white) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .bold))
        .tracking(0.5)
        .foregroundColor(color)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black.opacity(0.5)))
        .padding(.bottom, Spacing.sm)
}

/// A live channel surface + (optional) name chip + offline overlay, shared by the
/// big panes and the thumbnails.
private struct LivePane: View {
    @ObservedObject var channel: BridgeChannel
    var showName: Bool = true

    var body: some View {
        ZStack {
            if channel.previewEnabled {
                MirrorVideoView(channel: channel)
                if channel.latestFrame == nil { offline }
            } else {
                offline
            }
        }
        .overlay(alignment: .bottom) {
            if showName {
                HStack(spacing: Spacing.xs) {
                    ConnectionDot(connected: channel.isConnected)
                    Text(channel.name).font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black.opacity(0.5)))
                .padding(.bottom, Spacing.sm)
            }
        }
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
            .clipped()
            // Only tally tiles get a border (green = staged, red = on air); neutral tiles
            // rely on the 1px grid gap.  The accent reaches the tile edge, no doubling.
            .overlay {
                if isProgram || isPreview {
                    Rectangle().strokeBorder(borderColor, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onTake() }
            .onTapGesture { onStage() }
            .help(isProgram ? "On air" : "Click to stage in Preview · double-click to cut to Program")
    }

    private var borderColor: Color {
        if isProgram { return Theme.accentRed }
        if isPreview { return Theme.previewGreen }
        return Theme.stroke
    }
}

// MARK: - Fullscreen multiview wall (its own window)

/// A clean multiview for a second monitor: PREVIEW + PROGRAM on top, camera
/// thumbnails (rows of 4) below — NO cut bar, NO camera control, NO rails.  Same
/// live mirrors (zero extra decodes); clicking a tile still stages / cuts.
struct MultiviewWall: View {
    static let windowID = "multiview-wall"
    @ObservedObject var model: BridgeModel

    private var preview: BridgeChannel? { model.channels.first { $0.id == model.previewID } }
    private var program: BridgeChannel? { model.channels.first { $0.id == model.programID } }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 1) {
                BigPane(title: "PREVIEW", accent: Theme.previewGreen, channel: preview)
                BigPane(title: "PROGRAM", accent: Theme.accentRed, channel: program)
            }
            thumbnails
        }
        .background(Theme.stroke)              // 1px grid lines show through the gaps
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)               // window backing behind the grid
    }

    private var thumbnails: some View {
        let count = model.channels.count
        let capacity = max(1, (count + 3) / 4) * 4
        let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 4)
        return LazyVGrid(columns: columns, spacing: 1) {
            ForEach(0 ..< capacity, id: \.self) { index in
                if index < count {
                    let channel = model.channels[index]
                    ThumbCell(channel: channel,
                              isProgram: channel.id == model.programID,
                              isPreview: channel.id == model.previewID,
                              onStage: { model.stage(channel.id) },
                              onTake: { model.stage(channel.id); model.take() })
                } else {
                    Rectangle().fill(Color.black).aspectRatio(16.0 / 9.0, contentMode: .fit)
                }
            }
        }
    }
}
