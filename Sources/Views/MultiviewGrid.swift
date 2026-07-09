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
    @EnvironmentObject var shortcuts: ShortcutCenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.md) {
                topBar
                // One unified grid: every tile shares the `multiviewTile` rule (1px neutral
                // seam, 2px accent when selected), so seams are single 1px lines and the
                // selected PVW/PGM/thumbs read as crisp 2px green/red.  The container frame
                // closes the outer bottom/right edge.
                VStack(spacing: 0) {
                    bigRow
                    thumbnails
                }
                .overlay(Rectangle().strokeBorder(Theme.stroke, lineWidth: 1))
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
    /// cut it to air.  Delegates to `LensQuickRow`, which has its OWN `@ObservedObject`
    /// on the preview channel so it repaints the INSTANT that channel changes.
    @ViewBuilder
    private var lensQuickRow: some View {
        if let preview = model.previewChannel() {
            LensQuickRow(channel: preview)
        } else {
            Text("Stage a camera to pick its lens")
                .font(.system(size: 11)).foregroundColor(Theme.textFaint)
        }
    }

    /// Its OWN `@ObservedObject channel` is the whole point: the row repaints the
    /// INSTANT that channel publishes — the optimistic `pendingLens` on tap (blue moves
    /// on the same frame you click) and the camera's reported `remote` ladder / lens.
    /// As a plain computed property on MultiviewGrid it only repainted on a MODEL-level
    /// publish (≈ the debounced autosave tick), so the blue highlight lagged the camera
    /// by seconds and the ladder took ~5 s to appear on connect — a pure re-render bug
    /// that three rounds of model-side reconcile "fixes" never touched.  Shown ONLY once
    /// the camera reports ITS ladder (no invented default buttons for a camera that
    /// hasn't said what it can do); capped at 6 — the deepest iPhone ladder and the
    /// Z X C V B N shortcut row.
    private struct LensQuickRow: View {
        @ObservedObject var channel: BridgeChannel
        @EnvironmentObject var shortcuts: ShortcutCenter

        var body: some View {
            if let lenses = channel.remote?.availableLenses, !lenses.isEmpty {
                HStack(spacing: Spacing.xs) {
                    ForEach(Array(lenses.prefix(6).enumerated()), id: \.element) { pair in
                        let isSel = channel.selectedLens == pair.element
                        Button { channel.selectLens(pair.element) } label: {
                            HStack(spacing: 3) {
                                Text(pair.element)
                                    .font(.system(size: 11, weight: .medium))
                                if shortcuts.showHints {
                                    Text(shortcuts.bindings.chord(
                                            for: ShortcutAction(kind: .lens, index: pair.offset)).display)
                                        .font(.system(size: 9, weight: .medium))
                                        // White-on-fill so the key hint stays legible on the BLUE
                                        // selected tile (textFaint vanished there); brighter when active.
                                        .foregroundColor(.white.opacity(isSel ? 0.85 : 0.45))
                                }
                            }
                            .frame(height: 26)
                            .padding(.horizontal, Spacing.sm)
                        }
                        .bridgeButton(selected: isSel)
                        .disabled(!channel.remoteControlConnected || !channel.remoteControlAllowed)
                    }
                }
                .opacity((channel.remoteControlConnected && channel.remoteControlAllowed) ? 1 : 0.4)
            } else {
                Text("Stage a camera to pick its lens")
                    .font(.system(size: 11)).foregroundColor(Theme.textFaint)
            }
        }
    }

    /// CUT preview → program (also Space, handled centrally by ShortcutCenter so it
    /// works globally — no per-button shortcut, to avoid a double cut).  Moved to the
    /// top-center; the old full-width bar under the panes is gone.
    private var cutButton: some View {
        // ANY staged channel cuts to air, signal or not — a channel with no live video airs BLACK,
        // like an empty input on a real switcher.  Only disabled when nothing is staged at all.
        let canCut = model.previewID != nil
        return Button { model.take() } label: {
            HStack(spacing: 4) {
                Text("CUT")
                    .font(.system(size: 11, weight: .medium))
                if shortcuts.showHints {
                    Text(shortcuts.bindings.chord(for: ShortcutAction(kind: .cut, index: 0)).display)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Theme.textFaint.opacity(0.7))
                }
            }
            .frame(height: 26)
            .padding(.horizontal, Spacing.sm)
        }
        .bridgeButton()
        .disabled(!canCut)
        .opacity(canCut ? 1 : 0.5)
        .help(canCut ? "Cut the Preview channel to Program (Space) — no signal airs black"
                     : "Stage a channel in Preview first")
    }

    /// Full-Screen the window.  ROADMAP: a CLEAN multiview-only full-screen (hide the
    /// rails + controls, just the PVW/PGM + wall).  For now it's the native window
    /// full-screen so the button is live.
    private var fullScreenButton: some View {
        // Clean MULTICAM fullscreen, NOT the whole app: open the wall window (just the
        // PVW/PGM + thumbnail grid) and flip THAT to fullscreen.
        Button {
            model.wallFullscreenRequested = true
            openWindow(id: MultiviewWall.windowID)
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                Text("Full-Screen").font(.system(size: 11, weight: .medium))
            }
            .frame(height: 26)
            .padding(.horizontal, Spacing.sm)
        }
        .bridgeButton()
        .help("Full-screen the multiview (clean wall)")
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

    /// Tap-to-focus on the STAGED (preview) camera — the one the control panel drives.  Gated on the
    /// camera's "focusPoint" cap (legacy cameras no-op).  `pt` is already normalised to the native
    /// landscape frame (MirrorVideoView inverted its own rotation/letterbox).
    private func focusPreview(_ pt: CGPoint) {
        guard let c = model.previewChannel(), c.hasCap("focusPoint") else { return }
        c.send(.setFocusPoint(x: Float(pt.x), y: Float(pt.y)))
    }

    private var bigRow: some View {
        HStack(spacing: 0) {   // panes touch; green PVW edge meets red PGM edge
            BigPane(title: "PREVIEW", accent: Theme.previewGreen, channel: model.previewChannel(),
                    onTapPoint: focusPreview)
            BigPane(title: "PROGRAM", accent: Theme.accentRed, channel: model.programChannel())
        }
    }

    // Camera control for the STAGED (Preview) camera, kept under the multiview —
    // lens-first (the panel leads with the lens picker), no tally here.
    @ViewBuilder
    private var cameraControl: some View {
        if let preview = model.previewChannel() {
            // Lens lives in the quick-row above the panes here — hide the panel's LENS card.
            // For a Screen-Mirroring tile this leads with the "Remote control" dropdown.
            CameraControlSection(channel: preview)
        }
    }

    // MARK: Camera thumbnails (rows of 4)

    private var thumbnails: some View {
        let tiles = model.multiviewChannels          // Remote-Control channels carry no tile
        let count = tiles.count
        let capacity = max(1, (count + 3) / 4) * 4   // whole rows of 4
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 4)
        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(0 ..< capacity, id: \.self) { index in
                if index < count {
                    let channel = tiles[index]
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
            .multiviewTile(accent: nil)
            .overlay(
                Image(systemName: "plus").font(.system(size: 13))
                    .foregroundColor(Theme.textFaint.opacity(0.3))
            )
    }
}

