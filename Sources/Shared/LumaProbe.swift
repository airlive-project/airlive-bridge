// LumaProbe.swift — both halves of the virtual camera's per-hop pixel probe.
//
// Compiled into the app AND the extension, from this one file.  The two ends only tell you
// anything when they read pixels the SAME way — the whole point is to compare their numbers —
// and this used to be a hand-kept copy in VirtualCamera/VCamLog.swift with a comment asking
// whoever edited one to remember the other.  The extension stays every bit as self-contained:
// a source file compiled into two binaries links nothing between them.

import Foundation
import CoreVideo

/// Luma statistics of one frame, sampled sparsely.
///
/// The project's rule for colour bugs, learned the expensive way: probe PIXEL VALUES at every
/// hop before touching a single tag or display path.  Range trouble is unmistakable in these
/// numbers — video-range luma lives in 16…235, and a min pinned at 0 with a fat count of
/// zeros is shadows being clipped, not a picture that happens to be dark.
///
/// Sparse on purpose: 32×32 samples is a few thousand reads, once a second.
enum LumaProbe {
    static func describe(_ buffer: CVPixelBuffer?) -> String {
        guard let buffer, CVPixelBufferIsPlanar(buffer),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return "" }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return "" }

        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        var lo = 255, hi = 0, total = 0, count = 0, atFloor = 0
        let steps = 32
        for sy in 0..<steps {
            let y = height * sy / steps
            for sx in 0..<steps {
                let v = Int(pixels[y * stride + width * sx / steps])
                lo = min(lo, v); hi = max(hi, v)
                total += v; count += 1
                if v < 16 { atFloor += 1 }
            }
        }
        guard count > 0 else { return "" }
        return "luma \(lo)–\(hi) avg \(total / count) below16=\(atFloor)/\(count) \(width)x\(height)"
    }
}
