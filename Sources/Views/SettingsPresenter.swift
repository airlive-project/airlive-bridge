// SettingsPresenter.swift - opens Settings as an app-modal window, the way OBS does.
//
// Its own window with a title bar and the window buttons, so it can be moved anywhere; and MODAL,
// so the Bridge's main window takes no clicks until it is closed and it can never fall behind
// (operator, 2026-10-07). A sheet did the second but was pinned to the main window's title bar.
//
// `NSApp.runModal(for:)` is AppKit's documented app-modal window (the same call every `NSAlert` in
// the Bridge already makes). While it runs, the main run loop is in its modal-panel mode, so only
// work scheduled in `.common` modes or on a dispatch queue keeps running there - provided the
// session is not started from inside a main-queue block (see `open`). Checked 2026-10-07:
// everything the show depends on does - video and outputs run on their own queues, the Auto Cut
// and Stream Deck dial timers are `.common`, the shortcut tap hops via `DispatchQueue.main`. A new
// main-thread timer that must run during a show has to be `.common` too.

import AppKit
import SwiftUI
import Sparkle

final class SettingsPresenter: NSObject, NSWindowDelegate {
    static let shared = SettingsPresenter()

    /// What the window shows. Handed over once by the app at launch.
    struct Dependencies {
        let model: BridgeModel
        let shortcuts: ShortcutCenter
        let control: ControlServer
        let updater: SPUUpdater
    }
    var dependencies: Dependencies?

    private var window: NSWindow?
    /// The open window's unapplied changes - held here so every way out can ask about them.
    private var draft: SettingsDraft?

    /// Open Settings, or bring it forward if it is already open - on `section` when given, so a
    /// control elsewhere in the Bridge leads to the one place its setting lives.
    func open(at section: SettingsSection? = nil) {
        // The window reads its section from this key (`@AppStorage`), also while already open.
        if let section { UserDefaults.standard.set(section.rawValue, forKey: SettingsWindow.sectionKey) }
        if let window { window.makeKeyAndOrderFront(nil); return }
        guard let d = dependencies else { return }

        let draft = SettingsDraft()
        self.draft = draft
        let root = SettingsWindow(model: d.model, shortcuts: d.shortcuts, control: d.control,
                                  updater: d.updater, draft: draft)
            .preferredColorScheme(.dark)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        // Titled + closable only: minimize and zoom stay greyed out; the close button asks about
        // unapplied changes (windowShouldClose).
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true            // the bar takes the window's own colour
        window.backgroundColor = NSColor(Theme.bgApp)
        window.isReleasedWhenClosed = false
        window.isRestorable = false                         // opened deliberately, never on launch
        // With the Bridge full screen, a plain window opens on ANOTHER desktop - and the modal
        // session would then hold the full-screen switcher locked with nothing visible to close.
        // Auxiliary windows share the full-screen Space.
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self
        centre(window, over: NSApp.mainWindow)
        self.window = window

        // After the click that opened it has finished, not inside it: `runModal` does not return
        // until the window closes. Scheduled on the RUN LOOP, never with `DispatchQueue.main.async`:
        // the main queue is serial, so a modal session started from inside one of its blocks holds
        // that block open and NO other main-queue work runs until the window closes. Measured
        // 2026-10-07: the no-signal black ticker (a main-queue timer) stopped for the whole time
        // Settings was open - 10 s and 9 s without a single program frame in the recording.
        RunLoop.main.perform { [weak self] in
            // Closed again before the session began: starting one now could never be ended.
            guard self?.window === window else { return }
            NSApp.runModal(for: window)
        }
    }

    /// The bar's Cancel / Close: throw away what is pending and close, no question - that IS the
    /// answer.
    func discardAndClose() {
        draft?.discard()
        window?.close()
    }

    /// Leave Settings, then run `action` (Check for Updates). Asks first when something is
    /// pending; staying put is a valid answer, and then nothing runs.
    func leave(then action: @escaping () -> Void) {
        resolvePending { [weak self] proceed in
            guard proceed else { return }
            self?.window?.close()
            DispatchQueue.main.async(execute: action)   // after the modal session has ended
        }
    }

    /// The window's close button: asks first when something is pending. Always answers "not yet"
    /// while asking - the question is a sheet, and the window closes from its answer.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard draft?.hasChanges == true else { return true }
        resolvePending { [weak self] proceed in
            if proceed { self?.window?.close() }   // close() does not ask again
        }
        return false
    }

    /// One question for every way out with unapplied changes, like OBS's (operator, 2026-10-07):
    /// silently dropping them, or silently keeping them, both surprise someone. A sheet on the
    /// Settings window, so it opens on it and not beside it in the middle of the screen.
    private func resolvePending(_ done: @escaping (_ proceed: Bool) -> Void) {
        guard let draft, draft.hasChanges, let model = dependencies?.model, let window else {
            return done(true)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if draft.canApply {
            alert.messageText = "Apply your changes?"
            alert.informativeText = "Some settings were changed but not applied."
            alert.addButton(withTitle: "Apply")
            alert.addButton(withTitle: "Don't Apply")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { answer in
                switch answer {
                case .alertFirstButtonReturn:  draft.apply(model: model); done(true)
                case .alertSecondButtonReturn: draft.discard();           done(true)
                default:                       done(false)
                }
            }
            return
        }
        // Pending changes that cannot be applied (an Auto Cut range that ends before it starts).
        alert.messageText = "Discard your changes?"
        alert.informativeText = "The Auto Cut range is not valid, so the changes cannot be applied."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { answer in
            guard answer == .alertFirstButtonReturn else { return done(false) }
            draft.discard()
            done(true)
        }
    }

    /// `abortModal`, not `stopModal`. A SwiftUI button runs its action after the click event has
    /// been handled, and `stopModal` only takes effect when the NEXT event arrives - Cancel looked
    /// dead until a second click (operator, 2026-10-07). `abortModal` ends the session at once from
    /// anywhere, which is what Apple documents it for.
    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === window { NSApp.abortModal() }
        draft?.discard()   // nothing pending outlives the window (also clears a guide preview)
        draft = nil
        window = nil
    }

    private func centre(_ window: NSWindow, over parent: NSWindow?) {
        guard let parent else { window.center(); return }
        let p = parent.frame, size = window.frame.size
        window.setFrameOrigin(NSPoint(x: p.midX - size.width / 2, y: p.midY - size.height / 2))
    }
}
