// PreviewView.swift — efficient live-frame surface for one channel.
//
// Renders a `BridgeChannel`'s latest decoded `CVImageBuffer` by pointing a
// CALayer's `contents` straight at the IOSurface-backed pixel buffer the
// receiver already decoded.  This is the thermal-safe "decode once → show"
// path ported from Studio's MirrorVideoView:
//
//   • `CALayer.contents = pixelBuffer` is ZERO-COPY — Core Animation samples
//     the IOSurface in the WindowServer, no per-frame blit on our side.
//   • `contentsGravity = .resizeAspect` letterboxes / downscales on the GPU
//     for free, so a 4K buffer in a small pane costs nothing extra.
//   • We HOST the layer (`self.layer = contentLayer` BEFORE `wantsLayer`) so
//     `contents` can be mutated off the main thread without touching any
//     NSView API — a busy main thread can never freeze the preview.
//
// Gating: the view only updates when the channel's `previewEnabled` is true.
// The caller (CenterPane) swaps in a placeholder when preview is hidden, but we
// also defensively clear contents here so a hidden pane holds no buffer.

import SwiftUI
import AppKit
import CoreVideo

/// SwiftUI wrapper that mirrors a channel's `latestFrame` into a hosted CALayer.
struct PreviewView: NSViewRepresentable {
    /// The frame to display (the channel's `latestFrame`).  nil → black "no
    /// signal" fill (the surface stays present; the badge/border live in the
    /// SwiftUI overlay above this view).
    let frame: CVImageBuffer?
    /// Clockwise rotation hint (StateSnapshot.outputRotation): 0 / 90 / 180 /
    /// 270.  The iPhone always sends landscape pixels; we rotate at present.
    var rotation: Int = 0
    /// When false we render nothing and clear contents (preview hidden — the
    /// caller shows its own placeholder, this just avoids holding a buffer).
    var enabled: Bool = true

    func makeNSView(context: Context) -> Surface { Surface() }

    func updateNSView(_ nsView: Surface, context: Context) {
        nsView.update(frame: enabled ? frame : nil, rotation: rotation)
    }

    /// NSView hosting one CALayer we own, so its `contents` is ours to set from
    /// any thread.  SwiftUI re-instantiates representables freely, but the NSView
    /// (and its layer) is reused across `updateNSView` calls, so frame swaps are
    /// flicker-free.
    final class Surface: NSView {
        private let contentLayer = CALayer()

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
        /// animation transaction so frame swaps don't cross-fade.
        func update(frame: CVImageBuffer?, rotation: Int) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.contents = frame   // nil → black
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
