// MirrorVideoView.swift — live channel frame, "decode once → show in many".
//
// Ported from AirliveStudioApp/Sources/MirrorVideoView.swift (the proven scheme).
// Each instance HOSTS its OWN plain `CALayer` and points `contents` at the SAME
// IOSurface-backed `CVPixelBuffer` the channel already decoded — so one camera
// can appear live in any number of places at once (a multiview thumbnail AND the
// big Program / Preview window) with ZERO extra decodes.
//
// Why not `AVSampleBufferDisplayLayer`: it owns its decode and is single-parent,
// so the same camera can't appear in two tiles (the second steals the layer →
// black tile).  `CALayer.contents = pixelBuffer` is zero-copy (Core Animation
// samples the IOSurface in the WindowServer) and any number of layers may point
// at the same buffer.
//
// The channel calls `publishFrame` per decoded frame, posting
// `BridgeChannel.newFrameNotification` on its OFF-MAIN present thread; we observe
// it and set `contents` off main, so a busy main thread can never freeze preview.

import SwiftUI
import AppKit
import CoreVideo

struct MirrorVideoView: NSViewRepresentable {
    let channel: BridgeChannel

    func makeNSView(context: Context) -> Mirror {
        let view = Mirror()
        view.bind(to: channel)
        return view
    }

    func updateNSView(_ nsView: Mirror, context: Context) {
        nsView.bind(to: channel)
    }

    static func dismantleNSView(_ nsView: Mirror, coordinator: ()) {
        nsView.unbind()
    }

    /// NSView HOSTING one CALayer we own (not AppKit-managed) so we may mutate its
    /// `contents` from any thread (we touch only the layer, never NSView API).
    final class Mirror: NSView {
        private weak var channel: BridgeChannel?
        private var observer: NSObjectProtocol?
        private let contentLayer = CALayer()
        /// View size cached on main (in `layout()`) so the off-main paint can size
        /// the layer without touching main-only NSView API.
        private var viewSize: CGSize = .zero
        private var currentRotation: Int = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // AppKit OWNS the ROOT backing layer — it keeps it sized to the view's bounds
            // and positioned correctly in the window.  Our video goes in a SUBLAYER we own,
            // which we size/rotate ourselves AND may mutate off-main.  Driving the ROOT
            // hosted layer's bounds/position by hand fought AppKit's own placement and
            // parked the picture in a corner quadrant — the bug we kept chasing.
            wantsLayer = true
            // FIT (contain): scale to show the WHOLE frame, preserving aspect — fill the
            // LONG side to 100%, bars on the short side.  A portrait phone screen fills the
            // HEIGHT (bars left/right, whole screen visible); a landscape camera fills the
            // WIDTH.  Never cropped to a sliver.  The bars are the layer's black background.
            contentLayer.contentsGravity = .resizeAspect
            contentLayer.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(contentLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        func bind(to channel: BridgeChannel) {
            if self.channel === channel { return }
            unbind()
            self.channel = channel
            // queue: nil → delivered SYNCHRONOUSLY on the posting (off-main) thread,
            // so the paint never touches `.main`.  Read the buffer directly from the
            // weakly-captured channel so we never touch `self.channel` off-main.
            observer = NotificationCenter.default.addObserver(
                forName: BridgeChannel.newFrameNotification, object: channel, queue: nil
            ) { [weak channel, weak self] _ in
                self?.setContents(channel?.latestPixelBuffer, rotation: channel?.outputRotation ?? 0)
            }
            // Initial paint (bind runs on main; cheap one-shot).
            setContents(channel.latestPixelBuffer, rotation: channel.outputRotation)
        }

        func unbind() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            channel = nil
        }

        /// Point our owned layer's contents at the buffer + (re)apply geometry.
        /// Safe from any thread (we own `contentLayer`; no NSView API touched —
        /// `applyGeometry` uses the cached `viewSize`).
        private func setContents(_ buffer: CVPixelBuffer?, rotation: Int) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.contents = buffer   // nil → black (no signal)
            currentRotation = rotation
            applyGeometry()
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            viewSize = bounds.size           // main-only NSView read, cached here
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyGeometry()
            CATransaction.commit()
        }

        // layout() alone doesn't reliably fire when SwiftUI changes the representable's
        // size, which left the hosted layer stuck at its first (tiny) size in a corner —
        // the "signal in the top-right corner" bug.  Re-apply geometry on EVERY resize.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            viewSize = newSize
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyGeometry()
            CATransaction.commit()
        }

        /// Size, center and rotate our layer to FILL the tile (cover).
        ///
        /// The layer always maps onto the full tile, and `resizeAspectFill` then scales the
        /// frame to cover it (cropping overflow) — so the picture fills every window no
        /// matter its aspect.  For a portrait rotation (90 / 270) the pre-rotation bounds
        /// are the tile size with width/height SWAPPED, so after the rotation the layer
        /// still maps onto the full tile and cover-fills it.
        ///
        /// CRITICAL: never set `.bounds` while a non-identity transform is applied
        /// (`.bounds`/`.frame` are undefined under a transform).  Reset to identity first.
        /// A hosting (y-up) layer rotates CCW for a positive angle, so negate to get the
        /// clockwise rotation the phone's upright preview expects.
        private func applyGeometry() {
            let size = viewSize
            guard size.width > 0, size.height > 0 else { return }
            let rot = ((currentRotation % 360) + 360) % 360
            if rot == 0 {
                // Common case: the sublayer simply overlays the whole view.  `frame` is
                // well-defined here (identity transform) and is the simplest correct fill.
                contentLayer.transform = CATransform3DIdentity
                contentLayer.frame = CGRect(origin: .zero, size: size)
            } else {
                // Rotated: never set `.frame` under a transform (undefined).  Size the
                // pre-rotation bounds to the tile (swapped for portrait) and centre, so
                // after rotation the layer maps onto the full tile; resizeAspect then fits
                // the whole frame inside (bars on the short side).
                contentLayer.transform = CATransform3DIdentity
                contentLayer.position = CGPoint(x: size.width / 2, y: size.height / 2)
                let isPortrait = (rot == 90 || rot == 270)
                contentLayer.bounds = CGRect(
                    origin: .zero,
                    size: isPortrait ? CGSize(width: size.height, height: size.width) : size
                )
                contentLayer.transform = CATransform3DMakeRotation(-CGFloat(rot) * .pi / 180, 0, 0, 1)
            }
        }

        // A hosting layer's contentsScale is NOT auto-synced by AppKit, so a tile
        // can render half-res on a 2× display.  Read the backing scale on main
        // (NSWindow is main-only) and push it to the layer.
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            let scale = window?.backingScaleFactor ?? 2.0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.contentsScale = scale
            CATransaction.commit()
        }

        deinit { unbind() }
    }
}
