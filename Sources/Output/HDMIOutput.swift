// HDMIOutput.swift — put the PROGRAM full-screen on an external display.
//
// Not a network transport like NDI/SRT/RTSP: this is a clean, chrome-less
// full-screen window (no UI, no multiview, no tally) placed on a chosen screen —
// macOS drives that screen's HDMI port, so "HDMI Out" is really "Program on a
// second display", the same idea as OBS's Fullscreen Projector (Program).
//
// It IS a VideoOutput so it lives in the Outputs rail with the same toggle / order
// / delete as the others, and it consumes the SAME decoded program frames the
// model already fans out to NDI (feedProgram) — so a clean-program CUT, a black
// program, and a live camera all "just appear" with zero extra decode.  The one
// extra piece of state is which display to fill, stored in `config` so it survives
// a profile save/reload.
//
// Threading: like every other VideoOutput, send()/start()/stop() are called on
// MAIN (feedProgram runs on main; see BridgeModel).  The window + layer are AppKit,
// so main is required anyway; the start/stop paths hop to main defensively.

import Foundation
import CoreVideo
import AppKit

final class HDMIOutput: VideoOutput {
    let id: UUID
    let kind: OutputKind = .hdmi
    var label: String

    /// The target display, as a CGDirectDisplayID string.  Empty = "the second
    /// screen" (first external display), resolved live at start().  Persisted via
    /// the profile's `config` field, same as SRT's destination.
    var config: String

    private var _isLive = false
    private let lock = NSLock()
    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return _isLive }

    /// Card-visible failure (see VideoOutput.lastError).  Main-confined.
    private(set) var lastError: String?
    /// Fires on MAIN when `lastError` changes — the model nudges objectWillChange so
    /// the card re-renders (VideoOutput isn't observable).
    var onStateChanged: (() -> Void)?

    /// The projector window + its frame-fed layer.  Main-only (AppKit).
    private var projector: ProjectorWindow?
    /// Watches for a monitor being plugged/unplugged while we're live.
    private var screenObserver: NSObjectProtocol?

    init(id: UUID = UUID(), label: String = "HDMI Out", config: String = "") {
        self.id = id
        self.label = label
        self.config = config
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        // Safety net: a fullscreen NSWindow is retained by AppKit's window list while
        // ordered-in, so a dropped-without-stop instance would leave a black window on
        // the display.  Close it (on main — AppKit).
        if let p = projector {
            if Thread.isMainThread { p.close() } else { DispatchQueue.main.async { p.close() } }
        }
    }

    // MARK: - VideoOutput

    func start() {
        let build = { [weak self] in
            guard let self else { return }
            guard let screen = Self.resolveScreen(self.config) else {
                // No display to project on — do NOT silently cover the operator's own
                // screen (that buries the UI).  Report it; stay off.
                self.reportError("Connect a second display, then toggle HDMI Out again")
                return
            }
            let window = ProjectorWindow(screen: screen)
            window.show()
            self.projector = window
            self.reportError(nil)
            self.registerScreenObserver()
            self.lock.lock(); self._isLive = true; self.lock.unlock()
        }
        if Thread.isMainThread { build() } else { DispatchQueue.main.async(execute: build) }
    }

    func stop() {
        lock.lock(); _isLive = false; lock.unlock()
        let tear = { [weak self] in
            guard let self else { return }
            if let o = self.screenObserver { NotificationCenter.default.removeObserver(o); self.screenObserver = nil }
            self.projector?.close(); self.projector = nil
        }
        if Thread.isMainThread { tear() } else { DispatchQueue.main.async(execute: tear) }
    }

    /// Decoded program frame (same buffer NDI gets).  Painted straight onto the
    /// projector's owned CALayer — Core Animation samples the IOSurface in the
    /// WindowServer, zero-copy (the same pattern as MirrorVideoView).  Called on
    /// main (feedProgram); the CATransaction is cheap.
    func send(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {
        projector?.setBuffer(pixelBuffer)
    }

    /// Change the target display; if we're live, move the projector there — but only
    /// when it's actually a DIFFERENT physical screen (re-picking the same one must
    /// not flicker).
    func setDisplay(_ newConfig: String) {
        let oldScreenID = Self.resolveScreen(config)?.displayID
        config = newConfig
        guard isLive else { return }
        let move = { [weak self] in
            guard let self else { return }
            guard let screen = Self.resolveScreen(newConfig) else {
                // The chosen display vanished — stop cleanly instead of dangling.
                self.stop(); self.reportError("That display isn’t available")
                return
            }
            guard screen.displayID != oldScreenID else { return }   // same screen → no flicker
            self.projector?.move(to: screen)
        }
        if Thread.isMainThread { move() } else { DispatchQueue.main.async(execute: move) }
    }

    // MARK: - Screen changes

    private func registerScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.handleScreensChanged() }
    }

    /// A monitor was plugged/unplugged/rearranged while live.  Keep the projector on
    /// the right screen, or stop cleanly if the one we were filling is gone.
    private func handleScreensChanged() {
        guard isLive else { return }
        if let screen = Self.resolveScreen(config) {
            projector?.move(to: screen)
        } else {
            stop()
            reportError("The display was disconnected")
        }
    }

    // MARK: - Display resolution

    /// The screen for a stored config.  An EXPLICIT choice (a present display id — even
    /// the main screen, if the operator picked it) is honoured.  An empty/stale config
    /// resolves to the first EXTERNAL display, or `nil` when there's no second screen —
    /// callers must NOT fall back to the main screen (that buries the operator's UI).
    static func resolveScreen(_ config: String) -> NSScreen? {
        let screens = NSScreen.screens
        if let id = UInt32(config), let match = screens.first(where: { $0.displayID == id }) {
            return match
        }
        return screens.first(where: { $0 != NSScreen.main })
    }

    private func reportError(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastError != message else { return }
            self.lastError = message
            self.onStateChanged?()
        }
    }

    func clearError() { reportError(nil) }
}

