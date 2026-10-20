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
    /// Tap-to-focus: called with the NORMALISED point on the NATIVE LANDSCAPE frame — Apple's
    /// `focusPointOfInterest` convention (0,0 top-left … 1,1 bottom-right).  The Mirror inverts its
    /// OWN display geometry (resizeAspect letterbox + `outputRotation`), so the caller just sends
    /// `setFocusPoint`.  nil → the video isn't tappable (thumbnails, program, legacy cameras).
    var onTapPoint: ((CGPoint) -> Void)? = nil

    func makeNSView(context: Context) -> Mirror {
        let view = Mirror()
        view.bind(to: channel)
        view.setTapHandler(onTapPoint)
        return view
    }

    func updateNSView(_ nsView: Mirror, context: Context) {
        nsView.bind(to: channel)
        nsView.setTapHandler(onTapPoint)
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
        private var tapHandler: ((CGPoint) -> Void)?
        private var clickRecognizer: NSClickGestureRecognizer?

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
            pinWindowToSDRsRGB()
        }

        // Pin any window hosting live video to sRGB so the sRGB-tagged decoded
        // buffers composite sRGB→sRGB (identity) — the same presentation regime
        // as the phone's preview layer (colorspace=sRGB, EDR off) and the AirPlay
        // path.  Part of the display state the 2026-07-06 wire-colour fix was
        // verified against; harmless with honest wire values, and it keeps a
        // wide-gamut/EDR display profile from re-interpreting the monitoring
        // proxy.  (The wire bug itself was on the CAMERA — identity-LUT texel-
        // center stretch; see airlive/docs/WIRE-COLOR-RECEIVER-DIAGNOSIS.md.)
        private func pinWindowToSDRsRGB() {
            guard let window, window.colorSpace != .sRGB else { return }
            window.colorSpace = .sRGB
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            pinWindowToSDRsRGB()
        }

        deinit { unbind() }

        // MARK: Tap-to-focus

        /// Install / remove the click recogniser as the caller wires or unwires a tap handler.
        func setTapHandler(_ h: ((CGPoint) -> Void)?) {
            tapHandler = h
            if h != nil, clickRecognizer == nil {
                let r = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
                addGestureRecognizer(r)
                clickRecognizer = r
            } else if h == nil, let r = clickRecognizer {
                removeGestureRecognizer(r)
                clickRecognizer = nil
            }
        }

        @objc private func handleClick(_ g: NSClickGestureRecognizer) {
            guard let tapHandler, let buf = channel?.latestPixelBuffer else { return }
            let p = g.location(in: self)                    // y-UP (this NSView isn't flipped)
            let bw = Double(CVPixelBufferGetWidth(buf)), bh = Double(CVPixelBufferGetHeight(buf))
            guard bounds.width > 0, bounds.height > 0,
                  let pt = Self.normalizedFocusPoint(tapX: Double(p.x), tapY: Double(p.y),
                                                     viewW: Double(bounds.width), viewH: Double(bounds.height),
                                                     bufW: bw, bufH: bh, rotation: currentRotation)
            else { return }
            flashReticle(at: p)
            tapHandler(CGPoint(x: pt.x, y: pt.y))
        }

        /// Inverse of this view's DISPLAY geometry (resizeAspect letterbox + layer rotate(-rot) in a
        /// y-UP view) → Apple `focusPointOfInterest` on the NATIVE LANDSCAPE frame: (0,0) top-left …
        /// (1,1) bottom-right.  Returns nil when the tap fell on a letterbox bar.  Pure + verified by
        /// hand for rot 0/90/180 (see the /tmp/poi_test derivation).  ⚠️ The final top/bottom flip
        /// assumes CA shows the buffer upright (image row 0 at high-y) — true here (video isn't
        /// mirrored); the ONE thing to confirm on device.
        static func normalizedFocusPoint(tapX: Double, tapY: Double, viewW: Double, viewH: Double,
                                          bufW: Double, bufH: Double, rotation: Int) -> CGPoint? {
            guard bufW > 0, bufH > 0 else { return nil }
            let a = Double(((rotation % 360) + 360) % 360) * .pi / 180      // inverse-rotate by +rot
            let vrx = tapX - viewW / 2, vry = tapY - viewH / 2              // relative to view centre
            let ca = cos(a), sa = sin(a)
            let lrx = vrx * ca - vry * sa, lry = vrx * sa + vry * ca        // local_rel = R(+rot)·view_rel
            let portrait = (rotation % 180 != 0)
            let lbw = portrait ? viewH : viewW, lbh = portrait ? viewW : viewH
            let lx = lrx + lbw / 2, ly = lry + lbh / 2                      // layer-local (y-up, origin BL)
            let scale = min(lbw / bufW, lbh / bufH)                         // undo resizeAspect (fit)
            let imgW = bufW * scale, imgH = bufH * scale
            let u = (lx - (lbw - imgW) / 2) / imgW
            let v = (ly - (lbh - imgH) / 2) / imgH
            let eps = 0.03
            guard u >= -eps, u <= 1 + eps, v >= -eps, v <= 1 + eps else { return nil }   // outside → bar
            return CGPoint(x: min(1, max(0, u)), y: min(1, max(0, 1 - v)))  // clamp edge FP, flip to top-left
        }

        /// The tap-to-focus reticle, drawn exactly like the Airlive Camera's own (`FocusReticle` /
        /// `FocusBrackets` in the camera app, 1.1.3): four rounded corner brackets of a 60 pt
        /// square, and over it a label saying what the tap moves - "AE/AF" while the camera's
        /// exposure is automatic (focus and exposure follow the point), "AF" while it is manual
        /// (only focus does). The same look on the phone and in the Bridge.
        ///
        /// On this view's own layer, not the video layer: the video is rotated for portrait
        /// sources, the reticle must not be. The view is y-UP, so "above" is the larger y.
        private func flashReticle(at point: CGPoint) {
            currentReticle?.removeFromSuperlayer()   // a new tap replaces the last one at once

            let side = reticleSide()
            let reticle = CALayer()
            reticle.position = point
            reticle.addSublayer(Self.focusBrackets(side: side))
            reticle.addSublayer(focusLabel(channel?.remote?.exposureAuto ?? true ? "AE/AF" : "AF", side: side))
            layer?.addSublayer(reticle)
            currentReticle = reticle

            // The camera's timing: in with a 1.4 → 1.0 scale over 0.22 s (ease-out), held, gone
            // after about 1.2 s. Transform and opacity only.
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.4; scale.toValue = 1.0
            scale.duration = Self.reticleIn
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, NSNumber(value: Self.reticleHold / Self.reticleLife), 1]
            fade.duration = Self.reticleLife
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = Self.reticleLife
            reticle.opacity = 0   // the end state; the group shows it until then
            reticle.add(group, forKey: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.reticleLife) { [weak self, weak reticle] in
                reticle?.removeFromSuperlayer()
                if let self, self.currentReticle === reticle { self.currentReticle = nil }
            }
        }

        /// The camera's 60 pt square is about 6.4 % of its ~930 pt landscape preview. Taken as a
        /// share of the picture shown here, so the reticle covers the same part of the frame as on
        /// the phone at any window size; bounded so a small tile still shows it and a big pane does
        /// not blow it up (operator, 2026-10-20: 60 pt read too large in the Bridge).
        private func reticleSide() -> CGFloat {
            var picW = bounds.width
            if let buf = channel?.latestPixelBuffer {
                var bw = CGFloat(CVPixelBufferGetWidth(buf)), bh = CGFloat(CVPixelBufferGetHeight(buf))
                if currentRotation % 180 != 0 { swap(&bw, &bh) }
                if bw > 0, bh > 0 { picW = bw * min(bounds.width / bw, bounds.height / bh) }
            }
            return min(max(picW * Self.reticleShare, 32), 52)
        }
        private static let reticleShare: CGFloat = 60.0 / 932.0

        private var currentReticle: CALayer?
        private static let reticleIn: CFTimeInterval = 0.22    // camera: scale-in, ease-out
        private static let reticleHold: CFTimeInterval = 1.2   // camera: how long it stays
        private static let reticleLife: CFTimeInterval = 1.45  // hold + a 0.25 s fade

        /// The camera's square (camera FocusBrackets, drawn at 60 pt there): four corners with a
        /// 12/60 radius, each arm 21/60 of the side from the edge, the middle of every side open,
        /// a 1 pt stroke kept inside.
        private static func focusBrackets(side: CGFloat) -> CAShapeLayer {
            let corner = side * 12 / 60, arm = side * 21 / 60   // the camera's proportions
            let r = CGRect(x: -side / 2, y: -side / 2, width: side, height: side).insetBy(dx: 0.5, dy: 0.5)
            let path = CGMutablePath()
            for (c, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0), (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0)] {
                path.move(to: CGPoint(x: c.x, y: c.y + dy * arm))
                path.addArc(tangent1End: c, tangent2End: CGPoint(x: c.x + dx * arm, y: c.y), radius: corner)
                path.addLine(to: CGPoint(x: c.x + dx * arm, y: c.y))
            }
            let brackets = CAShapeLayer()
            brackets.path = path
            brackets.fillColor = nil
            brackets.strokeColor = NSColor(Theme.accentYellow).cgColor
            brackets.lineWidth = 1
            return brackets
        }

        /// The camera's HUD pill (black 50%, radius 10, white SF 14 regular, 10 pt sides and 5 pt top
        /// and bottom, 4 pt above the square), scaled with the square; text never under 10 pt.
        private func focusLabel(_ text: String, side: CGFloat) -> CALayer {
            let k = side / 60
            let fontSize = max(10, (14 * k).rounded())
            let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            let padX = (10 * k).rounded(), padY = (5 * k).rounded()
            let size = CGSize(width: ceil(textSize.width) + padX * 2, height: ceil(textSize.height) + padY * 2)
            let scale = window?.backingScaleFactor ?? 2

            let pill = CALayer()
            pill.bounds = CGRect(origin: .zero, size: size)
            pill.position = CGPoint(x: 0, y: side / 2 + 4 + size.height / 2)   // above the square (y-up)
            pill.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
            pill.cornerRadius = min(10 * k, size.height / 2)

            let label = CATextLayer()
            label.string = text
            label.font = font
            label.fontSize = fontSize
            label.foregroundColor = NSColor.white.cgColor
            label.alignmentMode = .center
            label.contentsScale = scale
            label.frame = CGRect(x: 0, y: (size.height - ceil(textSize.height)) / 2,
                                 width: size.width, height: ceil(textSize.height))
            pill.addSublayer(label)
            return pill
        }
    }
}
