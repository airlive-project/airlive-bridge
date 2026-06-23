// Channel.swift — one camera channel.
//
// A `BridgeChannel` is one receiver slot the iPhone connects to: it owns a
// `ChannelReceiver` (the TCP listener + Bonjour service + decoder, built in the
// receiver phase), publishes the latest decoded frame for preview, mirrors the
// camera's reported state, and fans every frame out to its downstream outputs.
//
// This file is FOUNDATION: the published surface and the public methods are
// final, but `start()` / `stop()` / `send(_:)` only wire to `receiver` once the
// receiver type exists.  The bodies here are minimal-but-correct — they manage
// the model-side state (isConnected, output fan-out gating) and forward to the
// receiver when present, so the receiver-phase agent only has to set `receiver`
// and implement `ChannelReceiver`.

import Foundation
import CoreVideo
import AVFoundation
import AppKit

/// One camera channel in the Bridge.  `ObservableObject` (not `@Observable`) so
/// it works on macOS 13 — the deployment target — where the `@Observable`
/// macro is unavailable.
final class BridgeChannel: ObservableObject, Identifiable {

    /// Stable routing id — survives rename and list reorder.
    let id: UUID

    /// Renameable, iPhone-facing source label.  Published in the receiver's
    /// Bonjour TXT (`src`) so a channels-aware iPhone shows this name.  Setting
    /// it directly only updates the model; use `rename(_:)` to also push the new
    /// name to the receiver.
    @Published var name: String

    /// True while an iPhone is connected to this channel's receiver.
    @Published var isConnected: Bool = false

    /// "Has a live picture" gate for the no-signal overlay — a LOW-FREQUENCY
    /// published flag, NOT the per-frame buffer.  Set once when video starts,
    /// nil on disconnect/clear; views read `latestFrame == nil` only to decide
    /// whether to show the "no signal" overlay (per-frame pixels go via the
    /// mirror path below, never through `@Published`, which froze preview on one
    /// frame and re-rendered the whole tree).
    @Published var latestFrame: CVPixelBuffer?

    // MARK: - Live frame mirroring (Studio's "decode once → show in many")
    //
    // The receiver calls `publishFrame` with each decoded buffer; MirrorVideoView
    // tiles observe `newFrameNotification` and point their OWN `CALayer.contents`
    // at `latestPixelBuffer`.  The same IOSurface-backed buffer can feed any
    // number of mirrors (multiview thumbnail + big Program + big Preview) with
    // zero extra decodes and no single-parent layer problem.

    static let newFrameNotification = Notification.Name("AirliveBridgeChannelNewFrame")

    private var _latestPixelBuffer: CVPixelBuffer?
    private let pixelBufferLock = NSLock()
    /// Thread-safe snapshot of the most recent decoded frame (read off-main by
    /// mirror tiles in their notification handler).
    var latestPixelBuffer: CVPixelBuffer? {
        pixelBufferLock.lock(); defer { pixelBufferLock.unlock() }
        return _latestPixelBuffer
    }

    /// Clockwise present rotation (0/90/180/270) from the camera's snapshot.  A
    /// plain Int read off-main by mirrors (atomic-enough, same trade-off as Studio).
    var outputRotation: Int = 0

    /// Receiver entry point: store the latest frame and notify mirrors.  Called on
    /// the receiver's present thread (OFF main) so a busy main thread can never
    /// freeze the live preview.  Pass nil to blank every mirror ("no signal").
    func publishFrame(_ buffer: CVPixelBuffer?) {
        pixelBufferLock.lock(); _latestPixelBuffer = buffer; pixelBufferLock.unlock()
        NotificationCenter.default.post(name: Self.newFrameNotification, object: self)
    }

    /// The camera's last-reported state (ISO, lens, fps, …).  Drives the remote
    /// control UI.  nil until the first `.control` snapshot arrives.
    @Published var remote: StateSnapshot?

    /// Operator toggle to hide this channel's preview (saves the per-frame
    /// CALayer update when the operator isn't watching it).  The receiver
    /// consults it to gate preview repaints.
    @Published var previewEnabled: Bool = true

    /// Jitter-buffer depth applied to this channel's output.  Forwarded live to
    /// the receiver so a mid-stream change re-anchors the playout timeline.
    @Published var delay: LatencyPreset = .normal {
        didSet {
            guard delay != oldValue else { return }
            receiver?.updateDelay(delay)
        }
    }

    /// Program tap: set by `BridgeModel` on the channel that is currently the
    /// program source (PGM in Multiview, the selected camera in Solo) and nil on
    /// every other channel.  The receiver calls it per presented frame so the
    /// program output (NDI/SRT/RTSP) gets THIS camera's frames — switching the
    /// source just moves the closure, the sender is never recreated.  Outputs are
    /// owned by the model's program bus, not per channel.
    var onProgramFrame: ((CVPixelBuffer, UInt64) -> Void)?

    // Receiver-password auth is GLOBAL (one password for the whole Bridge) and
    // lives on `BridgeModel`; the model pushes it to this channel's receiver via
    // `receiver.updateAuth(...)` on start and on change.  Nothing per-channel here.

    /// The owned receiver — TCP listener + Bonjour + decoder.  Forward-declared
    /// (`ChannelReceiver` is created in the receiver phase) and optional so this
    /// foundation file compiles standalone; the receiver phase assigns it in
    /// `start()` and the published bindings flow from it.
    var receiver: ChannelReceiver?

    init(id: UUID = UUID(), name: String, delay: LatencyPreset = .normal) {
        self.id = id
        self.name = name
        self.delay = delay
    }

    // MARK: - Lifecycle

    /// Bring the channel online: start the receiver (listener + Bonjour).
    /// Idempotent.  Outputs are NOT per-channel — they live on the model's program
    /// bus, fed via `onProgramFrame` when this channel is the program source.
    ///
    /// The concrete `BridgeChannelReceiver` is created lazily here (not in
    /// `init`) so an unstarted channel holds no listener / Bonjour service, and
    /// so the model layer can construct channels cheaply in tests.
    func start() {
        if receiver == nil {
            receiver = BridgeChannelReceiver(channel: self)
        }
        receiver?.start()
        // The global auth config is pushed to this receiver by `BridgeModel`
        // (right after start, and whenever it changes) — see BridgeModel.applyAuth.
    }

    /// Take the channel offline: stop the receiver, blank the mirrors, and clear
    /// the transient connection state so the UI reflects "not connected".
    ///
    /// The `@Published` writes must run on the main thread (SwiftUI state).  The
    /// sole current caller (`BridgeModel.removeChannel`) is already on main, but a
    /// future off-main caller must not tear SwiftUI state from a background thread
    /// — so the UI-side cleanup is hopped to main explicitly while the receiver
    /// teardown (thread-safe) runs inline.
    func stop() {
        onProgramFrame = nil
        receiver?.stop()
        publishFrame(nil)   // blank every mirror tile to black ("no signal")
        let clearUI = { [weak self] in
            guard let self else { return }
            self.isConnected = false
            self.latestFrame = nil
        }
        if Thread.isMainThread {
            clearUI()
        } else {
            DispatchQueue.main.async(execute: clearUI)
        }
    }

    // MARK: - Remote control

    /// Send a control command to the connected iPhone (Mac → iPhone).  No-op
    /// when no receiver / no connection is present.
    func send(_ msg: ControlMessage) {
        receiver?.send(msg)
    }

    // MARK: - Rename

    /// Rename the channel and push the new label to the receiver so the Bonjour
    /// TXT (`src`) updates for the iPhone.
    func rename(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        name = trimmed
        receiver?.rename(trimmed)
    }
}
