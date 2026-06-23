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
            contentLayer.contentsGravity = .resizeAspect
            contentLayer.backgroundColor = NSColor.black.cgColor
            // Layer-HOSTING: set `layer` BEFORE `wantsLayer` → the layer is OURS,
            // safe to mutate off-main (an AppKit-managed layer must be main-only).
            self.layer = contentLayer
            self.wantsLayer = true
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

        /// Size, center and rotate our layer for the current rotation.
        ///
        /// CRITICAL: never set `contentLayer.frame` while a rotation transform is
        /// applied — `.frame` is undefined under a non-identity transform and was
        /// the bug that sent rotated streams (90 / 180 / 270) to a black/garbled
        /// tile.  We set `bounds` + `position` + `transform` instead.
        ///
        /// Option B vertical stream: the iPhone sends LANDSCAPE (16:9) pixels + a
        /// clockwise rotation hint.  For a portrait hint (90 / 270) we make the
        /// pre-rotation layer a 16:9 rect whose long edge maps to the tile HEIGHT,
        /// so after rotation it presents as **9:16, fit by height, centred**
        /// (letterboxed left/right) — never stretched.  A hosting (y-up) layer
        /// rotates CCW for a positive angle, so we negate to get the clockwise
        /// rotation the phone's upright preview expects.
        private func applyGeometry() {
            let size = viewSize
            guard size.width > 0, size.height > 0 else { return }
            let rot = ((currentRotation % 360) + 360) % 360
            let isPortrait = (rot == 90 || rot == 270)

            let layerSize: CGSize = isPortrait
                ? CGSize(width: size.height, height: size.height * 9.0 / 16.0)  // → 9:16 by height
                : size                                                          // landscape fills tile
            contentLayer.bounds = CGRect(origin: .zero, size: layerSize)
            contentLayer.position = CGPoint(x: size.width / 2, y: size.height / 2)
            contentLayer.transform = (rot == 0)
                ? CATransform3DIdentity
                : CATransform3DMakeRotation(-CGFloat(rot) * .pi / 180, 0, 0, 1)
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
