// Updater.swift — real Sparkle auto-update (background checks + in-app install).
//
// Airlive Bridge updates the "normal" Mac way: Sparkle checks the appcast on a
// schedule, and when a newer SIGNED build exists it offers "Install and Relaunch"
// — the app downloads the notarized DMG, verifies Apple's signature + our EdDSA,
// swaps itself in /Applications and relaunches.  No website, no manual download,
// no browser hop.  (Replaces the earlier hand-rolled version.json check.)
//
//   Feed  = appcast.xml at this repo's ROOT, served by GitHub raw — SUFeedURL in
//           project.yml/Info.plist.  A URL we fully own; never 404s; no website.
//   Trust = SUPublicEDKey (Info.plist) verifies every download's EdDSA signature;
//           the private key lives ONLY in the login Keychain.  scripts/package.sh
//           runs sign_update on the final notarized DMG and prints the signature.
//
// Cutting a release stays one repo, one push:
//   1. bump MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml
//   2. scripts/package.sh → notarized Airlive-Bridge-X.Y.Z.dmg (prints edSignature + length)
//   3. add an <item> to appcast.xml (sparkle:version = the new CFBundleVersion; paste sig+length)
//   4. gh release create vX.Y.Z --latest  (upload the versioned dmg + the stable Airlive-Bridge.dmg copy)
//   5. git commit + push  →  every running Bridge auto-detects it within a day,
//      or immediately when the operator picks "Check for Updates…".
//
// This is the canonical Sparkle-in-SwiftUI recipe (Sparkle docs: "Adding a Check
// for Updates menu item with SwiftUI"): the App holds one SPUStandardUpdaterController;
// the menu item is a tiny View whose view-model publishes whether a check is allowed.

import SwiftUI
import Sparkle
import AppKit

/// Publishes whether the user may start an update check right now, so the menu
/// item can disable itself while a check is already in flight.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates…" menu item.  Owns its view-model; the updater itself
/// is owned for the whole app lifetime by AirliveBridgeApp.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}


// MARK: - Never interrupt a show

/// Holds the updater back while the Bridge is on air.
///
/// Sparkle's scheduled check is a TIMER, not a launch-time thing: with automatic checks on it
/// re-checks roughly once a day for as long as the app keeps running.  So on a machine that
/// stays up through a service, the "Install and Relaunch" prompt can appear in the middle of
/// one — and installing quits the app, which takes every camera, every output and the broadcast
/// with it.  One stray click during a service is all it would take.
///
/// Three gates, because there are three moments it could happen:
///   1. the CHECK doesn't run at all while on air, so the prompt never appears;
///   2. an update FOUND by a check that started a moment before going live is not offered;
///   3. and if a prompt from before the show is still on screen and somebody clicks it anyway,
///      the relaunch waits until the outputs are off instead of cutting the feed.
///
/// Nothing is skipped or lost — every gate defers, and the update installs the moment the show
/// is over.  The operator can still ask for it deliberately from the menu; they are told why
/// it is not happening rather than watching nothing happen.
final class UpdateGate: NSObject, SPUUpdaterDelegate {

    private weak var model: BridgeModel?

    init(model: BridgeModel) {
        self.model = model
        super.init()
        verifyGatesAreReachable()
    }

    /// Every gate below is an OPTIONAL protocol method: Sparkle asks whether we implement it and
    /// skips it if we do not.  So a Swift signature that does not match the Objective-C selector
    /// compiles perfectly, is never called, and the gate silently is not there — the exact shape
    /// of failure that would only be discovered by an update prompt appearing mid-service.
    /// Ask the runtime instead of trusting the spelling.
    private func verifyGatesAreReachable() {
        let gates = [
            "updater:mayPerformUpdateCheck:error:",
            "updater:shouldProceedWithUpdate:updateCheck:error:",
            "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
        ]
        let missing = gates.filter { !responds(to: NSSelectorFromString($0)) }
        if missing.isEmpty {
            NSLog("[Updater] on-air gates active (\(gates.count)/\(gates.count)) — updates cannot interrupt a broadcast")
        } else {
            NSLog("[Updater] ⚠️ ON-AIR GATE MISSING: \(missing.joined(separator: ", ")) — an update could interrupt a broadcast")
        }
    }

    /// On air = a camera is connected, OR an output is carrying the program.  Both matter: a
    /// mirrored screen feeding NDI with no Airlive camera on the network is just as live as a
    /// five-phone service, and either one dying mid-service is the same disaster.
    private var onAir: Bool { model?.isOnAir ?? false }

    private var refusal: NSError {
        NSError(domain: "studio.airlive.bridge", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Airlive Bridge is on air.",
            NSLocalizedRecoverySuggestionErrorKey:
                "Updates are paused while a camera is connected or an output is live, so an update can never interrupt a broadcast. Switch the outputs off and check again.",
        ])
    }

    // The selectors are PINNED with @objc rather than left to Swift's naming rules.  These are
    // optional protocol methods, so a name Swift derives differently from the one Sparkle asks
    // for is not an error — it is a gate that quietly is not there.  The check in init caught
    // exactly that on the third one below, which had compiled clean.

    // 1 — don't even look while on air, and come back to it the moment the show ends.
    //
    // The re-arm is not a nicety.  Sparkle stamps a REFUSED check as if it had happened and
    // schedules the next one a full interval later, so a service that happens to overlap the
    // daily check would otherwise push the update a whole day out — and the next launch would
    // not check either, because by its clock the day is not up.  Asking again as soon as the
    // outputs are off restores the intent: never during a show, promptly after one.
    @objc(updater:mayPerformUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard onAir else { return }
        recheckWhenAirClears(updater)
        throw refusal
    }

    // 2 — a check that began just before the show must not surface its result during it.
    @objc(updater:shouldProceedWithUpdate:updateCheck:error:)
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        guard onAir else { return }
        recheckWhenAirClears(updater)
        throw refusal
    }

    // 3 — last line: an update already accepted does not get to quit us mid-broadcast.
    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvoking installHandler: @escaping () -> Void) -> Bool {
        guard onAir else { return false }
        NSLog("[Updater] update ready, but the Bridge is on air — holding the relaunch until the outputs are off")
        waitForAirToClear {
            NSLog("[Updater] outputs are off — installing the held update now")
            installHandler()
        }
        return true
    }

    /// Polls slowly — it only runs while something is actually being held, and what it waits
    /// for is a human switching outputs off.  Five seconds is far below anyone's notice.
    private func waitForAirToClear(then finish: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { finish(); return }
            if self.onAir { self.waitForAirToClear(then: finish) }
            else { finish() }
        }
    }

    /// At most one pending re-check: a show can refuse several checks, and each one must not
    /// start its own waiter.
    private var recheckPending = false
    private func recheckWhenAirClears(_ updater: SPUUpdater) {
        guard !recheckPending else { return }
        recheckPending = true
        NSLog("[Updater] on air — update check deferred until the outputs are off")
        waitForAirToClear { [weak self] in
            self?.recheckPending = false
            NSLog("[Updater] outputs are off — checking for updates now")
            updater.checkForUpdatesInBackground()
        }
    }
}
