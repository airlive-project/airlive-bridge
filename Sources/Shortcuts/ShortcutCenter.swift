// ShortcutCenter.swift — maps key presses to Bridge actions, with a setting for
// in-app vs global operation.
//
// Two engines, picked by the setting (reliability is the goal — OBS's hotkeys
// "randomly stop"; ours re-arm):
//   • IN-APP (always on when shortcuts are enabled): an NSEvent LOCAL monitor —
//     no permission, fires only while the Bridge is the key window.  PLAIN keys
//     (Space = Cut, 1–9 = camera); ignored while typing in a field.
//   • GLOBAL (opt-in + Input Monitoring): the ShortcutMonitor tap — fires even
//     when another app (e.g. OBS) is frontmost.  Plain keys are unusable globally
//     (they're normal typing), so global uses a CHORD: ⌃⌥ + the same key.
//
// Bindings are reassignable (see ShortcutBindings): each action has a rebindable
// BASE chord; the global engine adds ⌃⌥ on top of it.  Both engines resolve the
// incoming key through the same `bindings` table — one source of truth.

import Foundation
import AppKit
import CoreGraphics
import Combine

/// All members run on the main thread (init from App.init, the local monitor and
/// notifications on the main queue, the tap callback hops via main.async), so no
/// `@MainActor` annotation is needed — and that keeps it constructible from the
/// non-isolated `App.init`.
final class ShortcutCenter: ObservableObject {
    private let model: BridgeModel
    private let monitor = ShortcutMonitor()
    private var localMonitor: Any?
    private var watchdog: Timer?

    /// The reassignable binding table (exposed for the Settings UI).
    let bindings = ShortcutBindings()
    /// While the Settings recorder is capturing a key, suppress firing so the
    /// captured press doesn't also trigger an action.
    var isRecording = false

    /// Master enable.
    @Published var enabled: Bool { didSet { persist(); apply() } }
    /// Also fire while OTHER apps are frontmost (needs Input Monitoring; uses the
    /// ⌃⌥ chord).  Off = only while the Bridge is focused (plain keys, no permission).
    @Published var global: Bool { didSet { persist(); apply() } }
    /// Live Input-Monitoring grant state (for the Settings UI).
    @Published private(set) var hasPermission: Bool = ShortcutMonitor.hasPermission

    private enum Keys { static let enabled = "shortcuts.enabled"; static let global = "shortcuts.global" }

    init(model: BridgeModel) {
        self.model = model
        self.enabled = (UserDefaults.standard.object(forKey: Keys.enabled) as? Bool) ?? true
        self.global = (UserDefaults.standard.object(forKey: Keys.global) as? Bool) ?? false
        monitor.onKeyDown = { [weak self] keycode, flags in self?.handleGlobal(keycode, flags) }
        wireReArm()
        apply()
    }

    /// Request Input Monitoring (user-initiated), then re-arm once it lands.
    func requestPermission() {
        ShortcutMonitor.requestPermission()
        hasPermission = ShortcutMonitor.hasPermission
        apply()
    }

    private func persist() {
        UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        UserDefaults.standard.set(global, forKey: Keys.global)
    }

    /// Bring up the right engine(s) for the current settings.  Idempotent.
    private func apply() {
        hasPermission = ShortcutMonitor.hasPermission
        monitor.stop()
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        guard enabled else { return }
        // In-app (plain keys) is always available — no permission needed.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Return nil to SWALLOW the key when we fired a shortcut — otherwise the
            // unhandled key falls through the responder chain and AppKit plays the system
            // "funk" beep (an empty keypress).  Non-matching keys pass through unchanged.
            (self?.handleLocal(event) ?? false) ? nil : event
        }
        // Global (chord) layers on top when opted in + permitted.
        if global && hasPermission { monitor.ensureRunning() }
    }

    // MARK: - Event handling

    /// In-app: match the BASE chord (key + optional ⇧/⌘).  A ⌃ or ⌥ press is the
    /// global activator — leave it to the global engine.  Ignored while typing or
    /// while the recorder is capturing.
    /// Returns true when a shortcut MATCHED and fired — the monitor then swallows the key
    /// so it doesn't beep.  False (key passes through) while typing/recording, for the
    /// ⌃/⌥ global activator, or when nothing matches.
    @discardableResult
    private func handleLocal(_ event: NSEvent) -> Bool {
        guard enabled, !isRecording, !isTyping() else { return false }
        let mods = event.modifierFlags
        if mods.contains(.control) || mods.contains(.option) { return false }   // global chord
        if let action = bindings.action(forKeyCode: event.keyCode,
                                        shift: mods.contains(.shift),
                                        command: mods.contains(.command)) {
            fire(action)
            return true
        }
        return false
    }

    /// Global: require the ⌃⌥ activator, then match the base chord's ⇧/⌘ on top.
    private func handleGlobal(_ keycode: CGKeyCode, _ flags: CGEventFlags) {
        guard enabled, global, !isRecording else { return }
        guard flags.contains(.maskControl) && flags.contains(.maskAlternate) else { return }
        if let action = bindings.action(forKeyCode: UInt16(keycode),
                                        shift: flags.contains(.maskShift),
                                        command: flags.contains(.maskCommand)) {
            fire(action)
        }
    }

    /// Run an action — both engines route here.
    private func fire(_ action: ShortcutAction) {
        switch action.kind {
        case .cut:    model.cutAction()
        case .camera: model.programSelect(action.index)
        case .lens:   model.lensSelect(action.index)
        }
    }

    /// True while a text field / editor is first responder (so Space / digits go
    /// into the field, not the switcher).
    private func isTyping() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSText || responder is NSTextView
    }

    // MARK: - Re-arm (the reliability)

    private func wireReArm() {
        let nc = NotificationCenter.default
        // App activated — re-check the permission grant and re-arm.
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        }
        // Woke from sleep — the system may have killed the tap.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.monitor.ensureRunning()
        }
        // Backstop watchdog (a background app may miss activate/wake events).
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            if self?.global == true { self?.monitor.ensureRunning() }
        }
    }
}
