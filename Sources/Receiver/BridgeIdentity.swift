// BridgeIdentity.swift — device-level Bonjour identity for this Bridge install.
//
// Ported from AirliveStudioApp/Sources/ReceiverIdentity.swift, re-keyed for the
// Bridge namespace and lowered to `ObservableObject` (macOS 13 — the `@Observable`
// macro Studio uses needs macOS 14).
//
// Two stable fields are published in EVERY channel's Bonjour TXT so a
// channels-aware iPhone can GROUP this Bridge's sources under one device and
// survive renames (docs/MULTI-DEVICE-CHANNELS-SPEC.md §2, §4):
//
//   • `did` — per-install UUID, the grouping key.  Generated once, persisted;
//     survives relaunch AND rename.  Never shown to the user.
//   • `dev` — device/group display name, default "Airlive Bridge".  Editable;
//     persisted.  On change, every channel re-advertises its TXT.
//
// A single shared instance (`BridgeIdentity.shared`) is injected into each
// channel's receiver, so all channels of one Bridge advertise the same `did`/`dev`.

import Foundation

/// Device-level identity for THIS Bridge install, shared by every channel
/// receiver it advertises.
final class BridgeIdentity: ObservableObject {

    /// Process-wide shared identity — one `did`/`dev` per running Bridge.
    static let shared = BridgeIdentity()

    /// Stable per-install id — the iPhone picker groups this Bridge's channels
    /// under one device by this value.  Opaque; not user-facing.
    let did: String

    /// Editable device/group display name (default "Airlive Bridge").  Writing
    /// it persists immediately and re-advertises every channel's TXT.
    @Published var dev: String {
        didSet {
            guard dev != oldValue else { return }
            UserDefaults.standard.set(dev, forKey: Self.devKey)
            // Snapshot the hooks under the lock, then fire them OUTSIDE it — a
            // receiver's `readvertise` hops to its own queue, so holding the lock
            // across the call is unnecessary and risks lock-ordering surprises.
            readvertisersLock.lock()
            let hooks = Array(readvertisers.values)
            readvertisersLock.unlock()
            for readvertise in hooks { readvertise() }
        }
    }

    private static let didKey = "airlive.bridge.did"
    private static let devKey = "airlive.bridge.dev"
    /// Default group name — the brief's "Airlive Bridge", NOT the Mac host name,
    /// so multiple operators' Bridges don't all read as the same machine.
    static let defaultDeviceName = "Airlive Bridge"

    /// Per-channel re-advertise hooks, keyed by channel id.  A receiver
    /// registers its `readvertise()` here so a `dev` change re-publishes every
    /// channel's TXT live (matching Studio's `MultiCamReceiver` fan-out).
    /// Guarded by `readvertisersLock` — `register`/`unregister` run from the
    /// channel-lifecycle thread (UI) while `dev.didSet` may be set from any
    /// thread (e.g. a future settings import), so every access takes the lock.
    private var readvertisers: [UUID: () -> Void] = [:]
    private let readvertisersLock = NSLock()

    private init() {
        let defaults = UserDefaults.standard

        // did — generate once, then reuse forever.
        if let stored = defaults.string(forKey: Self.didKey) {
            did = stored
        } else {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: Self.didKey)
            did = fresh
        }

        // dev — persisted override, else the brief's default group name.
        dev = defaults.string(forKey: Self.devKey) ?? Self.defaultDeviceName
    }

    /// Register a channel receiver's re-advertise closure so a `dev` change
    /// re-publishes its TXT.  Called by the receiver on `start()`.
    func registerReadvertiser(_ id: UUID, _ readvertise: @escaping () -> Void) {
        readvertisersLock.lock(); defer { readvertisersLock.unlock() }
        readvertisers[id] = readvertise
    }

    /// Drop a channel receiver's re-advertise closure on `stop()` so a stopped
    /// receiver is never asked to re-advertise a torn-down listener.
    func unregisterReadvertiser(_ id: UUID) {
        readvertisersLock.lock(); defer { readvertisersLock.unlock() }
        readvertisers[id] = nil
    }
}
