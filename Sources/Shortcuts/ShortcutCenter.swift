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
// Bindings are fixed for now (reassignable later); the action mapping is the one
// source of truth both engines call.

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
            self?.handleLocal(event)
            return event   // never suppress
        }
        // Global (chord) layers on top when opted in + permitted.
        if global && hasPermission { monitor.ensureRunning() }
    }

    // MARK: - Event handling

    /// In-app: plain key → program/cut; ⇧+digit → lens.  Ignored while typing.
    private func handleLocal(_ event: NSEvent) {
        guard enabled, !isTyping() else { return }
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if mods.isEmpty {
            fire(CGKeyCode(event.keyCode))
        } else if mods == [.shift] {
            fireLens(CGKeyCode(event.keyCode))
        }
    }

    /// Global: requires the ⌃⌥ chord (plain keys would fire on normal typing);
    /// add ⇧ for lens.
    private func handleGlobal(_ keycode: CGKeyCode, _ flags: CGEventFlags) {
        guard enabled, global else { return }
        guard flags.contains(.maskControl) && flags.contains(.maskAlternate) else { return }
        if flags.contains(.maskShift) { fireLens(keycode) } else { fire(keycode) }
    }

    /// Program / cut bindings — both engines route here.
    private func fire(_ keycode: CGKeyCode) {
        switch keycode {
        case 49: model.cutAction()                                   // Space → Cut / take
        default:
            if let n = Self.digit(for: keycode) { model.programSelect(n - 1) }   // 1–9 → camera N
        }
    }

    /// Lens bindings — ⇧+digit N → the focused camera's Nth lens.
    private func fireLens(_ keycode: CGKeyCode) {
        if let n = Self.digit(for: keycode) { model.lensSelect(n - 1) }
    }

    /// macOS keycodes for the top-row digits 1...9.
    private static func digit(for keycode: CGKeyCode) -> Int? {
        switch keycode {
        case 18: return 1; case 19: return 2; case 20: return 3
        case 21: return 4; case 23: return 5; case 22: return 6
        case 26: return 7; case 28: return 8; case 25: return 9
        default: return nil
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
