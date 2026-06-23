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

        /// Point our owned layer's contents at the buffer.  Safe from any thread
        /// (we own `contentLayer`; no NSView API touched).
        private func setContents(_ buffer: CVPixelBuffer?, rotation: Int) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.contents = buffer   // nil → black (no signal)
            // Option B vertical stream: the iPhone sends LANDSCAPE pixels + a
            // clockwise rotation hint.  A hosting (y-up) layer rotates CCW for a
            // positive angle, so negate to get the clockwise rotation the phone's
            // upright preview expects.
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
