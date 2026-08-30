// VCamLog.swift — the extension's only voice.
//
// A camera extension has no window, no console and no user: macOS launches it as
// `_cmiodalassistants`, and if it misbehaves the only symptom anyone sees is a black
// rectangle in Zoom.  Every state change on the frame path is therefore logged, so the
// question "does the picture reach the consumer?" is answered by reading, not guessing:
//
//     /usr/bin/log show --last 10m --predicate 'subsystem == "studio.airlive.vcam"'
//
// FULL PATH, always: a `log` shell function shadows the tool in this project's zsh, and a
// whole day went into "the extension writes nothing" before anyone noticed the command was
// never the one being run.
//
// Everything here logs at NOTICE, not INFO: info-level messages live in a memory ring buffer
// and are gone by the time anyone runs `log show`, which makes them useless for exactly the
// after-the-fact question they exist to answer.  Per-frame lines are aggregated to 1 Hz — a
// log line at 30 fps would be its own thermal problem.

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
