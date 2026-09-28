// DurationField.swift - a timecode entry box: `M:SS`, digits filling from the right.
//
// The colon is ALWAYS on screen, typing included. Four earlier attempts failed to deliver that,
// and every one failed the same way: something rewrote the field's STRING while the operator was
// editing it, and that string was then read back as input. Reformatting per keystroke fed its own
// padding in as digits (`6` rendered `0:06`, whose digits are `006`, so the next key parsed
// `0060`); a digits-only filter then ate the colon the formatter had just written, so `0:02`
// displayed as `002`.
//
// The cure is to stop having a string that anything can rewrite. This is NOT an editable text
// field: it is a view that owns its keystrokes. A buffer of up to four typed digits is the truth,
// the drawn text is a rendering of it, and nothing ever parses the rendering back. There is no
// field editor, no formatter and no text diffing, so there is nothing left to fight.
//
// The cost, accepted knowingly: no mouse caret, no selection, no paste. For a five-character
// timecode box that is a fair trade for a control that cannot misbehave.

import SwiftUI
import AppKit

/// Up to four typed digits read as `MMSS`, filling from the right: the last two are seconds, and
/// whatever precedes them is minutes. Seconds past 59 carry (`90` is 1:30) rather than being
/// refused - somebody typing 90 means ninety seconds.
struct DurationBuffer {
    private(set) var digits = ""
    /// The value is selected, so the next digit REPLACES it rather than appending. Without this,
    /// a field holding 0:02 turns 6,0,0,0 into 0:26 → 3:00 → 26:00 → 60:00: the right answer
    /// arrived at through three meaningless states.
    private var replacing: Bool

    init(seconds: Int, selected: Bool = true) {
        let m = seconds / 60, s = seconds % 60
        digits = m > 0 ? String(format: "%d%02d", m, s) : String(s)
        if digits.count > 4 { digits = String(digits.suffix(4)) }
        replacing = selected
    }

    mutating func insert(_ c: Character) {
        guard c.isASCII, c.isNumber else { return }
        if replacing { digits = ""; replacing = false }
        if digits.count == 4 { digits.removeFirst() }   // full: the oldest digit shifts out
        digits.append(c)
    }

    mutating func deleteBackward() {
        if replacing { digits = ""; replacing = false; return }
        if !digits.isEmpty { digits.removeLast() }
    }

    var seconds: Int {
        let n = Int(digits) ?? 0
        return min(n / 100 * 60 + n % 100, AutoSwitcher.maxAllowed)
    }

    /// What the operator reads. Always `M:SS`, empty buffer included, so the shape of the box
    /// never changes under them.
    var text: String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
}

struct DurationField: NSViewRepresentable {
    @Binding var seconds: Int
    /// Reported so the panel can draw its own focus ring.
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Return and Escape. Handed over explicitly rather than left to travel up the responder
    /// chain and hopefully reach the panel's buttons: a plain view is not a text control, and
    /// "hopefully" is not a behaviour.
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    func makeNSView(context: Context) -> KeyedDurationView {
        let v = KeyedDurationView()
        v.buffer = DurationBuffer(seconds: seconds)
        wire(v)
        return v
    }

    func updateNSView(_ v: KeyedDurationView, context: Context) {
        wire(v)
        // Adopt an outside change only while the operator is not typing into it.
        if !v.isEditing, v.buffer.seconds != seconds {
            v.buffer = DurationBuffer(seconds: seconds)
            v.needsDisplay = true
        }
    }

    private func wire(_ v: KeyedDurationView) {
        v.onChange = { seconds = max($0, AutoSwitcher.minAllowed) }
        v.onFocusChange = onFocusChange
        v.onSubmit = onSubmit
        v.onCancel = onCancel
    }
}

/// The view itself. Focusable, draws `M:SS`, and turns key presses into buffer operations.
final class KeyedDurationView: NSView, KeyboardCapturing {
    var buffer = DurationBuffer(seconds: 0) { didSet { needsDisplay = true } }
    var onChange: (Int) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    /// True from gaining focus until losing it: `updateNSView` must not overwrite the buffer
    /// mid-edit, which would undo the digit just typed.
    private(set) var isEditing = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func becomeFirstResponder() -> Bool {
        isEditing = true
        // Re-seed SELECTED, so the first digit replaces the whole value the way a selected
        // numeric field does everywhere else on this platform.
        buffer = DurationBuffer(seconds: buffer.seconds, selected: true)
        onFocusChange(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isEditing = false
        onFocusChange(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 51, 117:                                   // delete, forward delete
            buffer.deleteBackward()
            onChange(buffer.seconds)
        case 36, 76:                                    // return, enter
            onSubmit()
        case 53:                                        // escape
            onCancel()
        case 48:                                        // tab, and shift-tab
            focusAdjacentBox(backwards: event.modifierFlags.contains(.shift))
        default:
            // A chord is somebody's shortcut, not a digit: ⌘1 must not type a 1 into the box.
            let isChord = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            let digits = chars.filter { $0.isASCII && $0.isNumber }
            guard !isChord, !digits.isEmpty else { return super.keyDown(with: event) }
            for c in digits { buffer.insert(c) }
            onChange(buffer.seconds)
        }
    }

    /// Tab moves between timecode boxes and nowhere else. AppKit's own key loop runs through the
    /// WHOLE window, so from the last box it walked out of the panel into whatever field sat
    /// behind it - a channel's delay field, where the next digits would have landed (reproduced
    /// 2026-09-28). This walks the same loop but stops only on another box, so it cycles.
    private func focusAdjacentBox(backwards: Bool) {
        var visited = Set<ObjectIdentifier>()
        var candidate = backwards ? previousValidKeyView : nextValidKeyView
        while let view = candidate, view !== self, visited.insert(ObjectIdentifier(view)).inserted {
            if view is KeyedDurationView { window?.makeFirstResponder(view); return }
            candidate = backwards ? view.previousValidKeyView : view.nextValidKeyView
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(Theme.textPrimary),
            .paragraphStyle: p,
        ]
        let text = buffer.text as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(in: NSRect(x: 0, y: (bounds.height - size.height) / 2,
                             width: bounds.width, height: size.height),
                  withAttributes: attrs)
    }
}
