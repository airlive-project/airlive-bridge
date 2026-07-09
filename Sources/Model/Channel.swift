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

    /// What feeds this channel: the Airlive app (ARLV), a UVC capture card (HDMI),
    /// or AirPlay.  Decides which receiver `start()` builds.
    let kind: ChannelKind

    /// For `.capture` channels: the `AVCaptureDevice.uniqueID` of the capture card.
    let captureDeviceID: String?

    /// Renameable, iPhone-facing source label.  Published in the receiver's
    /// Bonjour TXT (`src`) so a channels-aware iPhone shows this name.  Setting
    /// it directly only updates the model; use `rename(_:)` to also push the new
    /// name to the receiver.
    @Published var name: String

    /// True while an iPhone is connected to this channel's receiver.
    @Published var isConnected: Bool = false {
        didSet { if isConnected != oldValue { onConnectivityChanged?() } }
    }

    /// Fired on main when EITHER transport's connected state flips (see `controlConnected`).
    /// The model uses it to re-assert tally to a (re)connected camera and clear a stale tally
    /// border from a fully-disconnected one.  Set by `BridgeModel` at channel creation.
    var onConnectivityChanged: (() -> Void)?

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

    /// Clockwise present rotation (0/90/180/270) from the camera's snapshot.  Written on main (the
    /// receiver's StateSnapshot apply), read OFF main by the mirror + aspect path — a plain Int there
    /// is a formal data race (a torn 0→90 read desyncs aspect vs transform). Guarded by its own lock.
    private var _outputRotation: Int = 0
    private let rotationLock = NSLock()
    var outputRotation: Int {
        get { rotationLock.lock(); defer { rotationLock.unlock() }; return _outputRotation }
        set { rotationLock.lock(); _outputRotation = newValue; rotationLock.unlock() }
    }

    /// On-screen aspect (width/height) derived from the LIVE buffer's real pixel
    /// dimensions: AirPlay reports a portrait iPhone screen, Airlive a landscape
    /// frame.  Preview panes bind to this so the image fits instead of floating in
    /// a fixed 16:9 box.  Updated only when it actually changes (never per frame).
    @Published var displayAspect: Double = 16.0 / 9.0
    private var _lastAspect: Double = 16.0 / 9.0
    /// Guards the `_lastAspect` compare-and-set.  `updateDisplayAspect` runs off main
    /// on the receiver's present thread; a combined "Screen Mirroring + Control" channel
    /// has TWO receivers (AirPlay video + control-side ARLV) that can both call
    /// `publishFrame`, so the read-compare-write must be atomic — same reasoning as
    /// `rotationLock` above.
    private let aspectLock = NSLock()

    /// Receiver entry point: store the latest frame and notify mirrors.  Called on
    /// the receiver's present thread (OFF main) so a busy main thread can never
    /// freeze the live preview.  Pass nil to blank every mirror ("no signal").
    func publishFrame(_ buffer: CVPixelBuffer?) {
        pixelBufferLock.lock(); _latestPixelBuffer = buffer; pixelBufferLock.unlock()
        if let buffer { updateDisplayAspect(buffer) }
        NotificationCenter.default.post(name: Self.newFrameNotification, object: self)
    }

    /// Recompute the display aspect from the buffer's real dims.  A 90/270 rotation
    /// hint (Airlive Option-B vertical: landscape buffer shown upright) swaps W/H.
    /// Off-main; publishes on main only on a real change to avoid per-frame hops.
    private func updateDisplayAspect(_ buffer: CVPixelBuffer) {
        let w = Double(CVPixelBufferGetWidth(buffer))
        let h = Double(CVPixelBufferGetHeight(buffer))
        guard w > 0, h > 0 else { return }
        let aspect = (outputRotation % 180 != 0) ? h / w : w / h
        aspectLock.lock()
        if abs(aspect - _lastAspect) < 0.001 { aspectLock.unlock(); return }
        _lastAspect = aspect
        aspectLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.displayAspect = aspect }
    }

    /// The camera's last-reported state (ISO, lens, fps, …).  Drives the remote
    /// control UI.  nil until the first `.control` snapshot arrives.
    @Published var remote: StateSnapshot? {
        didSet {
            // STICKY optimistic-lens reconcile.  Keep showing the operator's pick until EITHER the
            // camera confirms it, OR the camera moves to a genuinely DIFFERENT lens (changed on the
            // phone).  Do NOT drop it on a mere stale readback: some cameras keep reporting the old
            // lens for a beat after a switch, so a timeout-revert lit the OLD tile again even though
            // the video already changed — the "clicked 0.5×, top still shows 1×" bug.  No timeout.
            guard let p = pendingLens else { return }
            let newLens = remote?.lens
            if newLens == p {
                pendingLens = nil                 // confirmed → the camera drives the highlight again
            } else if newLens != oldValue?.lens {
                pendingLens = nil                 // camera jumped to a DIFFERENT lens (phone) → follow it
            }
            // else: lens unchanged and ≠ our pick → command still in flight → keep showing the pick
        }
    }

    // ── Peer protocol caps (from the camera's hello) ─────────────────────────────
    /// Capability strings the connected camera declared in its `hello` (e.g. "lut",
    /// "stabilization", "colorSpace", "focusPoint", "exposurePoint").  New-surface pickers gate
    /// on these — no flag (legacy camera) → that picker is hidden.  Cleared on disconnect.
    @Published var peerCaps: [String] = []
    func hasCap(_ c: String) -> Bool { peerCaps.contains(c) }

    // ── Optimistic lens selection ─────────────────────────────────────────────────
    /// Set the INSTANT the operator taps a lens tile (or hits its shortcut) so the blue highlight
    /// moves immediately on the Mac — instead of waiting the network round-trip for the camera's
    /// confirming `StateSnapshot`.  Sticky (see `remote.didSet`): the pick holds until the camera
    /// confirms it or genuinely switches to another lens.  nil → `remote.lens` drives the highlight.
    @Published var pendingLens: String?

    /// The lens the UI highlights: the optimistic pick if one is in flight, else the camera truth.
    var selectedLens: String? { pendingLens ?? remote?.lens }

    /// Tap/shortcut a lens: highlight it instantly (optimistic) AND send the command.
    func selectLens(_ label: String) {
        pendingLens = label
        send(.setLens(label))
    }

    // ── Delivery-mode / operator-gate accessors (read off `remote`; the camera is
    //    the source of truth — see docs/DELIVERY-MODE-DESIGN.md).  A nil snapshot
    //    (AirPlay / capture / pre-connect) reads the safe legacy default. ──────────
    /// Is the camera CURRENTLY sending its own Airlive video?  The UI keys its video
    /// tile off THIS, never off a requested mode (protocol invariant W1).  nil remote
    /// (AirPlay / capture) → true: those sources always carry their own video.  A combined
    /// "Screen Mirroring + Remote Control" channel is ALWAYS video-active — its picture is the
    /// AirPlay side, even though its ARLV control side reports `videoActive=false` (control-only).
    var videoActive: Bool {
        if kind == .screenMirroringPlusControl { return true }
        return remote?.videoActive ?? true
    }
    /// Operator's "Remote control" gate (default on).  Off → camera drops set-commands.
    var remoteControlAllowed: Bool { remote?.remoteControlAllowed ?? true }
    /// Operator's "Tally light" gate (default on).  Off → camera ignores tally cues.
    var tallyAllowed: Bool { remote?.tallyEnabled ?? true }
    /// Camera-side operator name (Settings → Live), for display / AirPlay binding.
    /// Empty unless an Airlive camera reported one.
    var cameraDeviceName: String { remote?.deviceName ?? "" }

    /// Operator toggle to hide this channel's preview (saves the per-frame
    /// CALayer update when the operator isn't watching it).  The receiver
    /// consults it to gate preview repaints.
    @Published var previewEnabled: Bool = true

    /// Jitter-buffer depth applied to this channel's output.  Forwarded live to
    /// the receiver so a mid-stream change re-anchors the playout timeline.
    // Default .lowest (0 ms): a LAN + our no-B-frame stream has low jitter, and present() feeds BOTH
    // the preview mirrors and the program/NDI output, so 0 cuts preview AND program latency together.
    // Per-channel + operator-tunable — bump to Normal/Smooth/Safe on a weak link.
    @Published var delay: LatencyPreset = .lowest {
        didSet {
            guard delay != oldValue else { return }
            receiver?.updateDelay(delay)
        }
    }

    /// Precise ADDITIONAL playout delay (ms) on top of `delay`'s preset — set in the
    /// channel's gear settings to align this source with slower cameras (multicam sync).
    /// Forwarded live to the receiver.
    @Published var extraDelayMs: Int = 0 {
        didSet {
            guard extraDelayMs != oldValue else { return }
            receiver?.updateExtraDelay(extraDelayMs)
        }
    }

    // MARK: - "Screen Mirroring + Remote Control" — two transports, one channel ("killer combo")
    //
    // A `.screenMirroringPlusControl` channel runs BOTH receivers for the SAME phone: an AirPlay
    // (UxPlay) receiver for VIDEO (`receiver`) and a control-only ARLV receiver for CONTROL +
    // tally (`controlReceiver`).  The phone screen-mirrors (video) AND connects the Airlive app
    // (control-only — no second encode, cool phone) to the same-named channel.  Video state
    // (isConnected / latestFrame / publishFrame) comes from the AirPlay side; control state
    // (`remote`, `controlConnected`) from the ARLV side.  See docs/DELIVERY-MODE-DESIGN.md.

    /// True while the ARLV control connection (Airlive app) is up.  Separate from `isConnected`
    /// (the video / AirPlay side) so one transport connecting doesn't imply the other.
    @Published var controlConnected: Bool = false {
        didSet { if controlConnected != oldValue { onConnectivityChanged?() } }
    }

    /// Whether the remote-control connection is live: the ARLV control side for a combined
    /// channel, else the channel's single connection.  Drives the control panel's enabled state.
    var remoteControlConnected: Bool {
        kind == .screenMirroringPlusControl ? controlConnected : isConnected
    }

    /// True when EITHER transport is live — the video side (`isConnected`) or the control side
    /// (`controlConnected`).  For a combined channel control can be up while video is down (or
    /// vice-versa); the rail status icon + delete-confirm guard key off this so a live control
    /// link is never shown as "disconnected".
    var anyConnected: Bool { isConnected || controlConnected }

    /// Only an ARLV (Airlive Camera) channel emits raw H.264 access units that the PASSTHROUGH
    /// outputs (OBS relay / RTSP / SRT) re-publish without transcoding.  AirPlay, combined
    /// (its video is AirPlay), and capture (BGRA) produce only DECODED frames — they can feed
    /// NDI but NOT the passthrough relays.  The model warns the operator when the program lacks
    /// this so those outputs don't go silently black.
    var producesRawH264: Bool { kind == .airlive }

    /// Program taps: set by `BridgeModel` on the channel that is currently the
    /// program source (PGM in Multiview, the selected camera in Solo) and nil on
    /// every other channel.  Switching the source just moves the closures.
    ///
    /// `onProgramFrame` — the DECODED frame, for buffer outputs (NDI).
    /// `onProgramSample` / `onProgramFormat` — the RAW H.264 ARLV payloads, for
    /// the passthrough relay to OBS (forward the camera's existing encode, no
    /// transcode).  `onProgramFormat` carries the length-prefixed SPS/PPS the
    /// camera resends each keyframe.
    var onProgramFrame: ((CVPixelBuffer, UInt64) -> Void)?
    var onProgramSample: ((Data, Int64) -> Void)?
    var onProgramFormat: ((Data) -> Void)?

    // Receiver-password auth is GLOBAL (one password for the whole Bridge) and
    // lives on `BridgeModel`; the model pushes it to this channel's receiver via
    // `receiver.updateAuth(...)` on start and on change.  Nothing per-channel here.

    /// The owned receiver — TCP listener + Bonjour + decoder.  For a combined channel this is
    /// the AirPlay (video) receiver; for every other kind it's the single receiver.
    var receiver: ChannelReceiver?

    /// The ARLV control-only receiver — ONLY for a `.screenMirroringPlusControl` channel (the
    /// Airlive app connects here for control + tally; the camera gates its video encoder).
    var controlReceiver: ChannelReceiver?

    init(id: UUID = UUID(), name: String, kind: ChannelKind = .airlive,
         captureDeviceID: String? = nil, delay: LatencyPreset = .lowest) {
        self.id = id
        self.name = name
        self.kind = kind
        self.captureDeviceID = captureDeviceID
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
    func start(order: Int = 0) {
        if receiver == nil {
            switch kind {
            case .capture:
                receiver = CaptureDeviceReceiver(channel: self, deviceID: captureDeviceID)
            case .airplay:
                receiver = AirPlayReceiver(channel: self, name: name)   // advertises as this Apple-TV name
            case .airlive:
                receiver = BridgeChannelReceiver(channel: self, order: order)
            case .screenMirroringPlusControl:
                // ONE channel, TWO transports for the same phone: AirPlay = video,
                // ARLV (control-only) = control + tally.  Same name so the phone sees one
                // "Camera X" in both Screen Mirroring and the Airlive app.
                receiver = AirPlayReceiver(channel: self, name: name)                       // video
                controlReceiver = BridgeChannelReceiver(channel: self, order: order, controlSide: true)  // control-only
            }
        }
        receiver?.start()
        controlReceiver?.start()
        // The global auth config is pushed to this channel's receiver(s) by `BridgeModel`
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
        onProgramFormat = nil
        onProgramSample = nil
        receiver?.stop()
        controlReceiver?.stop()
        publishFrame(nil)   // blank every mirror tile to black ("no signal")
        let clearUI = { [weak self] in
            guard let self else { return }
            self.isConnected = false
            self.controlConnected = false
            self.latestFrame = nil
        }
        if Thread.isMainThread {
            clearUI()
        } else {
            DispatchQueue.main.async(execute: clearUI)
        }
    }

    // MARK: - Remote control

    /// Send a control command to the connected iPhone (Mac → iPhone).  Routes to the control
    /// connection — the ARLV control receiver for a combined channel (AirPlay has no
    /// back-channel), else the single receiver.  No-op when nothing is connected.
    func send(_ msg: ControlMessage) {
        (controlReceiver ?? receiver)?.send(msg)
    }

    // MARK: - Rename

    /// Rename the channel and push the new label to both receivers so the Bonjour TXT (`src`)
    /// and the AirPlay advertise name update for the iPhone.
    func rename(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        name = trimmed
        receiver?.rename(trimmed)
        controlReceiver?.rename(trimmed)
    }

    // MARK: - Fan-out to both receivers (combined channel)

    /// Push the global auth config to every receiver this channel owns.  AirPlay no-ops it;
    /// the ARLV receiver(s) apply it.
    func updateAuth(require: Bool, password: String, disconnectNow: Bool) {
        receiver?.updateAuth(require: require, password: password, disconnectNow: disconnectNow)
        controlReceiver?.updateAuth(require: require, password: password, disconnectNow: disconnectNow)
    }

    /// Advertise this channel's order on every receiver (ARLV uses it; AirPlay no-ops).
    func updateOrder(_ index: Int) {
        receiver?.updateOrder(index)
        controlReceiver?.updateOrder(index)
    }

    /// Mark whether this channel feeds the program bus, on every receiver (H1 gate).
    func setProgramSource(_ isProgram: Bool) {
        receiver?.setProgramSource(isProgram)
        controlReceiver?.setProgramSource(isProgram)
    }
}
