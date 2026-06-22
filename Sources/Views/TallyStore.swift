// TallyStore.swift — UI-side memory of each channel's tally cue.
//
// The foundation `BridgeChannel` has no tally property: tally is a COMMAND
// (`ControlMessage.setCue`) the Mac sends to the iPhone, not channel state.  But
// the UI needs to remember what the operator last cued so two surfaces agree —
// the Channels-rail hint square and the center-pane Program/Preview/Off buttons
// must show the same thing — and so the selection survives re-renders.
//
// This is a tiny `ObservableObject` keyed by channel id.  It's purely
// presentational (the authoritative tally lives on the iPhone once the cue is
// sent); keeping it out of the model layer respects the frozen foundation
// contract while still giving the views one source of truth.

import SwiftUI

/// The three tally positions a channel can be cued to.  Raw values match the
/// wire strings `ControlMessage.setCue(_:)` expects.
enum TallyState: String, CaseIterable, Identifiable {
    case off     = "none"
    case preview = "preview"
    case program = "program"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:     return "Off"
        case .preview: return "Preview"
        case .program: return "Program"
        }
    }

    /// Accent for this position: red Program, yellow Preview, neutral Off.
    var accent: Color {
        switch self {
        case .off:     return Theme.textFaint
        case .preview: return Theme.accentYellow
        case .program: return Theme.accentRed
        }
    }
}

/// Shared, observable per-channel tally memory.  `shared` is the single app-wide
/// instance the rail hint and the center pane both read/write, so they never
/// disagree.  Mutations publish so SwiftUI re-renders both surfaces.
final class TallyStore: ObservableObject {
    static let shared = TallyStore()

    @Published private var states: [UUID: TallyState] = [:]

    private init() {}

    /// Current cue for a channel (defaults to `.off` for an unseen channel).
    func state(for id: UUID) -> TallyState {
        states[id] ?? .off
    }

    /// Record a new cue for a channel.  The caller is responsible for also
    /// sending the matching `ControlMessage.setCue` on the channel.
    func set(_ state: TallyState, for id: UUID) {
        states[id] = state
    }

    /// Forget a channel (call on remove so the dictionary doesn't leak ids).
    func clear(_ id: UUID) {
        states.removeValue(forKey: id)
    }
}
