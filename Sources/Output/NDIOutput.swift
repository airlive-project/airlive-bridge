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
// for every frame while we're live.  The Studio decoder produces 32BGRA, which
// is exactly NDIlib_FourCC_type_BGRA — so the common path is a zero-conversion
// lock-and-send.  Anything else is converted to BGRA via a cached CIContext.
// We must not retain the buffer past the call, and we don't: send_send_video_v2
// copies (or at minimum reads) the data synchronously before we unlock.

import Foundation
import CoreVideo
import CoreImage

// MARK: - NDI C ABI (minimal, matches Processing.NDI.* headers)

// FourCC codes are the literal 'BGRA' / 'UYVY' little-endian packed values the
// SDK defines.  We only ever emit BGRA.
private let kNDIFourCC_BGRA: UInt32 = fourCC("BGRA")

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

    let isLoaded: Bool
    let initialize: NDIlib_initialize_t?
    let sendCreate: NDIlib_send_create_t_fn?
    let sendVideo: NDIlib_send_send_video_v2_t?
    let sendDestroy: NDIlib_send_destroy_t?

    private let handle: UnsafeMutableRawPointer?
    private var didInitialize = false
    private let lock = NSLock()

    private init() {
        guard let handle = NDIRuntime.openLibrary() else {
            self.handle = nil
            self.isLoaded = false
            self.initialize = nil
            self.sendCreate = nil
            self.sendVideo = nil
            self.sendDestroy = nil
            return
        }
        self.handle = handle

        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let raw = dlsym(handle, name) else {
                print("[NDIOutput] libndi loaded but symbol '\(name)' is missing — incompatible runtime.")
                return nil
            }
            return unsafeBitCast(raw, to: T.self)
        }

        let initFn   = sym("NDIlib_initialize",          as: NDIlib_initialize_t.self)
        let createFn = sym("NDIlib_send_create",         as: NDIlib_send_create_t_fn.self)
        let videoFn  = sym("NDIlib_send_send_video_v2",  as: NDIlib_send_send_video_v2_t.self)
        let destFn   = sym("NDIlib_send_destroy",        as: NDIlib_send_destroy_t.self)

        self.initialize  = initFn
        self.sendCreate  = createFn
        self.sendVideo   = videoFn
        self.sendDestroy = destFn

        // All five must resolve (NDIlib_destroy is intentionally not stored —
        // see class note — but we verify it exists as a sanity check).
        let destroyOK = dlsym(handle, "NDIlib_destroy") != nil
        self.isLoaded = initFn != nil && createFn != nil && videoFn != nil && destFn != nil && destroyOK
    }

    /// Call `NDIlib_initialize` at most once for the whole process.  Returns
    /// false if the runtime refuses (e.g. unsupported CPU) — start() then bails.
    func ensureInitialized() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isLoaded, let initialize else { return false }
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

    // The program tap calls `send` on MAIN (BridgeModel.feedProgram); the BGRA convert +
    // synchronous SDK send must NOT block main per frame.  Hand them to this serial queue.
    // `sendInFlight` drops a frame while one is still being sent, so a slow/stalled NDI
    // receiver can never back up a queue of retained pixel buffers (memory).  Guarded by `lock`.
    private let sendQueue = DispatchQueue(label: "studio.airlive.bridge.ndi.send", qos: .userInteractive)
    private var sendInFlight = false

    // BGRA conversion fallback — created lazily only if a non-BGRA frame arrives.
    private var ciContext: CIContext?
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
    }

    /// Publish one decoded frame.  No-op when not live.  Called on MAIN (the program tap) but
    /// the convert + SDK send run OFF main on `sendQueue`; a frame arriving while a send is
    /// still in flight is dropped (latest-wins, bounded memory).  The IOSurface-backed buffer
    /// is retained across the hand-off — no copy.
    func send(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {
        lock.lock()
        guard _isLive, !sendInFlight else { lock.unlock(); return }
        sendInFlight = true
        lock.unlock()
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.deliver(pixelBuffer, timeNs: timeNs)
            self.lock.lock(); self.sendInFlight = false; self.lock.unlock()
        }
    }

    /// The actual convert + SDK send, off main on `sendQueue`.
    private func deliver(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard _isLive, let sender, let sendVideo = NDIRuntime.shared.sendVideo else { return }

        let outBuffer = bgraBufferLocked(from: pixelBuffer)
        guard let outBuffer else { return }

        CVPixelBufferLockBaseAddress(outBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(outBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(outBuffer) else { return }
        let width  = CVPixelBufferGetWidth(outBuffer)
        let height = CVPixelBufferGetHeight(outBuffer)
        let stride = CVPixelBufferGetBytesPerRow(outBuffer)

        var frame = NDIlib_video_frame_v2_t()
        frame.xres = Int32(width)
        frame.yres = Int32(height)
        frame.FourCC = kNDIFourCC_BGRA
        frame.line_stride_in_bytes = Int32(stride)
        frame.p_data = base.assumingMemoryBound(to: UInt8.self)
        // Convert the monotonic host nanoseconds to NDI's 100-ns timestamp unit.
        // (NDI timestamps are in 100-nanosecond intervals.)
        frame.timestamp = Int64(bitPattern: timeNs / 100)
        // Let the SDK synthesize a monotonic broadcast timecode for the receiver.
        frame.timecode = kNDISendTimecodeSynthesize

        // send_send_video_v2 reads p_data synchronously here; safe to unlock on
        // return (defer above).  We never retain pixelBuffer past this call.
        withUnsafePointer(to: &frame) { sendVideo(sender, UnsafeRawPointer($0)) }
    }

    // MARK: Sender lifecycle (lock held by callers)

    private func startSenderLocked() {
        let rt = NDIRuntime.shared
        guard rt.isLoaded else {
            print("[NDIOutput] start('\(label)') skipped — NDI runtime not installed.")
            _isLive = false
            return
        }
        guard rt.ensureInitialized(), let create = rt.sendCreate else {
            print("[NDIOutput] start('\(label)') failed — NDI runtime did not initialize.")
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
            _isLive = false
            return
        }
        sender = created
        _isLive = true
        print("[NDIOutput] NDI source '\(label)' is live.")
    }

    private func destroySenderLocked() {
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

    /// Return a BGRA buffer for `src`: `src` itself when it's already 32BGRA
    /// (the common Studio-decoder case, zero copy), otherwise a converted copy
    /// from the recycled conversion pool.  Returns nil only if conversion fails.
    private func bgraBufferLocked(from src: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA {
            return src
        }

        let width  = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        guard let dst = conversionDestinationLocked(width: width, height: height) else {
            return nil
        }

        // Lazy first-use allocation, under `lock`: the Studio decoder emits
        // 32BGRA, so this conversion path (and thus the CIContext) is only ever
        // hit by a non-BGRA source.  Building the CIContext can take 50–200 ms,
        // and it happens INSIDE the send lock, so the FIRST non-BGRA frame blocks
        // the frame path briefly — an accepted one-time cost for a rare path.
        // Do not remove this lazy guard to "simplify": eager allocation would pay
        // that cost on every output even when BGRA is the only format seen.
        let context = ciContext ?? {
            let c = CIContext(options: [.useSoftwareRenderer: false])
            ciContext = c
            return c
        }()

        let image = CIImage(cvPixelBuffer: src)
        context.render(image, to: dst,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
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
