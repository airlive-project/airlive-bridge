// StayAwake.swift - keeps the Mac awake while the Bridge is running a show.
//
// A show can run for hours with nobody touching the Mac, especially with Auto Cut on. Left to its
// idle timers, macOS would sleep the Mac (every camera and output drops), blank the displays (an
// HDMI output to a projector IS a display) and put the Bridge in App Nap once its window is behind
// another app, which delays its main-thread timers.
//
// Apple's documented answer is an activity (`ProcessInfo.beginActivity`, Energy Efficiency Guide
// for Mac Apps, "Prevent App Nap"); OBS holds the same while it streams or records. It needs no
// permission and no entitlement, it shows in Activity Monitor ("Preventing Sleep") and in
// `pmset -g assertions` under the reason below, and macOS drops it when the app quits. It is held
// only while there is a show, so an idle Bridge never keeps a laptop awake.

import Foundation

final class StayAwake {
    private var activity: NSObjectProtocol?

    /// `.userInitiated` covers idle SYSTEM sleep and App Nap; idle DISPLAY sleep is added on top.
    /// Not `.latencyCritical`: Apple asks for it only where it is truly needed, it costs energy,
    /// and App Nap is already off without it.
    func update(onShow: Bool) {
        if onShow, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled],
                reason: "Airlive Bridge is on air")
            print("[StayAwake] show running - the Mac and its displays stay awake")
        } else if !onShow, let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
            print("[StayAwake] no show - the Mac may sleep again")
        }
    }
}
