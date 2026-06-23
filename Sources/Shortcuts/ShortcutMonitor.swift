// ShortcutMonitor.swift — reliable GLOBAL key-press tracker.
//
// Just the TRACKING STRUCTURE ported from Klyvo's KeyboardMonitor (a proven,
// in-the-field CGEventTap) — none of its app-specific bindings.  It only OBSERVES
// (`.listenOnly`); it never suppresses, so the focused app still gets the key.
//
// The whole point is reliability: macOS disables an event tap after a callback
// timeout or an input burst (sleep/wake, CPU spike, login transition).  If you
// don't re-arm it, global shortcuts "randomly stop working" until relaunch — the
// exact OBS bug we're avoiding.  So we re-enable INSIDE the callback on
// `.tapDisabledBy*`, and `ensureRunning()` rebuilds it on wake / activate / a
// watchdog tick.
//
// Needs Input Monitoring (not Accessibility) — the sandbox-safe permission for a
// listen-only tap.  Only used for the GLOBAL path; in-app shortcuts use a local
// NSEvent monitor (no permission), see ShortcutCenter.

import Foundation
import CoreGraphics
import AppKit

final class ShortcutMonitor {
    /// Fired on each initial key DOWN (autorepeat ignored), with keycode + active
    /// modifier flags.  Always delivered on the main queue.
    var onKeyDown: ((CGKeyCode, CGEventFlags) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private static weak var shared: ShortcutMonitor?

    var isRunning: Bool { eventTap != nil }

    /// Silent permission check — does NOT prompt (so the system sheet can't pop
    /// before our own UI asks for it).
    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Explicitly request Input Monitoring (shows the system prompt).  Call only
    /// from a user action (a Settings button).
    @discardableResult
    static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    func start() {
        guard CGPreflightListenEventAccess() else { return }   // not granted → idle
        guard eventTap == nil else { ensureRunning(); return }
        ShortcutMonitor.shared = self

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                guard let monitor = ShortcutMonitor.shared else {
                    return Unmanaged.passUnretained(event)
                }
                // System disabled the tap (callback timeout / input burst) →
                // re-enable, or the app goes permanently silent until relaunch.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown {
                    // Chords react to the initial press only — holding shouldn't
                    // ping-pong the action.
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if !isRepeat {
                        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                        let flags = event.flags
                        DispatchQueue.main.async { monitor.onKeyDown?(keyCode, flags) }
                    }
                }
                // listen-only NEVER returns nil — always pass the event through.
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )

        guard let tap = eventTap else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        if ShortcutMonitor.shared === self { ShortcutMonitor.shared = nil }
    }

    /// Make sure the tap is live AND enabled; rebuild it if a long sleep
    /// invalidated the port.  Safe to call anytime — a cheap no-op when healthy,
    /// a silent no-op without permission.
    func ensureRunning() {
        guard CGPreflightListenEventAccess() else { return }   // not permitted yet
        guard let tap = eventTap else { start(); return }      // idle → create
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)          // cheap re-enable
            if !CGEvent.tapIsEnabled(tap: tap) { stop(); start() }   // rebuild
        }
    }
}
