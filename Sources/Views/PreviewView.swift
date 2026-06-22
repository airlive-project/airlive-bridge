// PreviewView.swift — live-frame surface for one channel.
//
// Renders a `BridgeChannel`'s decoded frames by HOSTING the channel's own
// `AVSampleBufferDisplayLayer` — the canonical Apple path for a continuous
// CVPixelBuffer / CMSampleBuffer stream, ported from Studio's `LiveVideoView`
// (which hosts a provider-owned layer).  The design points that keep the
// preview live and re-creation-proof:
//
//   • The display layer is owned by the CHANNEL (`channel.displayLayer`), not
//     by this view.  SwiftUI re-instantiates `NSViewRepresentable`s freely;
//     because the layer outlives the view, a re-created `PreviewView` just
//     re-attaches the SAME layer (no frame pipe to re-wire, nothing to go nil).
//     The receiver enqueues every decoded frame straight into that layer.
//   • `AVSampleBufferDisplayLayer` is Metal-backed and owns its display timing;
//     we enqueue frames for IMMEDIATE display (the receiver's jitter ring
//     already gated latency), so the layer paints what it's handed.
//   • `videoGravity = .resizeAspect` letterboxes / downscales on the GPU for
//     free, so a 4K buffer in a small pane costs nothing extra.
//   • The low-frequency rotation hint (`StateSnapshot.outputRotation`) flows the
//     normal SwiftUI way via `updateNSView` — it changes a handful of times per
//     session, not per frame.
//
// A legacy `PreviewView(frame:rotation:enabled:)` initialiser is kept for
// callers that hand a single buffer; it hosts its OWN plain `CALayer` and points
// `contents` straight at the (IOSurface-backed) buffer — the zero-copy path
// Studio's `MirrorVideoView` ships.  Prefer `PreviewView(channel:)` for live
// video.

import SwiftUI
import AppKit
import AVFoundation
import CoreVideo

/// SwiftUI wrapper that renders a channel's decoded frames.
///
/// Primary use is `PreviewView(channel:)` — hosts the channel-owned
/// `AVSampleBufferDisplayLayer` the receiver enqueues into.  A
/// `PreviewView(frame:rotation:enabled:)` initialiser is kept for callers that
/// still hand a single buffer.
struct PreviewView: NSViewRepresentable {

    /// The channel to stream from, when using the display-layer path.  nil for
    /// the legacy single-frame initialiser.
    private let channel: BridgeChannel?

    /// Legacy single-frame value (only set by the `frame:` initialiser).
    private let staticFrame: CVPixelBuffer?

    /// Clockwise rotation hint (StateSnapshot.outputRotation): 0 / 90 / 180 /
    /// 270.  The iPhone always sends landscape pixels; we rotate at present.
    private let rotation: Int

    /// When false we render nothing and clear contents (preview hidden — the
    /// caller shows its own placeholder, this just avoids holding a buffer).
    private let enabled: Bool

    /// Live path — preferred for video.  Hosts `channel.displayLayer`, which the
    /// receiver enqueues every decoded frame into.
    init(channel: BridgeChannel) {
        self.channel = channel
        self.staticFrame = nil
        self.rotation = channel.remote?.outputRotation ?? 0
        self.enabled = channel.previewEnabled
    }

    /// Legacy single-frame init — kept so existing call sites compile.  Hosts a
    /// plain layer and points its `contents` at the buffer the caller passes per
    /// body eval.
    init(frame: CVPixelBuffer?, rotation: Int = 0, enabled: Bool = true) {
        self.channel = nil
        self.staticFrame = frame
        self.rotation = rotation
        self.enabled = enabled
    }

    func makeNSView(context: Context) -> Surface {
        let surface = Surface()
        configure(surface)
        return surface
    }

    func updateNSView(_ nsView: Surface, context: Context) {
        configure(nsView)
    }

