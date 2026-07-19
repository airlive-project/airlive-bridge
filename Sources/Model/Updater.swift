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
