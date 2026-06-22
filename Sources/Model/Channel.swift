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

    /// "Has a live picture" gate for the preview overlay — a LOW-FREQUENCY
    /// published flag, NOT a per-frame buffer.  It is set (to the first decoded
    /// buffer) exactly once when video starts, and cleared (nil) on disconnect /
    /// format change; it does NOT change per frame.  The actual per-frame pixels
    /// are enqueued into `displayLayer` (a Metal-backed
    /// `AVSampleBufferDisplayLayer`), never through this `@Published` — routing
    /// video frames through `@Published` only repaints on SwiftUI's diff cycle
    /// and froze the preview on one frame.  Views read `latestFrame == nil` only
    /// to decide whether to show the "no signal" overlay; they must NOT use it as
    /// the live frame source (use `PreviewView(channel:)`).
    ///
    /// Typed `CVPixelBuffer` (not the `CVImageBuffer` super-type it aliases) so
    /// the seam matches the receiver, which only ever hands over decoded
    /// `CVPixelBuffer`s — no ambiguity for a future caller reaching for a
    /// pixel-buffer-only API.
    @Published var latestFrame: CVPixelBuffer?

    /// Canonical live-preview surface for this channel — a Metal-backed
    /// `AVSampleBufferDisplayLayer` the receiver enqueues each decoded frame
    /// into (wrapped in a `CMSampleBuffer` with timing) and `PreviewView` simply
    /// HOSTS.  Owned HERE, not in the view, so it survives SwiftUI re-creating
    /// `PreviewView` (the layer outlives the view tree, the way Studio owns its
    /// display layer on the receiver) — that removes the "view rebuilds → frame
    /// pipe goes nil" fragility a per-view closure pipe had.  It is deliberately
    /// NOT `@Published`: enqueuing frames into it never touches SwiftUI state, so
    /// the preview repaints at the capture rate with zero per-frame diff cost.
    /// `AVSampleBufferDisplayLayer` is available since macOS 10.8.
    let displayLayer: AVSampleBufferDisplayLayer

    /// Clear the live-preview surface to black ("no signal").  Called by the
    /// receiver on disconnect / format change so a stale last frame doesn't
    /// linger under the overlay.  NOT `@Published` — it flushes the owned
    /// `displayLayer` directly.
    var onClear: (() -> Void)?

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

    /// Downstream re-publishing sinks (NDI / SRT / RTSP).
    @Published var outputs: [VideoOutput] = []

    /// The owned receiver — TCP listener + Bonjour + decoder.  Forward-declared
    /// (`ChannelReceiver` is created in the receiver phase) and optional so this
    /// foundation file compiles standalone; the receiver phase assigns it in
    /// `start()` and the published bindings flow from it.
    var receiver: ChannelReceiver?

    init(id: UUID = UUID(), name: String, delay: LatencyPreset = .normal) {
        self.id = id
        self.name = name
        self.displayLayer = AVSampleBufferDisplayLayer()
        // Letterbox / downscale on the GPU for free — a 4K buffer in a small
        // pane costs nothing extra; black backing so an empty layer reads as
        // "no signal" rather than transparent.
        self.displayLayer.videoGravity = .resizeAspect
        self.displayLayer.backgroundColor = NSColor.black.cgColor
        // Default-clear flushes the owned layer to black.  `flushAndRemoveImage`
        // drops the queued sample and blanks the layer in one call.
        self.delay = delay
        self.onClear = { [weak self] in
            self?.displayLayer.flushAndRemoveImage()
        }
    }

    // MARK: - Lifecycle

    /// Bring the channel online: start the receiver (listener + Bonjour) and all
    /// configured outputs.  Idempotent — safe to call when already started.
    ///
    /// The concrete `BridgeChannelReceiver` is created lazily here (not in
    /// `init`) so an unstarted channel holds no listener / Bonjour service, and
    /// so the model layer can construct channels cheaply in tests.
    func start() {
        if receiver == nil {
            receiver = BridgeChannelReceiver(channel: self)
        }
        receiver?.start()
        for output in outputs where !output.isLive {
            output.start()
        }
    }

    /// Take the channel offline: stop outputs and the receiver, and clear the
    /// transient connection state so the UI reflects "not connected".
    ///
    /// The `@Published` writes and the `onClear` layer flush must run on the
    /// main thread (SwiftUI state + CALayer).  The sole current caller
    /// (`BridgeModel.removeChannel`) is already on main, but a future off-main
    /// caller must not tear SwiftUI state from a background thread — so the
    /// UI-side cleanup is hopped to main explicitly while the receiver/output
    /// teardown (thread-safe) runs inline.
    func stop() {
        for output in outputs where output.isLive {
            output.stop()
        }
        receiver?.stop()
        let clearUI = { [weak self] in
            guard let self else { return }
            self.isConnected = false
            self.latestFrame = nil
            self.onClear?()
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

    // MARK: - Output management

    /// Attach a downstream output.  Starts it immediately if the channel is
    /// already live so the new sink begins publishing without a restart.
    func addOutput(_ output: VideoOutput) {
        outputs.append(output)
        if isConnected { output.start() }
    }

    /// Detach and stop a downstream output by identity.
    func removeOutput(_ output: VideoOutput) {
        output.stop()
        outputs.removeAll { $0.id == output.id }
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
