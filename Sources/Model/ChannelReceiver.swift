// ChannelReceiver.swift — the receiver seam.
//
// FOUNDATION placeholder for the type the receiver phase builds.  A
// `ChannelReceiver` owns one channel's TCP listener + Bonjour service + decoder:
// it accepts ONE iPhone, decodes its frames, and reports state back into the
// owning `BridgeChannel`'s published properties.
//
// Defining it here as a protocol gives `BridgeChannel` a stable, compile-ready
// seam to call (`start` / `stop` / `send` / `rename`) without depending on the
// not-yet-written networking class.  The receiver-phase agent writes a concrete
// `final class` conforming to this protocol (porting Studio's `CamSlotReceiver`)
// and assigns an instance to `BridgeChannel.receiver`.  Extending this protocol
// is allowed; the four members below are the contract `BridgeChannel` relies on.

import Foundation

/// One channel's network receiver — listener, Bonjour advertisement, and
/// decoder.  The owning `BridgeChannel` drives its lifecycle and forwards
/// remote-control commands through it; the receiver pushes decoded frames and
/// state snapshots back onto the channel's `@Published` properties.
protocol ChannelReceiver: AnyObject {
    /// Open the TCP listener and advertise the Bonjour service so the iPhone can
    /// discover and connect.  Idempotent.
    func start()

    /// Close the listener, drop any active connection, and stop advertising.
    func stop()

    /// Forward a control command to the connected iPhone (Mac → iPhone).  No-op
    /// when no iPhone is connected.
    func send(_ msg: ControlMessage)

    /// Update the published source label (Bonjour TXT `src`) without tearing the
    /// service down.
    func rename(_ newName: String)

    /// Publish this channel's ORDER index (Bonjour TXT `ord`) so the iPhone can
    /// list channels in the operator's Bridge order — independent of the (freely
    /// renameable) display name.  Re-advertises live; no teardown.
    func updateOrder(_ index: Int)

    /// Apply a live change to the playout-delay preset (jitter-buffer depth).
    /// Re-anchors and drops frames queued under the old depth.  Added to the
    /// foundation seam so `BridgeChannel` can forward `delay` changes without a
    /// concrete-type dependency.
    func updateDelay(_ preset: LatencyPreset)

    /// Additional fixed playout delay (ms) ON TOP of `updateDelay`'s preset — the precise
    /// per-source latency the operator dials in the channel's gear settings to align this
    /// source with slower ones (multicam sync).  0 = none.
    func updateExtraDelay(_ ms: Int)

    /// Apply the receiver-password auth config live (STREAM-AUTH-SPEC §4).
    /// `require && !password.isEmpty` turns the challenge-response on for the
    /// NEXT connection; `disconnectNow` additionally drops a currently-connected
    /// camera so a password change forces an immediate re-auth (revocation).
    func updateAuth(require: Bool, password: String, disconnectNow: Bool)

    /// Tell the receiver whether THIS channel currently feeds the program bus, so it can
    /// gate per-frame program taps (skip the main-thread hop on non-program channels — the
    /// 5-camera scale win, H1).  Default no-op: only the ARLV receiver carries the raw
    /// sample/format relay taps that make this worth gating.
    func setProgramSource(_ isProgram: Bool)
}

extension ChannelReceiver {
    func setProgramSource(_ isProgram: Bool) {}   // default no-op (AirPlay / capture)
}
