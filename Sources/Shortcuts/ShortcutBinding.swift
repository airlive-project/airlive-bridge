// ShortcutBinding.swift — the reassignable binding table.
//
// Each Bridge action (Cut, Camera N, Lens N) maps to a BASE chord the operator
// can rebind.  The base is a key + optional ⇧/⌘; ⌃⌥ is reserved as the GLOBAL
// activator (added automatically in global mode so we never hijack plain typing
// in other apps — see ShortcutCenter), so it is never stored in a base chord.
//
// Bindings persist in UserDefaults as JSON; an unset action falls back to its
// default, so an empty store == stock layout (Space / 1–9 / Z X C V B N).

import Foundation
import AppKit

/// A base key combination: a key plus the operator-settable ⇧ / ⌘ flags.
struct KeyChord: Equatable, Codable {
    var keyCode: UInt16
    var shift: Bool = false
    var command: Bool = false

    /// Capture from a key event, dropping the reserved ⌃⌥ activator.
    init(event: NSEvent) {
        keyCode = event.keyCode
        shift = event.modifierFlags.contains(.shift)
        command = event.modifierFlags.contains(.command)
    }

    init(keyCode: UInt16, shift: Bool = false, command: Bool = false) {
        self.keyCode = keyCode; self.shift = shift; self.command = command
    }

    /// Human label with "+" between parts, e.g. "Space", "⇧+1", "⌘+Delete",
    /// "⇧+⌘+Z" (⇧ before ⌘ — Apple's modifier order).  The separator keeps a
    /// modifier+word chord readable ("⌘Delete" ran together in the chip).
    var display: String {
        var parts: [String] = []
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        parts.append(KeyNames.name(for: keyCode))
        return parts.joined(separator: "+")
    }
}

/// One rebindable action.  `camera`/`programCut`/`lens` carry a 0-based index.
///
/// The two-bus switcher keyboard: plain digit = channel → PREVIEW (safe bus, same
/// as clicking the tile), ⌘digit = channel → PROGRAM (direct cut).  Space = staged
/// cut, ⌘Delete = remove the selected channel (in-app only — see ShortcutCenter).
struct ShortcutAction: Identifiable, Hashable {
    enum Kind: String, Hashable { case cut, camera, programCut, lens, removeChannel }
    let kind: Kind
    let index: Int   // ignored for .cut / .removeChannel

    var id: String {
        switch kind {
        case .cut:           return "cut"
        case .removeChannel: return "removeChannel"
        default:             return "\(kind.rawValue)\(index)"
        }
    }

    var title: String {
        switch kind {
        case .cut:           return "Cut"
        case .camera:        return "Channel \(index + 1) → Preview"   // rail order, 1-based
        case .programCut:    return "Channel \(index + 1) → Program"
        case .lens:          return "Lens \(index + 1)"
        case .removeChannel: return "Remove Selected Channel"
        }
    }

    /// Stock binding: Cut = Space, Channel N → Preview = digit N, → Program = ⌘N,
    /// Lens N = the Z-row letter, Remove = ⌘Delete (Finder's delete idiom).
    /// Lenses sit on Z X C V B N (6 = the deepest lens ladder an iPhone reports) —
    /// one plain key per lens, mirroring the digits-for-cameras idea on the row below.
    var defaultChord: KeyChord {
        switch kind {
        case .cut:           return KeyChord(keyCode: 49)                               // Space
        case .camera:        return KeyChord(keyCode: KeyNames.digitKeyCode(index + 1)) // 1–9
        case .programCut:    return KeyChord(keyCode: KeyNames.digitKeyCode(index + 1),
                                             command: true)                             // ⌘1–⌘9
        case .lens:          return KeyChord(keyCode: Self.lensRowKeys[min(index, Self.lensRowKeys.count - 1)])
        case .removeChannel: return KeyChord(keyCode: 51, command: true)                // ⌘Delete
        }
    }

    /// Z X C V B N virtual keycodes (US layout) — the lens defaults.
    private static let lensRowKeys: [UInt16] = [6, 7, 8, 9, 11, 45]

    /// The full action set, in display order.
    static let all: [ShortcutAction] =
        [ShortcutAction(kind: .cut, index: 0),
         ShortcutAction(kind: .removeChannel, index: 0)]
        + (0 ..< 9).map { ShortcutAction(kind: .camera, index: $0) }
        + (0 ..< 9).map { ShortcutAction(kind: .programCut, index: $0) }
        + (0 ..< 6).map { ShortcutAction(kind: .lens, index: $0) }
}

/// The persisted, observable binding table.  Empty == all defaults.
final class ShortcutBindings: ObservableObject {
    @Published private(set) var custom: [String: KeyChord]

    private static let storeKey = "shortcuts.bindings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode([String: KeyChord].self, from: data) {
            custom = decoded
        } else {
            custom = [:]
        }
    }

    /// The effective chord for an action (custom override or its default).
    func chord(for action: ShortcutAction) -> KeyChord {
        custom[action.id] ?? action.defaultChord
    }

    /// True when the action has been rebound away from its default.
    func isCustomized(_ action: ShortcutAction) -> Bool { custom[action.id] != nil }

    /// Reverse lookup: which action owns this base chord (nil if none).
    func action(forKeyCode code: UInt16, shift: Bool, command: Bool) -> ShortcutAction? {
        let probe = KeyChord(keyCode: code, shift: shift, command: command)
        return ShortcutAction.all.first { chord(for: $0) == probe }
    }

    /// The action (other than `action`) already using `chord`, if any.
    func conflicting(_ chord: KeyChord, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.all.first { $0.id != action.id && self.chord(for: $0) == chord }
    }

    /// Assign `chord` to `action`.  Refuses (returns the clashing action) on a
    /// conflict so the caller can surface it instead of silently shadowing a key.
    @discardableResult
    func set(_ chord: KeyChord, for action: ShortcutAction) -> ShortcutAction? {
        if let clash = conflicting(chord, excluding: action) { return clash }
        custom[action.id] = chord
        persist()
        return nil
    }

    func reset(_ action: ShortcutAction) { custom[action.id] = nil; persist() }
    func resetAll() { custom = [:]; persist() }

    private func persist() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}

/// macOS virtual-keycode ↔ label helper (US layout) for the keys a switcher uses.
enum KeyNames {
    /// Keycode for the top-row digit 1...9 (and 0).
    static func digitKeyCode(_ digit: Int) -> UInt16 {
        switch digit {
        case 1: return 18; case 2: return 19; case 3: return 20
        case 4: return 21; case 5: return 23; case 6: return 22
        case 7: return 26; case 8: return 28; case 9: return 25
        case 0: return 29
        default: return 18
        }
    }

    static func name(for keyCode: UInt16) -> String {
        if let special = special[keyCode] { return special }
        if let letter = letters[keyCode] { return letter }
        if let digit = digits[keyCode] { return digit }
        return "Key \(keyCode)"
    }

    private static let special: [UInt16: String] = [
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 53: "Esc",
        51: "Delete", 117: "Fwd Del",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        24: "=", 27: "-", 33: "[", 30: "]", 41: ";", 39: "'",
        42: "\\", 43: ",", 47: ".", 44: "/", 50: "`",
    ]
    private static let digits: [UInt16: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    ]
    private static let letters: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
    ]
}
