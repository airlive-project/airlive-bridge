// SettingsDraft.swift - the Settings window's not-yet-applied changes.
//
// The window works like OBS's: a change made in it is held here until Apply, and Cancel drops it
// (operator, 2026-10-07). Each field is an OVERRIDE, nil meaning "no change - show the live
// value", so every field the operator has not touched shows the current setting.
//
// Not held here, applied the moment they change (operator, 2026-10-07): the latency buffer and
// its lock (a director raises it ON AIR when a camera starts stuttering - it must act at once,
// like the rail's row), Shortcuts (a key is recorded when pressed, as in the ⌘K window) and the
// Stream Deck switch.
//
// The frame guide is held like everything else but SHOWN at once: while a guide change is pending,
// the Preview / Program panes draw it (FrameGuidePreview), so the operator sees what they pick;
// Cancel or closing takes it back off the panes.

import SwiftUI

final class SettingsDraft: ObservableObject {
    // Every field below is listed again in `hasChanges`, `apply` and `discard` - keep all four
    // in step when adding one (a field missing from `discard` would outlive Cancel).
    @Published var autoCut: AutoCutRange?
    @Published var recordFolder: URL?
    @Published var previewClickCuts: Bool?
    @Published var frameGuide: FrameGuide? {
        didSet { FrameGuidePreview.shared.guide = frameGuide }
    }
    @Published var frameGuideStyle: FrameGuideStyle? {
        didSet { FrameGuidePreview.shared.style = frameGuideStyle }
    }

    struct AutoCutRange: Equatable {
        var lo: Int
        var hi: Int
        var isValid: Bool { hi >= lo }
    }

    /// The lock on the latency buffer: the same UserDefaults key the Channels rail's
    /// `@AppStorage` reads, so one lock shows in both places.
    static let latencyLockKey = "bridge.latencyBufferLocked"
    /// Whether clicking a multiview camera that is ALREADY in Preview cuts it to Program (default
    /// on, so a quick double-click still cuts as it always did). Read by the tiles' `@AppStorage`.
    static let previewClickCutsKey = "bridge.previewClickCutsToProgram"

    var hasChanges: Bool {
        autoCut != nil || recordFolder != nil || previewClickCuts != nil
            || frameGuide != nil || frameGuideStyle != nil
    }

    /// Apply refuses a range the AUTO panel would refuse too.
    var canApply: Bool { hasChanges && (autoCut?.isValid ?? true) }

    /// A control's binding to one field: shows the pending value if there is one, else `stored`;
    /// choosing the stored value again clears the field, so "changed back" is not a change.
    func binding<T: Equatable>(_ field: ReferenceWritableKeyPath<SettingsDraft, T?>,
                               stored: T) -> Binding<T> {
        Binding(get: { self[keyPath: field] ?? stored },
                set: { self[keyPath: field] = $0 == stored ? nil : $0 })
    }

    func apply(model: BridgeModel) {
        guard canApply else { return }
        if let autoCut {
            model.autoSwitcher.minSeconds = autoCut.lo
            model.autoSwitcher.maxSeconds = autoCut.hi
        }
        // Safe even mid-take: a take keeps the folder it started in, the next one uses this.
        if let recordFolder { model.programRecorder.folder = recordFolder }
        let defaults = UserDefaults.standard
        if let previewClickCuts { defaults.set(previewClickCuts, forKey: Self.previewClickCutsKey) }
        // Stored before `discard` clears the preview, so the panes never flash the old guide.
        if let frameGuide { defaults.set(frameGuide.rawValue, forKey: FrameGuide.storageKey) }
        if let frameGuideStyle { defaults.set(frameGuideStyle.rawValue, forKey: FrameGuideStyle.storageKey) }
        discard()
    }

    func discard() {
        autoCut = nil
        recordFolder = nil
        previewClickCuts = nil
        frameGuide = nil
        frameGuideStyle = nil
    }
}
