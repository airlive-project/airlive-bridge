// AirliveBridgeApp.swift — app entry.
//
// Airlive Bridge receives the Airlive Camera (iPhone) stream and re-publishes it
// as NDI / SRT / RTSP, with remote camera control built in (downstream outputs
// are one-way, so control lives here). Mac MVP; see README.md / ROADMAP.md.
//
// Owns the single `BridgeModel` as a `@StateObject` and injects it into the view
// tree as an environment object — the three zones (Channels | Selected channel +
// control | Outputs) all observe it from there.

import SwiftUI

@main
struct AirliveBridgeApp: App {
    @StateObject private var model: BridgeModel
    @StateObject private var shortcuts: ShortcutCenter

    init() {
        let m = BridgeModel()
        _model = StateObject(wrappedValue: m)
        _shortcuts = StateObject(wrappedValue: ShortcutCenter(model: m))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(shortcuts)
                // Min size keeps the three zones (Channels 240 + center + Outputs
                // 280, plus dividers) from overlapping; the center still has room
                // for the 16:9 preview + control panel at the floor.  Ideal size
                // is the comfortable default the window opens at on first launch
                // so nothing overflows out of the box (the center pane scrolls).
                .frame(minWidth: 1040, idealWidth: 1200,
                       minHeight: 680, idealHeight: 760)
                .preferredColorScheme(.dark)
        }
        // Real title bar — it IS our control strip: ContentView puts our themed
        // Solo ⇄ Multiview switch in it (`.toolbar` principal) and paints the bar
        // our dark background (`.toolbarBackground`), so there's no extra empty
        // row and no grey native chrome.
        .windowStyle(.titleBar)
        // First-launch window size — matches the ideal content frame so the
        // operator never has to resize to see all three zones.
        .defaultSize(width: 1200, height: 760)
        // Profiles menu — the entry point for saving/loading a whole setup (channels +
        // outputs + names + order).  The save/load engine is a ROADMAP item (needs the
        // model serialised); these are the menu hooks it will wire into, disabled until then.
        .commands {
            CommandMenu("Profiles") {
                Button("New Profile…") {}.disabled(true)
                Button("Open Profile…") {}.disabled(true)
            }
        }

        // Clean fullscreen multiview wall (second monitor) — opened from the
        // multiview's "Fullscreen Multicam" button.  Shares the same model.
        WindowGroup(id: MultiviewWall.windowID) {
            MultiviewWall(model: model)
                .frame(minWidth: 640, minHeight: 400)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 800)
    }
}
