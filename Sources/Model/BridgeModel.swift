// BridgeModel.swift — top-level app state.
//
// Owns the list of channels and the current selection.  ContentView creates it
// as a `@StateObject`; the three zones (Channels rail | Selected channel +
// control | Outputs) observe it.  Pure model state + selection helpers — no
// networking lives here (each channel owns its own receiver).

import Foundation

/// Application-level state for Airlive Bridge.  `ObservableObject` for macOS 13
/// compatibility (see `BridgeChannel`).
final class BridgeModel: ObservableObject {

    /// All channels, in display order.
    @Published var channels: [BridgeChannel] = []

    /// Currently-selected channel's id (drives the center zone), or nil when
    /// none is selected.
    @Published var selectedID: UUID?

    init() {}

    // MARK: - Selection helpers

    /// The currently-selected channel, or nil.
    var selectedChannel: BridgeChannel? {
        guard let selectedID else { return nil }
        return channels.first { $0.id == selectedID }
    }

    /// Select a channel by id (no-op if it isn't in the list).
    func select(_ id: UUID) {
        guard channels.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    // MARK: - Channel management

    /// Create a new channel with an auto-numbered default name, append it, and
    /// select it.  Returns the new channel.
    @discardableResult
    func addChannel() -> BridgeChannel {
        let channel = BridgeChannel(name: defaultChannelName())
        channels.append(channel)
        selectedID = channel.id
        return channel
    }

    /// Stop and remove the channel with `id`, fixing up the selection if the
    /// removed channel was selected (falls back to the previous channel, or nil
    /// when the list becomes empty).
    func removeChannel(_ id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].stop()
        channels.remove(at: index)

        guard selectedID == id else { return }
        if channels.isEmpty {
            selectedID = nil
        } else {
            // Prefer the channel that took the removed one's slot; else the last.
            selectedID = channels[min(index, channels.count - 1)].id
        }
    }

    // MARK: - Private

    /// "Camera N" using the lowest free index, so removing CAM 2 and adding
    /// again reuses "Camera 2" rather than ever-increasing numbers.
    private func defaultChannelName() -> String {
        let used = Set(channels.map(\.name))
        var n = 1
        while used.contains("Camera \(n)") { n += 1 }
        return "Camera \(n)"
    }
}
