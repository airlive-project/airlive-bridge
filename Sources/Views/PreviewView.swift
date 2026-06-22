// PreviewView.swift — DIRECT live-frame surface for one channel.
//
// Renders a `BridgeChannel`'s decoded frames by pointing a hosted CALayer's
// `contents` straight at each IOSurface-backed `CVPixelBuffer` the receiver
// decodes — the thermal-safe "decode once → show" path ported from Studio's
// MirrorVideoView.  The CRITICAL difference from a naïve SwiftUI binding:
//
//   • The per-frame buffer is pushed through the channel's DIRECT pipe
//     (`channel.onFrame`), NOT a `@Published` property.  A `@Published` frame
//     only repaints on SwiftUI's diff cycle, so the preview froze on one
//     frame; routing pixels through a plain closure straight into the layer
//     gives smooth, continuous video with zero SwiftUI involvement per frame.
//   • `CALayer.contents = pixelBuffer` is ZERO-COPY — Core Animation samples
//     the IOSurface in the WindowServer, no per-frame blit on our side.
//   • `contentsGravity = .resizeAspect` letterboxes / downscales on the GPU
//     for free, so a 4K buffer in a small pane costs nothing extra.
//   • We HOST the layer (`self.layer = contentLayer` BEFORE `wantsLayer`) so
//     `contents` is ours to mutate without touching any NSView API — a busy
//     main thread can never freeze the preview.
//
// Wiring: a `Coordinator` registers the channel's `onFrame` / `onClear` sinks
// on appear (in `makeNSView`) and clears them on disappear
// (`dismantleNSView`), so exactly the channel currently shown receives frames.
// The low-frequency rotation hint (`StateSnapshot.outputRotation`) flows the
// normal SwiftUI way via `updateNSView` — it changes a handful of times per
// session, not per frame.

import SwiftUI
import AppKit
import CoreVideo
import CoreImage

/// SwiftUI wrapper that streams a channel's decoded frames into a hosted CALayer
/// via the channel's direct `onFrame` pipe.
///
/// Primary use is `PreviewView(channel:)` — the direct pipe.  A
/// `PreviewView(frame:rotation:enabled:)` initialiser is kept for callers that
/// still hand a single buffer; it routes through the same hosted layer but is
/// driven by `updateNSView` (one buffer per body eval), so prefer the channel
/// initialiser for live video.
struct PreviewView: NSViewRepresentable {

    /// The channel to stream from, when using the direct-pipe path.  nil for the
    /// legacy single-frame initialiser.
    private let channel: BridgeChannel?

    /// Legacy single-frame value (only set by the `frame:` initialiser).
    private let staticFrame: CVImageBuffer?

    /// Clockwise rotation hint (StateSnapshot.outputRotation): 0 / 90 / 180 /
    /// 270.  The iPhone always sends landscape pixels; we rotate at present.
    private let rotation: Int

    /// When false we render nothing and clear contents (preview hidden — the
    /// caller shows its own placeholder, this just avoids holding a buffer).
    private let enabled: Bool

    /// DIRECT pipe — preferred for live video.  Registers `channel.onFrame` so
    /// every decoded frame paints straight into the hosted layer.
    init(channel: BridgeChannel) {
        self.channel = channel
        self.staticFrame = nil
        self.rotation = channel.remote?.outputRotation ?? 0
        self.enabled = channel.previewEnabled
    }

