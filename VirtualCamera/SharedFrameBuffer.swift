// SharedFrameBuffer.swift — the one channel between the Bridge and its camera extension.
//
// Compiled into BOTH targets.  They are separate processes with separate lifetimes:
// the extension is launched by macOS when an app opens the camera, and the Bridge may
// not be running at all.  So the channel has to be something that simply exists — a
// memory-mapped file in the shared App Group container — rather than a connection one
// side has to accept.  This is what Apple's own camera-extension template is set up
// for (its entitlements carry nothing but the App Group).
//
// Layout: a small header + two full frame slots.  The writer fills the slot the reader
// is NOT reading and then publishes its index, so a reader never copies a half-written
// frame.  Frames are BGRA at a fixed 1080p, matching the stream's declared format —
// no negotiation, nothing to get out of sync.

import Foundation
import CoreVideo

enum SharedFrame {
    /// Must match the extension's declared stream format.
    static let width = 1920
    static let height = 1080
    static let bytesPerRow = width * 4          // BGRA
    static let slotBytes = bytesPerRow * height
    static let slots = 2
    static let headerBytes = 64                 // generous: keeps slots page-aligned
    static let totalBytes = headerBytes + slotBytes * slots

    /// App Group id — must be identical in both targets' entitlements.
    static let appGroup = "group.studio.airlive.bridge"
    static let fileName = "vcam-frame.bin"

    /// Path of the backing file, or nil when the App Group is unavailable (which is a
    /// configuration error, not a runtime condition — both sides log and degrade).
    static func fileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    // Header word offsets (each 8 bytes, naturally aligned).
    static let offMagic = 0      // "ARLVCAM1"
    static let offLatest = 8     // index of the slot holding the newest complete frame
    static let offSeq = 16       // bumped on every publish; readers use it to skip repeats
    static let magic: UInt64 = 0x4152_4C56_4341_4D31
}

/// Maps the shared file once and hands out a raw pointer.  Both sides use this so the
/// mapping rules (size, creation, magic) live in exactly one place.
final class SharedFrameMapping {
    let base: UnsafeMutableRawPointer
    private let handle: FileHandle
    private let length: Int

    init?(createIfMissing: Bool) {
        guard let url = SharedFrame.fileURL() else { return nil }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard createIfMissing else { return nil }
            fm.createFile(atPath: url.path, contents: nil)
            // Size it up front: mmap of a short file faults on access.
            if let h = try? FileHandle(forWritingTo: url) {
                try? h.truncate(atOffset: UInt64(SharedFrame.totalBytes))
                try? h.close()
            }
        }
        guard let h = try? FileHandle(forUpdating: url) else { return nil }
        handle = h
        length = SharedFrame.totalBytes
        let p = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, h.fileDescriptor, 0)
        guard let p, p != MAP_FAILED else { try? h.close(); return nil }
        base = p
    }

    deinit {
        munmap(base, length)
        try? handle.close()
    }

    func word(_ offset: Int) -> UInt64 {
        base.load(fromByteOffset: offset, as: UInt64.self)
    }
    func setWord(_ offset: Int, _ value: UInt64) {
        base.storeBytes(of: value, toByteOffset: offset, as: UInt64.self)
    }
    func slot(_ index: Int) -> UnsafeMutableRawPointer {
        base.advanced(by: SharedFrame.headerBytes + index * SharedFrame.slotBytes)
    }
}

// MARK: - Reader (extension side)

/// Reads the newest published frame.  Never blocks and never fails loudly: if the
/// Bridge has not published anything the caller shows its placeholder instead.
final class SharedFrameReader {
    private var mapping: SharedFrameMapping?
    private var lastSeq: UInt64 = 0

    init() { mapping = SharedFrameMapping(createIfMissing: false) }

    /// Copy the newest frame into `buffer` (allocated on first use and then reused).
    /// Returns nil when nothing has ever been published, so the caller can fall back.
    func latestFrame(into buffer: inout CVPixelBuffer?) -> CVPixelBuffer? {
        // The Bridge may start after the extension; retry the mapping until it exists.
        if mapping == nil { mapping = SharedFrameMapping(createIfMissing: false) }
        guard let m = mapping, m.word(SharedFrame.offMagic) == SharedFrame.magic else { return nil }
        let seq = m.word(SharedFrame.offSeq)
        guard seq != 0 else { return nil }

        if buffer == nil {
            let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            var out: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, SharedFrame.width, SharedFrame.height,
                                kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
            buffer = out
        }
        guard let px = buffer else { return nil }

        // Nothing new since the last tick → republish the same buffer (a webcam must keep
        // a steady cadence even when the program is a still frame).
        if seq == lastSeq { return px }

        let index = Int(m.word(SharedFrame.offLatest)) % SharedFrame.slots
        CVPixelBufferLockBaseAddress(px, [])
        if let dst = CVPixelBufferGetBaseAddress(px) {
            let dstStride = CVPixelBufferGetBytesPerRow(px)
            let src = m.slot(index)
            if dstStride == SharedFrame.bytesPerRow {
                memcpy(dst, src, SharedFrame.slotBytes)
            } else {
                for row in 0 ..< SharedFrame.height {
                    memcpy(dst.advanced(by: row * dstStride),
                           src.advanced(by: row * SharedFrame.bytesPerRow),
                           SharedFrame.bytesPerRow)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(px, [])
        lastSeq = seq
        return px
    }
}

// MARK: - Writer (Bridge side)

/// Publishes program frames for the extension.  Single writer by construction — only
/// the Bridge's virtual-camera output calls this.
final class SharedFrameWriter {
    private var mapping: SharedFrameMapping?
    private var next = 0

    init?() {
        mapping = SharedFrameMapping(createIfMissing: true)
        guard let m = mapping else { return nil }
        m.setWord(SharedFrame.offMagic, SharedFrame.magic)
    }

    /// Copy one BGRA frame in and publish it.  `src` must be 1080p BGRA; the caller
    /// scales/converts before this point so the hot path here is a straight memcpy.
    func publish(_ pixelBuffer: CVPixelBuffer) {
        guard let m = mapping else { return }
        guard CVPixelBufferGetWidth(pixelBuffer) == SharedFrame.width,
              CVPixelBufferGetHeight(pixelBuffer) == SharedFrame.height,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let src = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let srcStride = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Write to the slot the reader is not pointed at, THEN publish the index — so a
        // reader that runs mid-write still sees a whole earlier frame.
        let slot = next
        let dst = m.slot(slot)
        if srcStride == SharedFrame.bytesPerRow {
            memcpy(dst, src, SharedFrame.slotBytes)
        } else {
            for row in 0 ..< SharedFrame.height {
                memcpy(dst.advanced(by: row * SharedFrame.bytesPerRow),
                       src.advanced(by: row * srcStride),
                       SharedFrame.bytesPerRow)
            }
        }
        m.setWord(SharedFrame.offLatest, UInt64(slot))
        m.setWord(SharedFrame.offSeq, m.word(SharedFrame.offSeq) &+ 1)
        next = (slot + 1) % SharedFrame.slots
    }
}