// MARK: - Unified multiview cell border
//
// ONE rule for every tile (big panes, thumbnails, empties) so the whole grid behaves as
// a single object instead of separate blocks whose edges double at the seams:
//   • a 1px NEUTRAL line on the TOP and LEADING edges only — so two touching tiles SHARE
//     one line (each internal seam is drawn exactly once, by the tile below / to the
//     right).  Never 2px, never missing.
//   • a SELECTED tile adds a 2px accent frame on top (green = preview/staged, red =
//     program/on-air), which covers the neutral line on its edges.
// The grid container draws the outer bottom/right frame the per-tile top/leading edges
// don't reach.
private extension View {
    func multiviewTile(accent: Color?) -> some View {
        self
            .overlay(alignment: .top)     { Theme.stroke.frame(height: 1) }
            .overlay(alignment: .leading) { Theme.stroke.frame(width: 1) }
            .overlay { if let accent { Rectangle().strokeBorder(accent, lineWidth: 2) } }
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
    /// Tap-to-focus, wired ONLY on the PREVIEW pane (the camera the control panel drives).
    var onTapPoint: ((CGPoint) -> Void)? = nil

    var body: some View {
        Group {
            if let channel {
                LivePane(channel: channel, showName: false, onTapPoint: onTapPoint)
            } else {
                placeholder
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipped()
        // Always selected (PVW green / PGM red) → 2px accent via the shared tile rule.
        .multiviewTile(accent: accent)
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
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.black.opacity(0.5)))
        .padding(.bottom, Spacing.sm)
}

/// A live channel surface + (optional) name chip + offline overlay, shared by the
/// big panes and the thumbnails.
private struct LivePane: View {
    @ObservedObject var channel: BridgeChannel
    var showName: Bool = true
    var onTapPoint: ((CGPoint) -> Void)? = nil

    var body: some View {
        // Video lives in an OVERLAY over a SIZED black Rectangle — the proven Studio
        // pattern (VideoRegion.swift).  The overlay inherits the Rectangle's full tile
        // size, so the hosted video layer fills the tile.  A bare ZStack whose only child
        // is the flexible video NSView collapses to that NSView's tiny intrinsic size,
        // which is what stuck the picture in a small corner rectangle.
        Rectangle()
            .fill(Color.black)
            .overlay {
                ZStack {
                    // ⚠️ Key off the camera-CONFIRMED videoActive, never a requested mode.
                    // Control-only (encoder off) → labelled placeholder, NOT a frozen frame
                    // / disconnect.  videoActive is true for AirPlay/capture (nil remote).
                    if !channel.videoActive {
                        controlOnly
                    } else if channel.previewEnabled {
                        MirrorVideoView(channel: channel, onTapPoint: onTapPoint)
                        if channel.latestFrame == nil { offline }
                    } else {
                        offline
                    }
                }
            }
            .overlay(alignment: .bottom) {
            if showName {
                HStack(spacing: Spacing.xs) {
                    ConnectionDot(connected: channel.anyConnected)   // combined: control link counts too
                    Text(channel.name).font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.black.opacity(0.5)))
                .padding(.bottom, Spacing.sm)
            }
        }
    }

    private var offline: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: channel.anyConnected ? "hourglass" : "wifi.slash")
                .font(.system(size: 18)).foregroundColor(Theme.textFaint)
            Text(channel.anyConnected ? "Waiting for video" : "No camera")
                .font(.system(size: 10)).foregroundColor(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Camera confirmed Control-only (encoder off): no Airlive video on this link.
    private var controlOnly: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: "video.slash").font(.system(size: 18)).foregroundColor(Theme.textFaint)
            Text("CONTROL ONLY").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.textFaint)
            Text("no Airlive video").font(.system(size: 9)).foregroundColor(Theme.textFaint.opacity(0.7))
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
            // Shared tile rule: 1px neutral seam, +2px accent when staged (green) / on air (red).
            .multiviewTile(accent: tileAccent)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onTake() }
            .onTapGesture { onStage() }
            .help(isProgram ? "On air" : "Click to stage in Preview · double-click to cut to Program")
    }

    private var tileAccent: Color? {
        if isProgram { return Theme.accentRed }
        if isPreview { return Theme.previewGreen }
        return nil
    }
}

