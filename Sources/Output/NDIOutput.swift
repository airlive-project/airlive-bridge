// NDIOutput.swift — re-publish a channel's decoded frames as an NDI® source.
//
// WHY runtime dlopen instead of a build-time link:
// The NDI SDK is NOT redistributable and is NOT on Homebrew — it ships as a
// free "NDI Tools / NDI Runtime" installer from ndi.video.  Linking libndi at
// build time would make this app fail to build (and fail to launch) on any
// machine without the SDK present.  Instead we `dlopen` libndi at start() and
// resolve the five entry points we need with `dlsym`.  If the runtime isn't
// installed, start() logs a clear message and stays not-live — the rest of the
// app (preview, other outputs) keeps working.  See docs/NDI-SETUP.md.
//
// Frame contract (from VideoOutput): the channel hands us a decoded CVPixelBuffer
// for every frame while we're live.  The decoders produce NV12 (8-bit 4:2:0
// bi-planar, video range) — the ARLV camera path and the AirPlay path both — and
// NDI carries that natively, so the common path sends the decoder's own bytes with
// NO conversion at all.  Only a source that is neither NV12-contiguous nor already
// BGRA (an HDMI capture card is BGRA; an exotic layout is neither) is converted,
// and then by VTPixelTransferSession — a fixed-function hardware block.
//
// This file used to assert the opposite ("the decoder produces 32BGRA") and convert
// every frame through CoreImage on the strength of it.  The claim was true once; the
// decoder's output format was changed to NV12 in a later commit that edited this file
// without touching the comment.  From then on the "rare fallback" ran on every single
// frame of the app's two main sources: a full CoreImage render pass, plus a fresh
// colour space object, per frame — the largest avoidable cost in the whole program
// path, and a colour-management path no other consumer of the same buffer used.
// We must not retain the buffer past the call, and we don't: send_send_video_v2
// copies (or at minimum reads) the data synchronously before we unlock.

import Foundation
import CoreVideo
import VideoToolbox

// MARK: - NDI C ABI (minimal, matches Processing.NDI.* headers)

// FourCC codes are the literal 'BGRA' / 'UYVY' little-endian packed values the
// SDK defines.  We only ever emit BGRA.
private let kNDIFourCC_BGRA: UInt32 = fourCC("BGRA")
/// 8-bit 4:2:0 bi-planar YCbCr — the decoders' own output, sent untouched.
private let kNDIFourCC_NV12: UInt32 = fourCC("NV12")

/// Build a FourCC the way the NDI SDK does: the four ASCII bytes packed
/// little-endian (byte 0 in the low 8 bits).  e.g. "BGRA" → 0x41524742.
private func fourCC(_ s: StaticString) -> UInt32 {
    precondition(s.utf8CodeUnitCount == 4, "FourCC must be 4 ASCII chars")
    var value: UInt32 = 0
    s.withUTF8Buffer { buf in
        value = UInt32(buf[0]) | (UInt32(buf[1]) << 8) | (UInt32(buf[2]) << 16) | (UInt32(buf[3]) << 24)
    }
    return value
}

/// NDIlib_frame_format_type_e — we always send full progressive frames.
private let kNDIFrameFormat_Progressive: Int32 = 1

/// NDIlib_send_timecode_synthesize — let the SDK stamp a monotonic timecode
/// when we pass this sentinel.  (INT64_MAX in the headers.)
private let kNDISendTimecodeSynthesize: Int64 = Int64.max

/// C-compatible mirror of `NDIlib_send_create_t`.
/// Field order and types match the SDK header exactly — this struct is passed
/// by pointer straight into NDIlib_send_create.
private struct NDIlib_send_create_t {
    var p_ndi_name: UnsafePointer<CChar>?
    var p_groups: UnsafePointer<CChar>?
    var clock_video: Bool
    var clock_audio: Bool
}