// MARK: - CGDirectDisplayID helper

extension NSScreen {
    /// The stable-per-session CoreGraphics display id (the key used to target a
    /// specific monitor across app runs, as far as macOS allows).
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - The full-screen projector window

/// A borderless, chrome-less window covering one screen, hosting a single CALayer
/// we feed program frames into.  Not a SwiftUI scene — a plain AppKit window so we
/// can place it on an exact NSScreen.  All members are main-confined (AppKit).
private final class ProjectorWindow {
    private let window: NSWindow
    private let layerView: ProjectorLayerView

    init(screen: NSScreen) {
        layerView = ProjectorLayerView()
        window = NSWindow(contentRect: screen.frame,
                          styleMask: .borderless,
                          backing: .buffered,
                          defer: false,
                          screen: screen)
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]
        window.contentView = layerView
        window.setFrame(screen.frame, display: true)
    }

    func show() {
        // orderFront (not makeKey): the projector fills the second screen but must
        // NOT steal keyboard focus — the operator keeps driving the main window.
        window.orderFrontRegardless()
    }

    /// Reposition onto another screen (or the same screen after a resolution change)
    /// WITHOUT recreating the window — no flicker, keeps the layer + its last frame.
    func move(to screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
    }

    func close() { window.orderOut(nil); window.close() }

    func setBuffer(_ buffer: CVPixelBuffer?) { layerView.setBuffer(buffer) }
}

/// NSView hosting ONE CALayer we own; frames arrive via `setBuffer` from
/// HDMIOutput.send (on main).  Same proven layer-contents pattern as
/// MirrorVideoView.Mirror, minus the channel binding.
private final class ProjectorLayerView: NSView {
    private let contentLayer = CALayer()
    private var viewSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        contentLayer.contentsGravity = .resizeAspect   // whole program visible, bars if needed
        contentLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(contentLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setBuffer(_ buffer: CVPixelBuffer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = buffer   // nil → black.  IOSurface-backed → zero-copy;
                                         // the layer legitimately holds it (compositor path).
        applyGeometry()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        viewSize = bounds.size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        applyGeometry()
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        viewSize = newSize
        CATransaction.begin(); CATransaction.setDisableActions(true)
        applyGeometry()
        CATransaction.commit()
    }

    private func applyGeometry() {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        contentLayer.frame = CGRect(origin: .zero, size: viewSize)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2.0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        contentLayer.contentsScale = scale
        CATransaction.commit()
    }
}