// MARK: - Fullscreen multiview wall (its own window)

/// A clean multiview for a second monitor: PREVIEW + PROGRAM on top, camera
/// thumbnails (rows of 4) below — NO cut bar, NO camera control, NO rails.  Same
/// live mirrors (zero extra decodes); clicking a tile still stages / cuts.
struct MultiviewWall: View {
    static let windowID = "multiview-wall"
    @ObservedObject var model: BridgeModel
    @State private var win: NSWindow?
    @State private var alwaysOnTop = false

    private var preview: BridgeChannel? { model.channels.first { $0.id == model.previewID } }
    private var program: BridgeChannel? { model.channels.first { $0.id == model.programID } }

    var body: some View {
        // The grid fills the window edge-to-edge (no outer .fit letterbox → no side bars).
        // Each tile keeps 16:9 via its own aspectRatio, and the window is LOCKED to the
        // grid's aspect (configurator) so filling never stretches the tiles.  In fullscreen
        // the per-tile ratios keep everything 16:9, letterboxed on the screen.
        grid
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .background(WallWindowConfigurator(aspect: gridAspect, model: model) { w in
                if win !== w { win = w }
                w.isRestorable = false   // don't auto-reopen the wall next launch (see NonRestorableWindow)
            })
            // OBS-style projector menu on right-click.
            .contextMenu { wallMenu }
    }