/// C-compatible mirror of `NDIlib_video_frame_v2_t`.
/// CRITICAL: field order, sizes and alignment must match the SDK header, or the
/// sender reads garbage.  This layout is the documented v2 video frame.
private struct NDIlib_video_frame_v2_t {
    var xres: Int32 = 0
    var yres: Int32 = 0
    var FourCC: UInt32 = 0
    var frame_rate_N: Int32 = 30000
    var frame_rate_D: Int32 = 1000
    var picture_aspect_ratio: Float = 0          // 0 = derive from xres/yres
    var frame_format_type: Int32 = kNDIFrameFormat_Progressive
    var timecode: Int64 = kNDISendTimecodeSynthesize
    var p_data: UnsafeMutablePointer<UInt8>? = nil
    var line_stride_in_bytes: Int32 = 0
    var p_metadata: UnsafePointer<CChar>? = nil
    var timestamp: Int64 = 0
}

// C function-pointer typealiases for the five entry points we resolve.
private typealias NDIlib_initialize_t        = @convention(c) () -> Bool
private typealias NDIlib_destroy_t           = @convention(c) () -> Void
// NOTE: @convention(c) function types may only reference C-representable
// parameter types — a pointer to a Swift struct is NOT (hence the "not
// representable in Objective-C" errors). We pass the descriptor/frame structs
// as UnsafeRawPointer and bridge with withUnsafePointer(to:) at the call sites.
private typealias NDIlib_send_create_t_fn    = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
private typealias NDIlib_send_destroy_t      = @convention(c) (OpaquePointer?) -> Void
private typealias NDIlib_send_send_video_v2_t = @convention(c) (OpaquePointer?, UnsafeRawPointer?) -> Void

// MARK: - Runtime loader

/// Loads libndi once per process and vends the resolved symbols.  Shared across
/// every NDIOutput instance — `NDIlib_initialize` is process-global and must be
/// paired with exactly one `NDIlib_destroy`, so we never call destroy here (the
/// OS reclaims the handle at exit; calling destroy while another sender is live
/// would corrupt it).
private final class NDIRuntime {
    static let shared = NDIRuntime()

    // Resolved on the first SUCCESSFUL load; nil until then.  Written once under
    // `lock`, then read-only — so the per-frame `sendVideo` read needs no lock.
    private(set) var initialize: NDIlib_initialize_t?
    private(set) var sendCreate: NDIlib_send_create_t_fn?
    private(set) var sendVideo: NDIlib_send_send_video_v2_t?
    private(set) var sendDestroy: NDIlib_send_destroy_t?
    private(set) var isLoaded = false

    private var handle: UnsafeMutableRawPointer?
    private var didInitialize = false
    private let lock = NSLock()

    private init() {}   // NO eager load — the dlopen lives in loadIfNeeded (retryable).