    /// Legacy single-frame init — kept so existing call sites compile.  No
    /// direct pipe; the buffer is whatever the caller passes per body eval.
    init(frame: CVImageBuffer?, rotation: Int = 0, enabled: Bool = true) {
        self.channel = nil
        self.staticFrame = frame
        self.rotation = rotation
        self.enabled = enabled
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Surface {
        let surface = Surface()
        // Register the direct pipe NOW (on appear) so frames flow into THIS
        // surface for as long as it lives.  Cleared in dismantleNSView.
        if let channel {
            context.coordinator.bind(channel: channel, to: surface)
        }
        return surface
    }

    func updateNSView(_ nsView: Surface, context: Context) {
        if channel != nil {
            // Direct-pipe path: per-frame pixels arrive via onFrame; here we
            // only push the (low-frequency) rotation + enabled state, and clear
            // the layer when preview is disabled so a hidden pane holds nothing.
            context.coordinator.update(rotation: rotation, enabled: enabled)
        } else {
            // Legacy path: paint the single static frame.
            nsView.update(frame: enabled ? staticFrame : nil, rotation: rotation)
        }
    }

    static func dismantleNSView(_ nsView: Surface, coordinator: Coordinator) {
        coordinator.unbind()
    }

    // MARK: - Coordinator (owns the channel↔surface frame wiring)

    /// Holds the weak surface + channel and the registered sinks, so the direct
    /// pipe is torn down cleanly when the view goes away (no retain cycle, no
    /// stale closure firing into a dead layer).
    final class Coordinator {
        private weak var surface: Surface?
        private weak var channel: BridgeChannel?
        private var rotation: Int = 0

        /// Register `onFrame` / `onClear` so the receiver streams straight into
        /// `surface`.  Called on appear (main thread).
        func bind(channel: BridgeChannel, to surface: Surface) {
            self.surface = surface
            self.channel = channel
            self.rotation = channel.remote?.outputRotation ?? 0

            // Per-frame pipe: capture the surface + current rotation weakly and
            // paint directly.  The receiver invokes this on the main queue.
            channel.onFrame = { [weak surface, weak self] buffer in
                surface?.update(frame: buffer, rotation: self?.rotation ?? 0)
            }
            channel.onClear = { [weak surface] in
                surface?.update(frame: nil, rotation: 0)
            }
        }

        /// Push a low-frequency rotation / enabled change.  When preview is
        /// disabled we clear the layer (the caller shows its own placeholder).
        func update(rotation: Int, enabled: Bool) {
            self.rotation = rotation
            guard let surface else { return }
            if !enabled {
                surface.update(frame: nil, rotation: rotation)
            }
            // When enabled, the next onFrame call repaints with the new
            // rotation — no need to force a paint of a possibly-stale buffer.
        }

        /// Clear the registered sinks on disappear so the channel never holds a
        /// closure into a torn-down surface.
        func unbind() {
            channel?.onFrame = nil
            channel?.onClear = nil
            surface = nil
            channel = nil
        }
    }

    // MARK: - Surface (hosted-layer NSView)

    /// NSView hosting one CALayer we own, so its `contents` is ours to set.
    /// SwiftUI re-instantiates representables freely, but the NSView (and its
    /// layer) is reused across `updateNSView` calls, so frame swaps are
    /// flicker-free.
    final class Surface: NSView {
        private let contentLayer = CALayer()
        // Fallback rasterizer for the rare frame that isn't IOSurface-backed.
        private let ciContext = CIContext()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            contentLayer.contentsGravity = .resizeAspect
            contentLayer.backgroundColor = NSColor.black.cgColor
            // Layer-HOSTING: set the layer BEFORE wantsLayer so we own it.
            self.layer = contentLayer
            self.wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        /// Point the owned layer at `frame` and apply the rotation hint.  No-
        /// animation transaction so frame swaps don't cross-fade.  Safe to call
        /// per frame — it's two atomic CALayer property writes inside one
        /// committed transaction.
        func update(frame: CVImageBuffer?, rotation: Int) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // CALayer.contents does NOT reliably display a CVPixelBuffer directly.
            // VideoToolbox frames are IOSurface-backed, and an IOSurface IS a valid
            // contents type → zero-copy. Fall back to a CGImage if not backed.
            if let pb = frame {
                if let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
                    contentLayer.contents = surf
                } else if let cg = ciContext.createCGImage(CIImage(cvPixelBuffer: pb),
                                                           from: CIImage(cvPixelBuffer: pb).extent) {
                    contentLayer.contents = cg
                }
            } else {
                contentLayer.contents = nil // black
            }
            // Option B vertical-stream: present the landscape buffer rotated.
            // NEGATED angle — a hosting (non-flipped, y-up) layer rotates CCW for
            // a positive angle, so negate to get the clockwise rotation the
            // phone's upright preview expects.
            contentLayer.transform = (rotation == 0)
                ? CATransform3DIdentity
                : CATransform3DMakeRotation(-CGFloat(rotation) * .pi / 180, 0, 0, 1)
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.frame = bounds
            CATransaction.commit()
        }

        // A hosting layer's contentsScale is NOT auto-synced by AppKit, so a
        // pane can render half-res on a 2× display.  Read the backing scale on
        // main (NSWindow is main-only) and push it to the layer.
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            let scale = window?.backingScaleFactor ?? 2.0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.contentsScale = scale
            CATransaction.commit()
        }
    }
}
