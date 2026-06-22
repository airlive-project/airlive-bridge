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

    // MARK: - Security (ONE global password for the whole Bridge)
    //
    // The operator sets a single password that gates EVERY channel (simpler than
    // per-channel for a solo director).  The wire is still per-connection HMAC —
    // we just feed every channel's receiver the same secret.  Stored in the
    // Keychain (one account); OFF by default unless a password exists at launch.

    /// Keychain account for the single global Bridge password.
    private static let authAccount = "global"

    /// Require a password on every channel.  Pushed to all receivers on change.
    @Published var requireAuth: Bool {
        didSet {
            guard requireAuth != oldValue else { return }
            pushAuthToAll(disconnectNow: false)
        }
    }

    /// True when a global password is stored (drives the UI without reading the
    /// secret into a published property).
    var hasPassword: Bool { BridgeKeychain.password(account: Self.authAccount) != nil }

    init() {
        // Persist auth across launches via the Keychain's presence: if a password
        // was set last time, come up locked.  (didSet is not triggered by the
        // initializer, and there are no channels yet, so nothing to push.)
        requireAuth = BridgeKeychain.password(account: Self.authAccount) != nil
    }

    /// Set (or clear) the global password.  Stored in the Keychain, then pushed
    /// to every channel.  A password change is a REVOCATION (`disconnectNow`) so
    /// currently-connected cameras drop and must re-auth with the new secret.
    func setPassword(_ password: String) {
        BridgeKeychain.setPassword(password, account: Self.authAccount)
        objectWillChange.send()                 // `hasPassword` is derived
        pushAuthToAll(disconnectNow: true)
    }

    /// Push the current global auth config to every channel's receiver.
    func pushAuthToAll(disconnectNow: Bool) {
        let password = BridgeKeychain.password(account: Self.authAccount) ?? ""
        for channel in channels {
            channel.receiver?.updateAuth(require: requireAuth, password: password,
                                         disconnectNow: disconnectNow)
        }
    }

    /// Push the global auth config to ONE channel (used when a fresh channel's
    /// receiver comes online, so its very first connection is gated correctly).
    private func applyAuth(to channel: BridgeChannel) {
        let password = BridgeKeychain.password(account: Self.authAccount) ?? ""
        channel.receiver?.updateAuth(require: requireAuth, password: password,
                                     disconnectNow: false)
    }

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
        channel.start()             // bring the receiver + Bonjour online
        applyAuth(to: channel)      // gate it with the current global password
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
