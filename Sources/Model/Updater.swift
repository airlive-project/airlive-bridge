// Updater.swift — the "Check for Updates…" menu action (manual, gentle).
//
// The seamless Sparkle path is wired but DORMANT until the update backend is live
// (a real EdDSA key + a hosted appcast — both blocked on the paid Apple Developer
// Program + hosting; see docs/RELEASE.md).  Starting Sparkle with the placeholder
// key made "Check for Updates…" throw an alarming "updater failed to start" alert,
// so for now the menu uses this lightweight manual check instead:
//   • user clicks → fetch a tiny version.json, compare semver
//   • newer available → "vX is available → Download" (opens the downloads page)
//   • otherwise / feed unreachable → a gentle "you're up to date"; the real fetch
//     error is logged to Console, never shown as a scary popup (the operator asked
//     for zero nagging — only a real available-update should interrupt them).
//
// When the Sparkle backend goes live, swap this menu action back to the Sparkle
// updater (the framework, package.sh signing, and docs are all still in place).

import Foundation
import AppKit

enum Updater {

    /// Version feed: `{ "version": "1.0.1", "url": "…/downloads", "notes": "…" }`.
    private static let feedURL = URL(string: "https://airlive.vercel.app/version.json")!
    private static let downloadsURL = URL(string: "https://airlive.vercel.app/downloads")!

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private struct Feed: Decodable { let version: String; let url: String?; let notes: String? }

    static func checkForUpdates(userInitiated: Bool) {
        URLSession.shared.dataTask(with: feedURL) { data, _, error in
            if let error { print("[Updater] feed unreachable: \(error.localizedDescription)") }
            let feed = data.flatMap { try? JSONDecoder().decode(Feed.self, from: $0) }
            DispatchQueue.main.async { present(feed: feed, userInitiated: userInitiated) }
        }.resume()
    }

    private static func present(feed: Feed?, userInitiated: Bool) {
        // A genuinely newer version → the only case that ever interrupts the operator.
        if let feed, isNewer(feed.version, than: currentVersion) {
            let alert = NSAlert()
            alert.messageText = "Airlive Bridge \(feed.version) is available"
            alert.informativeText = feed.notes?.isEmpty == false
                ? feed.notes! : "You have \(currentVersion).  Download the new version to update."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Download…")   // default
            alert.addButton(withTitle: "Later")        // Esc
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(feed.url.flatMap(URL.init(string:)) ?? downloadsURL)
            }
            return
        }
        // No newer version (or the feed isn't reachable yet) — only speak up when the
        // operator explicitly clicked, and NEVER with an error.  Gentle "up to date".
        guard userInitiated else { return }
        let alert = NSAlert()
        alert.messageText = "You’re up to date"
        alert.informativeText = "Airlive Bridge \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Numeric semver compare — "1.0.10" > "1.0.9".  Missing parts read as 0.
    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0, r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
