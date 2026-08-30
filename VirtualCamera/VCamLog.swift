// VCamLog.swift — the extension's only voice.
//
// A camera extension has no window, no console and no user: macOS launches it as
// `_cmiodalassistants`, and if it misbehaves the only symptom anyone sees is a black
// rectangle in Zoom.  Every state change on the frame path is therefore logged, so the
// question "does the picture reach the consumer?" is answered by
//
//     log show --last 10m --predicate 'subsystem == "studio.airlive.vcam"'
//
// Everything here logs at NOTICE, not INFO: info-level messages live in a memory ring
// buffer and are gone by the time anyone runs `log show`, which makes them useless for
// exactly the after-the-fact question they exist to answer.
//
// instead of by guesswork.  Per-frame lines are aggregated to 1 Hz — a log line at 30 fps
// would be its own thermal problem.

import Foundation
import CoreVideo
import os

let vcamLog = Logger(subsystem: "studio.airlive.vcam", category: "frames")

/// Counts events and emits ONE line per second.  Cheap enough for the frame path:
/// two integer adds and a clock read.
final class RateLog {
    private let label: String
    private let lock = NSLock()
    private var count = 0
    private var last = Date()

    init(_ label: String) { self.label = label }

    func tick(_ note: @autoclosure () -> String = "") {
        lock.lock()
        count += 1
        let now = Date()
        guard now.timeIntervalSince(last) >= 1.0 else { lock.unlock(); return }
        let n = count, extra = note()
        count = 0; last = now
        lock.unlock()
        vcamLog.notice("\(self.label, privacy: .public) \(n)/s \(extra, privacy: .public)")
    }
}


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