    /// (Re)attempt to dlopen libndi + resolve its symbols if not already loaded.  A
    /// cheap no-op once loaded.  RETRYABLE (the load is here, not in `init`) so
    /// "install the NDI runtime, THEN toggle the output on" works WITHOUT restarting
    /// the app — a first failed attempt no longer sticks for the whole session.
    @discardableResult
    func loadIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    private func loadLocked() -> Bool {   // caller holds `lock`
        if isLoaded { return true }
        guard let h = NDIRuntime.openLibrary() else { return false }
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let raw = dlsym(h, name) else {
                print("[NDIOutput] libndi loaded but symbol '\(name)' is missing — incompatible runtime.")
                return nil
            }
            return unsafeBitCast(raw, to: T.self)
        }
        let initFn   = sym("NDIlib_initialize",          as: NDIlib_initialize_t.self)
        let createFn = sym("NDIlib_send_create",         as: NDIlib_send_create_t_fn.self)
        let videoFn  = sym("NDIlib_send_send_video_v2",  as: NDIlib_send_send_video_v2_t.self)
        let destFn   = sym("NDIlib_send_destroy",        as: NDIlib_send_destroy_t.self)
        let destroyOK = dlsym(h, "NDIlib_destroy") != nil   // verified, not stored (see class note)
        guard initFn != nil, createFn != nil, videoFn != nil, destFn != nil, destroyOK else {
            dlclose(h); return false   // incompatible runtime — leave room for a later retry
        }
        handle = h
        initialize = initFn; sendCreate = createFn; sendVideo = videoFn; sendDestroy = destFn
        isLoaded = true
        return true
    }

    /// Load-if-needed, then call `NDIlib_initialize` at most once for the process.
    /// False if the runtime is absent or refuses (e.g. unsupported CPU).
    func ensureInitialized() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard loadLocked(), let initialize else { return false }
        if didInitialize { return true }
        if initialize() {
            didInitialize = true
            return true
        }
        print("[NDIOutput] NDIlib_initialize() returned false — runtime refused to start.")
        return false
    }

    /// Search the documented install locations + env overrides for libndi.
    private static func openLibrary() -> UnsafeMutableRawPointer? {
        var candidates: [String] = []

        // Env overrides the SDK itself honours (V6 then V5 then generic).
        let env = ProcessInfo.processInfo.environment
        for key in ["NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5", "NDI_RUNTIME_DIR"] {
            if let dir = env[key], !dir.isEmpty {
                candidates.append(dir + "/libndi.dylib")
                candidates.append(dir + "/libndi_advanced.dylib")
            }
        }

        // Common fixed locations (installer + Homebrew-style + SDK bundle).
        candidates.append(contentsOf: [
            "/usr/local/lib/libndi.dylib",
            "/usr/local/lib/libndi.4.dylib",
            "/opt/homebrew/lib/libndi.dylib",
            "/opt/homebrew/lib/libndi.4.dylib",
            "/Library/NDI SDK for Apple/lib/macOS/libndi_advanced.dylib",
            "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
        ])

        // Last resort: let the dynamic loader resolve by bare name from any
        // directory already on the loader path (DYLD_LIBRARY_PATH, etc.).
        candidates.append(contentsOf: ["libndi.4.dylib", "libndi.dylib"])

        for path in candidates {
            if let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                print("[NDIOutput] Loaded NDI runtime from \(path)")
                return h
            }
        }

        print("""
        [NDIOutput] libndi not found. Install the free NDI Tools / NDI Runtime \
        from https://ndi.video (see docs/NDI-SETUP.md). NDI output is disabled; \
        the rest of Airlive Bridge works normally.
        """)
        return nil
    }
}

// MARK: - NDIOutput

/// One NDI sender.  `label` is the NDI source name as it appears in receivers
/// (OBS, vMix, Studio Monitor) — renaming it recreates the sender so the new
/// name takes effect.
final class NDIOutput: VideoOutput {
    let id: UUID
    let kind: OutputKind = .ndi