    /// Right-click menu on the detached wall, mirroring OBS's windowed-projector menu.
    @ViewBuilder
    private var wallMenu: some View {
        Button("Fullscreen") { win?.toggleFullScreen(nil) }
        Button("Fit Window to Content") {
            guard let win else { return }
            let w = win.contentLayoutRect.width            // snap height back to the grid aspect
            win.setContentSize(NSSize(width: w, height: (w / gridAspect).rounded()))
        }
        Divider()
        Toggle("Always On Top", isOn: Binding(
            get: { alwaysOnTop },
            set: { on in alwaysOnTop = on; win?.level = on ? .floating : .normal }
        ))
        Divider()
        Button("Close") { win?.close() }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                BigPane(title: "PREVIEW", accent: Theme.previewGreen, channel: preview,
                        onTapPoint: { pt in
                            guard preview?.hasCap("focusPoint") == true else { return }
                            preview?.send(.setFocusPoint(x: Float(pt.x), y: Float(pt.y)))
                        })
                BigPane(title: "PROGRAM", accent: Theme.accentRed, channel: program)
            }
            thumbnails
        }
        .overlay(Rectangle().strokeBorder(Theme.stroke, lineWidth: 1))   // outer frame
    }

    /// Natural width:height of the wall grid for the current channel count, so the window
    /// and the `.fit` keep every tile at 16:9.  bigRow = two 16:9 panes side by side; each
    /// thumbnail row is half a pane tall → W:H = 64 : 9·(2 + rows).
    private var gridAspect: CGFloat {
        let rows = CGFloat(max(1, (model.multiviewChannels.count + 3) / 4))
        return 64.0 / (9.0 * (2.0 + rows))
    }

    private var thumbnails: some View {
        let tiles = model.multiviewChannels          // Remote-Control channels carry no tile
        let count = tiles.count
        let capacity = max(1, (count + 3) / 4) * 4
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 4)
        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(0 ..< capacity, id: \.self) { index in
                if index < count {
                    let channel = tiles[index]
                    ThumbCell(channel: channel,
                              isProgram: channel.id == model.programID,
                              isPreview: channel.id == model.previewID,
                              onStage: { model.stage(channel.id) },
                              onTake: { model.stage(channel.id); model.take() })
                } else {
                    Rectangle().fill(Color.black).aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .multiviewTile(accent: nil)
                }
            }
        }
    }
}

// MARK: - Wall window configurator
//
// Reaches the wall's NSWindow to: (1) LOCK it to the grid's aspect so tiles never stretch
// and there are no letterbox bars when windowed, (2) size it to that aspect on first show
// (Detach opens "under the multiview", not a fixed default), and (3) flip it to fullscreen
// once when the operator hit "Full-Screen" — a CLEAN multicam fullscreen, not the app.
private struct WallWindowConfigurator: NSViewRepresentable {
    let aspect: CGFloat
    @ObservedObject var model: BridgeModel
    var onWindow: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { apply(v.window, context.coordinator) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(nsView.window, context.coordinator) }
    }

    private func apply(_ window: NSWindow?, _ coord: Coordinator) {
        guard let window else { return }
        onWindow(window)
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        if !coord.sized {
            coord.sized = true
            window.title = "Multiview"
            let w: CGFloat = 1280
            window.setContentSize(NSSize(width: w, height: (w / aspect).rounded()))
            window.center()
        }
        if model.wallFullscreenRequested {
            model.wallFullscreenRequested = false
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            // The Full-Screen BUTTON means "fullscreen mode", not "detach": leaving
            // fullscreen (Esc / toggle) closes the wall window outright instead of
            // stranding the operator in a windowed detach they then have to close.
            // Detach + the context-menu Fullscreen toggle keep the windowed behaviour.
            coord.closeOnExitFullScreen = true
            if coord.exitObserver == nil {
                coord.exitObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window, queue: .main) { [weak window] _ in
                    guard coord.closeOnExitFullScreen else { return }
                    coord.closeOnExitFullScreen = false
                    window?.close()
                }
            }
        }
    }

    final class Coordinator {
        var sized = false
        var closeOnExitFullScreen = false
        var exitObserver: Any?
        deinit { if let o = exitObserver { NotificationCenter.default.removeObserver(o) } }
    }
}
