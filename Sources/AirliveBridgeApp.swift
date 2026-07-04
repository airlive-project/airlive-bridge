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

/// Quit guard: closing the app mid-take kills every camera stream and the program feed
/// (OBS/NDI/RTSP/SRT go dark) — too destructive for a stray ⌘Q.  If any channel is live,
/// ask first; with nothing connected, quit silently as usual.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by AirliveBridgeApp.init — the adaptor instantiates this delegate itself,
    /// so the model is handed over via a static (single app-lifetime model).
    static weak var model: BridgeModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model,
              model.channels.contains(where: { $0.anyConnected }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A stream is live"
        alert.informativeText = "One or more cameras are connected — quitting stops the stream and every program output. Quit anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")     // first = default (Return)
        alert.addButton(withTitle: "Cancel")   // Esc
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Flush the session autosave — a quit right after a change must not lose it
    /// (the debounced write may still be pending).
    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.autosaveNow()
    }
}

@main
struct AirliveBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: BridgeModel
    @StateObject private var shortcuts: ShortcutCenter

    init() {
        let m = BridgeModel()
        _model = StateObject(wrappedValue: m)
        _shortcuts = StateObject(wrappedValue: ShortcutCenter(model: m))
        AppDelegate.model = m   // quit guard reads live-stream state from here
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
        // delays) to a portable `.airliveprofile`.  Live connections / running outputs
        // are NOT saved; a loaded profile rebuilds the layout (outputs OFF).  Day-to-day
        // persistence doesn't need this menu at all: the session autosaves continuously
        // and restores on launch (see BridgeModel "Session autosave").
        .commands {
            // Our own Undo/Redo (⌘Z / ⇧⌘Z) — the model keeps a config-action history
            // (add/remove/reorder/rename of channels + outputs; never live switching).
            // While a text field is being edited its OWN undo wins, so typing ⌘Z in a
            // name field undoes typing, not the last config action.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { performUndo() }
                    .keyboardShortcut("z", modifiers: [.command])
                Button("Redo") { performRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Profiles") {
                Button("New Profile") { newProfile() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Save Profile") { saveCurrentProfile() }       // update-in-place
                    .keyboardShortcut("s", modifiers: [.command])
                Button("Save Profile As…") { saveProfileAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Open Profile…") { openProfile() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
            // Shortcuts open their OWN window from the menu bar (⌘K).  Deliberately not a
            // toolbar button: macOS 26 wraps toolbar items in liquid-glass chrome we can't
            // disable, and the app must look identical across OS versions.
            CommandMenu("Shortcuts") {
                OpenShortcutsCommand()
            }
        }

        // The Shortcuts window itself (menu bar → Shortcuts → Customize Shortcuts…, ⌘K).
        Window("Shortcuts", id: shortcutsWindowID) {
            ShortcutSettings(shortcuts: shortcuts, bindings: shortcuts.bindings, model: model)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)

        // Clean fullscreen multiview wall (second monitor) — opened from the
        // multiview's "Fullscreen Multicam" button.  Shares the same model.
        WindowGroup(id: MultiviewWall.windowID) {
            MultiviewWall(model: model)
                .frame(minWidth: 640, minHeight: 400)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 800)
    }

    // MARK: - Undo / Redo (menu actions)

    /// Field editing active → forward to the text system's undo; else the model's
    /// config history.  (Menu key equivalents fire BEFORE the responder chain, so
    /// without this a ⌘Z while renaming would undo a channel delete instead of typing.)
    private func performUndo() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
            editor.undoManager?.undo()
        } else {
            model.undo()
        }
    }

    private func performRedo() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
            editor.undoManager?.redo()
        } else {
            model.redo()
        }
    }

    // MARK: - Profiles (menu actions)

    /// Stable id for the Shortcuts window scene.
    fileprivate var shortcutsWindowID: String { "bridge-shortcuts" }

    /// Reset to a first-launch setup.  Deliberate destruction → confirm when a show
    /// is built (channels exist); an already-empty Bridge resets silently.
    private func newProfile() {
        if !model.channels.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Start a new profile?"
            alert.informativeText = "This clears every channel and output. The current setup is kept only if you saved it as a profile."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "New Profile")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.newProfile()
    }

    /// Update the current profile file in place; falls back to Save As when the
    /// setup was never saved (no file to update yet).
    private func saveCurrentProfile() {
        guard let url = model.profileURL else { saveProfileAs(); return }
        do { try model.snapshotProfile().write(to: url) }
        catch { presentProfileError(error, verb: "save") }
    }

    /// Write the current setup to a NEW `.airliveprofile` the operator picks; it
    /// becomes the current profile (window title + Save target).
    private func saveProfileAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [BridgeProfileDocument.contentType]
        panel.nameFieldStringValue = model.profileName == "Default" ? "Bridge" : model.profileName
        panel.canCreateDirectories = true
        panel.title = "Save Bridge Profile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.snapshotProfile().write(to: url)
            model.profileName = url.deletingPathExtension().lastPathComponent   // → window title
            model.profileURL = url                                              // → Save target
        }
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
        do {
            model.applyProfile(try BridgeProfile.read(from: url))
            model.profileName = url.deletingPathExtension().lastPathComponent   // → window title
            model.profileURL = url                                              // → Save target
        }
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

/// Menu-bar command that opens the Shortcuts window — a tiny View so it can read
/// `openWindow` from the environment (commands content can't take @Environment directly).
private struct OpenShortcutsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Customize Shortcuts…") { openWindow(id: "bridge-shortcuts") }
            .keyboardShortcut("k", modifiers: [.command])
    }
}