    /// Push the current attachment + rotation into the surface.  For the live
    /// path that's the channel's display layer (re-attached idempotently so a
    /// re-created view re-hosts the same layer); for the legacy path it's the
    /// single static buffer.
    private func configure(_ surface: Surface) {
        if let channel {
            surface.attach(displayLayer: channel.displayLayer, rotation: rotation)
        } else {
            surface.show(staticFrame: enabled ? staticFrame : nil, rotation: rotation)
        }
    }

    // MARK: - Surface (hosted-layer NSView)

    /// NSView that hosts either the channel's `AVSampleBufferDisplayLayer` (live
    /// path) or a plain `CALayer` whose `contents` we set (legacy single-frame
    /// path).  The hosted layer is laid out to fill `bounds` and the rotation
    /// transform is applied to it.
    final class Surface: NSView {
        /// The currently-hosted layer (channel display layer OR the legacy plain
        /// layer).  Weak for the channel-owned case (the channel owns it);
        /// `legacyLayer` keeps the legacy one alive.
        private weak var hostedLayer: CALayer?
        /// Owned plain layer for the legacy `frame:` path only.
        private var legacyLayer: CALayer?
        private var rotation: Int = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        /// Host the channel-owned display layer (live path).  Idempotent — a
        /// re-created `PreviewView` re-attaches the SAME layer, so we no-op if
        /// it's already hosted (beyond refreshing the rotation).
        func attach(displayLayer: AVSampleBufferDisplayLayer, rotation: Int) {
            self.rotation = rotation
            if hostedLayer !== displayLayer {
                swapHosted(displayLayer)
            }
            applyRotation()
        }

        /// Legacy path: host a plain layer and point its `contents` at `buffer`.
        /// `CALayer.contents = <IOSurface-backed CVPixelBuffer>` is the zero-copy
        /// path Studio's MirrorVideoView ships — no CIContext / CGImage copy.
        func show(staticFrame buffer: CVPixelBuffer?, rotation: Int) {
            self.rotation = rotation
            let plain: CALayer
            if let legacyLayer, hostedLayer === legacyLayer {
                plain = legacyLayer
            } else {
                plain = CALayer()
                plain.contentsGravity = .resizeAspect
                plain.backgroundColor = NSColor.black.cgColor
                legacyLayer = plain
                swapHosted(plain)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            plain.contents = buffer   // nil → black (no signal)
            CATransaction.commit()
            applyRotation()
        }

        /// Replace the hosted layer, dropping any previous sublayers so we never
        /// accumulate them across attach/show swaps.
        private func swapHosted(_ newLayer: CALayer) {
            layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            // The legacy plain layer is only kept alive while it is the hosted
            // one; clear the strong ref when swapping to the channel layer so it
            // deallocates.
            if newLayer !== legacyLayer { legacyLayer = nil }
            layer?.addSublayer(newLayer)
            hostedLayer = newLayer
            newLayer.contentsScale = window?.backingScaleFactor ?? 2.0
            needsLayout = true
        }

        /// Apply the rotation hint to the hosted layer.  Option B vertical
        /// stream: the iPhone sends LANDSCAPE pixels + a clockwise rotation hint.
        /// NEGATED angle — a hosting (non-flipped, y-up) layer rotates CCW for a
        /// positive angle, so negate to get the clockwise rotation the phone's
        /// upright preview expects.
        private func applyRotation() {
            guard let hostedLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer.transform = (rotation == 0)
                ? CATransform3DIdentity
                : CATransform3DMakeRotation(-CGFloat(rotation) * .pi / 180, 0, 0, 1)
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer?.frame = bounds
            CATransaction.commit()
        }

        // A hosted layer's contentsScale is NOT auto-synced by AppKit, so a pane
        // can render half-res on a 2× display.  Read the backing scale on main
        // (NSWindow is main-only) and push it to the hosted layer.
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            let scale = window?.backingScaleFactor ?? 2.0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer?.contentsScale = scale
            CATransaction.commit()
        }
    }
}
