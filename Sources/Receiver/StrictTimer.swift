// StrictTimer.swift - run a block at an exact moment, for frames released on a schedule.
//
// `asyncAfter` lets the system shift the wake-up by up to ±8 ms to save power. Invisible in the
// Bridge's own window, which repaints whenever a frame lands - but the virtual camera re-times
// frames to its 11 ms pull grid and OBS samples at exactly 33.3 ms, so ±8 ms turned into repeated
// and dropped frames there. Measured 2026-10-05 on OBS's own recording of the camera: 22 repeated
// frames in 232 with asyncAfter, 0 in 232 with this strict one-shot timer.

import Foundation

extension DispatchQueue {
    /// `asyncAfter` without the power-saving slack: a strict one-shot timer with zero leeway.
    func strictAfter(_ delay: TimeInterval, execute work: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self)
        timer.schedule(deadline: .now() + delay, leeway: .nanoseconds(0))
        timer.setEventHandler {
            timer.cancel()   // one-shot; cancelling also releases this handler
            work()
        }
        timer.resume()
    }
}
