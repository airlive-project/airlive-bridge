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
import AppKit   // NSSavePanel / NSOpenPanel / NSAlert for profile load / save

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
        // Profiles menu — save / load a whole setup (channels + outputs + names + order +
        // delays + mode) to a portable `.airliveprofile`.  Live connections / running
        // outputs are NOT saved; a loaded profile rebuilds the layout (outputs OFF).
        .commands {
            CommandMenu("Profiles") {
                Button("Save Profile…") { saveProfile() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Open Profile…") { openProfile() }
                    .keyboardShortcut("o", modifiers: [.command])
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

    // MARK: - Profiles (menu actions)

    /// Write the current setup to a `.airliveprofile` the operator picks.
    private func saveProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [BridgeProfileDocument.contentType]
        panel.nameFieldStringValue = "Bridge"
        panel.canCreateDirectories = true
        panel.title = "Save Bridge Profile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.snapshotProfile().write(to: url) }
        catch { presentProfileError(error, verb: "save") }
    }

    /// Load a `.airliveprofile` and replace the current setup with it.
    private func openProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [BridgeProfileDocument.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Bridge Profile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { model.applyProfile(try BridgeProfile.read(from: url)) }
        catch { presentProfileError(error, verb: "open") }
    }

    private func presentProfileError(_ error: Error, verb: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t \(verb) the profile"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