    /// Card-visible failure (see VideoOutput.lastError).  Main-confined.
    private(set) var lastError: String?
    /// Fires on MAIN when `lastError` changes — the model nudges objectWillChange
    /// so the card re-renders (VideoOutput isn't observable).
    var onStateChanged: (() -> Void)?
    private func reportError(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastError != message else { return }
            self.lastError = message
            self.onStateChanged?()
        }
    }

    func clearError() { reportError(nil) }

    /// The NDI source name.  Setting it while live recreates the sender.
    var label: String {
        didSet {
            guard label != oldValue, isLive else { return }
            // Rename on a live sender: tear down and bring up under the new name.
            restartSender()
        }
    }

    /// Live flag, read by the frame path (`present()` → `send()`) and by the UI
    /// (the output card's status pill / toggle) — both potentially off-thread
    /// from where it is mutated.  Backed by `_isLive` under `lock` so a read can
    /// never observe a torn write while start/stop flips it.
    var isLive: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isLive
    }
    private var _isLive: Bool = false

    // NDI sender handle (opaque pointer from NDIlib_send_create).
    private var sender: OpaquePointer?

    // Serialize start/stop/send/rename — send() runs on the channel's frame
    // path, the others from the UI; the sender handle must not be torn down
    // mid-send.  Also guards `_isLive` (the public `isLive` accessor takes it).
    private let lock = NSLock()

    // Serializes ONLY the actual SDK `sendVideo` call against sender teardown (stop/rename), so the
    // send can run OUTSIDE `lock`.  Rationale: `sendVideo` can block on a slow/backed-up NDI receiver;
    // holding `lock` across it would stall a main-thread `send()` that only needs `lock` to check
    // state.  `sender` is read/written only under this lock; deliver() re-reads it here so a teardown
    // landing mid-convert skips the send cleanly instead of using a freed handle (UAF).
    private let senderLock = NSLock()

    // The program tap calls `send` on MAIN (BridgeModel.feedProgram); the BGRA convert +
    // synchronous SDK send must NOT block main per frame.  Hand them to this serial queue.
    // `sendInFlight` drops a frame while one is still being sent, so a slow/stalled NDI
    // receiver can never back up a queue of retained pixel buffers (memory).  Guarded by `lock`.
    private let sendQueue = DispatchQueue(label: "studio.airlive.bridge.ndi.send", qos: .userInteractive)
    private var sendInFlight = false
    // While a send is in flight, the newest frame is STASHED here (latest-wins) instead of dropped,
    // then delivered as the tail when the send completes.  This guarantees a ONE-SHOT frame — the
    // black dead-signal pushed on a program drop / cut-to-no-video — is never lost to the in-flight
    // drop (which would freeze the program on the previous camera's last frame).  Bounded to one
    // IOSurface-backed buffer (CF-retained, no copy), so memory stays bounded.
    private var pendingBuffer: CVPixelBuffer?
    private var pendingTimeNs: UInt64 = 0

    // BGRA conversion fallback — created lazily only if a non-BGRA frame arrives.
    private var transferSession: VTPixelTransferSession?
    // Recycled destination pool for the conversion path (no per-frame alloc).
    private var conversionPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    init(id: UUID = UUID(), label: String) {
        self.id = id
        self.label = label
    }

    deinit {
        stop()
    }

    // MARK: VideoOutput lifecycle

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !_isLive else { return }
        startSenderLocked()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        destroySenderLocked()
        _isLive = false
        // Drop the conversion pool (~25 MB of IOSurfaces at 1080p) and the transfer session —
        // both exist only for a source NDI can't take directly, which is no longer the normal
        // case at all, and a stopped output must not keep IOSurfaces warm.  Safe under `lock`
        // (every access is lock-held in sendableBufferLocked); both rebuild lazily on next use.
        conversionPool = nil
        poolWidth = 0
        poolHeight = 0
        if let t = transferSession { VTPixelTransferSessionInvalidate(t) }
        transferSession = nil
    }

    /// Publish one decoded frame.  No-op when not live.  Called on MAIN (the program tap) but
    /// the convert + SDK send run OFF main on `sendQueue`; a frame arriving while a send is
    /// still in flight is dropped (latest-wins, bounded memory).  The IOSurface-backed buffer
    /// is retained across the hand-off — no copy.
    func send(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {
        lock.lock()
        guard _isLive else { lock.unlock(); return }
        if sendInFlight {
            // Stash the newest frame (latest-wins) rather than dropping it, so a one-shot dead-signal
            // frame survives; a continuous stream just coalesces to the newest. Delivered as the tail.
            pendingBuffer = pixelBuffer
            pendingTimeNs = timeNs
            lock.unlock()
            return
        }
        sendInFlight = true
        lock.unlock()
        dispatchSend(pixelBuffer, timeNs: timeNs)
    }

    /// Deliver on `sendQueue`; when it finishes, flush any frame stashed during the send (tail
    /// delivery) so the LAST buffer is always sent.  sendInFlight stays true across the chain, so
    /// sends remain strictly serialized and memory stays bounded to one pending buffer.
    private func dispatchSend(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.deliver(pixelBuffer, timeNs: timeNs)
            self.lock.lock()
            if let pending = self.pendingBuffer {
                let t = self.pendingTimeNs
                self.pendingBuffer = nil
                self.lock.unlock()
                self.dispatchSend(pending, timeNs: t)
            } else {
                self.sendInFlight = false
                self.lock.unlock()
            }
        }
    }

    /// The actual send, off main on `sendQueue`.
    private func deliver(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {
        // Prepare under `lock` (the conversion pool + transfer session are lock-guarded), then
        // RELEASE `lock` before the SDK send.  The send goes out under `senderLock` instead — a
        // slow receiver blocking `sendVideo` must never hold `lock` and stall a main-thread
        // send() checking state.
        lock.lock()
        guard _isLive, NDIRuntime.shared.sendVideo != nil else { lock.unlock(); return }
        let outBuffer = sendableBufferLocked(from: pixelBuffer)
        lock.unlock()
        guard let outBuffer, let sendVideo = NDIRuntime.shared.sendVideo else { return }

        CVPixelBufferLockBaseAddress(outBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(outBuffer, .readOnly) }

        let width  = CVPixelBufferGetWidth(outBuffer)
        let height = CVPixelBufferGetHeight(outBuffer)
        guard let wire = wireLayout(of: outBuffer, height: height) else { return }

        var frame = NDIlib_video_frame_v2_t()
        frame.xres = Int32(width)
        frame.yres = Int32(height)
        frame.FourCC = wire.fourCC
        frame.line_stride_in_bytes = Int32(wire.stride)
        frame.p_data = wire.base.assumingMemoryBound(to: UInt8.self)
        // Convert the monotonic host nanoseconds to NDI's 100-ns timestamp unit.
        // (NDI timestamps are in 100-nanosecond intervals.)
        frame.timestamp = Int64(bitPattern: timeNs / 100)
        // Let the SDK synthesize a monotonic broadcast timecode for the receiver.
        frame.timecode = kNDISendTimecodeSynthesize

        // send_send_video_v2 reads p_data synchronously here; we never retain pixelBuffer past this
        // call.  Re-read `sender` under senderLock: if stop()/rename tore it down while we prepared,
        // skip — sending to a freed handle is a UAF.  Teardown holds senderLock, so it can't free the
        // handle underneath this in-flight send.
        senderLock.lock()
        defer { senderLock.unlock() }
        guard let sender = self.sender else { return }
        withUnsafePointer(to: &frame) { sendVideo(sender, UnsafeRawPointer($0)) }
    }

    /// How this buffer goes on the wire: which NDI FourCC, where the bytes start, and the
    /// stride of the first row.  Returns nil for a layout NDI can't be handed directly.
    ///
    /// NV12 is TWO planes, and NDI reads them as one block: the chroma plane must sit exactly
    /// one luma plane after the start.  VideoToolbox allocates both in a single IOSurface and
    /// normally does exactly that, but "normally" is not "always" — an allocator is free to pad
    /// between planes — so it is checked per frame and a non-contiguous buffer falls back to a
    /// conversion rather than shipping a torn picture.
    private func wireLayout(of buffer: CVPixelBuffer, height: Int) -> (fourCC: UInt32, base: UnsafeMutableRawPointer, stride: Int)? {
        if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            return (kNDIFourCC_BGRA, base, CVPixelBufferGetBytesPerRow(buffer))
        }
        guard CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) == 2,
              let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard luma.advanced(by: lumaStride * height) == chroma else { return nil }
        return (kNDIFourCC_NV12, luma, lumaStride)
    }

    // MARK: Sender lifecycle (lock held by callers)

    private func startSenderLocked() {
        let rt = NDIRuntime.shared
        guard rt.loadIfNeeded() else {   // RETRIES the dlopen — picks up a runtime installed since launch
            print("[NDIOutput] start('\(label)') skipped — NDI runtime not installed.")
            reportError("NDI runtime isn\u{2019}t installed — get it from ndi.video")
            _isLive = false
            return
        }
        guard rt.ensureInitialized(), let create = rt.sendCreate else {
            print("[NDIOutput] start('\(label)') failed — NDI runtime did not initialize.")
            reportError("NDI runtime failed to initialize")
            _isLive = false
            return
        }

        // The C struct holds a borrowed pointer into our name bytes for the
        // duration of the create call only, so a withCString scope is correct.
        let created: OpaquePointer? = label.withCString { namePtr -> OpaquePointer? in
            var desc = NDIlib_send_create_t(
                p_ndi_name: namePtr,
                p_groups: nil,
                // clock_video:false — DON'T let the SDK sleep-to-pace inside
                // send_video.  feedProgram calls send() on the MAIN thread, so
                // SDK clocking would stall main up to a frame interval EVERY frame.
                // Our frames are already paced by the jitter ring (the timing
                // authority), so we send at the correct cadence without re-clocking.
                clock_video: false,
                clock_audio: false
            )
            return withUnsafePointer(to: &desc) { create(UnsafeRawPointer($0)) }
        }

        guard let created else {
            print("[NDIOutput] NDIlib_send_create returned NULL for '\(label)'.")
            reportError("NDI sender creation failed")
            _isLive = false
            return
        }
        senderLock.lock(); sender = created; senderLock.unlock()
        _isLive = true
        reportError(nil)   // live — clear any stale failure
        print("[NDIOutput] NDI source '\(label)' is live.")
    }

    private func destroySenderLocked() {
        // Hold senderLock so we never free the handle while deliver() is mid-send with it (UAF).
        // Ordering is always lock → senderLock (callers hold `lock`); deliver takes senderLock alone.
        senderLock.lock()
        defer { senderLock.unlock() }
        guard let sender else { return }
        NDIRuntime.shared.sendDestroy?(sender)
        self.sender = nil
        print("[NDIOutput] NDI source torn down.")
    }

    /// Rename = recreate.  Called from the `label` setter while live.  Takes the
    /// lock itself because the setter runs outside start()/stop().
    private func restartSender() {
        lock.lock(); defer { lock.unlock() }
        guard _isLive else { return }
        destroySenderLocked()
        startSenderLocked()
    }

    // MARK: BGRA conversion fallback (lock held by caller)

    /// The buffer to send: `src` itself whenever NDI can take it as-is — which is every
    /// frame from either decoder (contiguous NV12) and every frame from an HDMI capture card
    /// (BGRA) — otherwise a converted copy from the recycled pool.
    private func sendableBufferLocked(from src: CVPixelBuffer) -> CVPixelBuffer? {
        let height = CVPixelBufferGetHeight(src)
        if wireLayout(of: src, height: height) != nil { return src }

        let width = CVPixelBufferGetWidth(src)
        guard let dst = conversionDestinationLocked(width: width, height: height) else { return nil }

        // VTPixelTransferSession, not CoreImage: a fixed-function hardware block instead of an
        // image-processing graph.  CoreImage also colour-manages on the way through, which put
        // NDI on a different colour path from every other consumer of the identical buffer.
        // Lazily built — with the pass-through above, most sessions never convert at all, and
        // an unused session plus its pool is exactly the kind of idle allocation that costs heat.
        if transferSession == nil {
            var session: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                               pixelTransferSessionOut: &session) == noErr,
                  let session else { return nil }
            transferSession = session
        }
        guard let transferSession,
              VTPixelTransferSessionTransferImage(transferSession, from: src, to: dst) == noErr
        else { return nil }
        // Carry the source's colour tags: a pool buffer is born untagged, and an untagged frame
        // is interpreted by whatever the receiver assumes.
        CVBufferPropagateAttachments(src, dst)
        return dst
    }

    /// A recycled BGRA destination buffer at the requested size, rebuilding the
    /// pool only when the frame size changes.
    private func conversionDestinationLocked(width: Int, height: Int) -> CVPixelBuffer? {
        if conversionPool == nil || poolWidth != width || poolHeight != height {
            let pbAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:  width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
            let poolAttrs = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs,
                                          pbAttrs as CFDictionary, &pool) == kCVReturnSuccess,
                  let pool else {
                print("[NDIOutput] failed to create BGRA conversion pool \(width)×\(height).")
                return nil
            }
            conversionPool = pool
            poolWidth = width
            poolHeight = height
        }

        var dst: CVPixelBuffer?
        guard let pool = conversionPool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) == kCVReturnSuccess else {
            return nil
        }
        return dst
    }
}
