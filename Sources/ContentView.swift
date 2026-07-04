// ContentView.swift — the three-zone window.
//
//   ┌──────────┬───────────────────────────┬──────────────┐
//   │ Channels │   Multiview (PVW/PGM +    │  Publish to  │
//   │  (rail)  │   CUT + camera control)   │   (rail)     │
//   └──────────┴───────────────────────────┴──────────────┘
//
// Left and right are fixed-width recessed rails; the center expands.  The model
// is injected from the app entry as an `@EnvironmentObject` so any zone can
// observe channels / selection without prop-drilling.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: BridgeModel
    @EnvironmentObject var shortcuts: ShortcutCenter
    /// Each side rail collapses to a minimal strip INDEPENDENTLY — the chevron lives on the
    /// rail itself (header when open, strip top when collapsed), so the operator hides exactly
    /// the column they want for more multiview room.
    @State private var leftCollapsed = false
    @State private var rightCollapsed = false

    var body: some View {
        HStack(spacing: 0) {
            // No explicit dividers between zones — the rails carry faint edge
            // hairlines (see ChannelsRail / OutputsRail).
            ChannelsRail(model: model, collapsed: leftCollapsed,
                         onToggleCollapse: { withAnimation(.easeInOut(duration: 0.2)) { leftCollapsed.toggle() } })
            CenterPane(model: model)
            OutputsRail(model: model, collapsed: rightCollapsed,
                        onToggleCollapse: { withAnimation(.easeInOut(duration: 0.2)) { rightCollapsed.toggle() } })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgApp)
        // Hairline right under the title bar so it reads as separated from the
        // columns (the mode-bar divider moved into the title bar with the switch).
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.stroke),
                 alignment: .top)
        .preferredColorScheme(.dark)
        // No toolbar items: the Solo ⇄ Multiview switch was REMOVED for launch
        // (2026-07-03) — Multiview is the only mode; Solo needs a real per-channel
        // routing design (aux buses) and ships later.  The dark toolbar background
        // stays so the title bar reads as part of the app, not grey chrome.
        .toolbarBackground(Theme.bgApp, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        // OBS-style working title: "Airlive Bridge 1.0.0 - Profile: EAGLES" (no
        // scenes segment — Bridge has no scene collections).
        .navigationTitle("Airlive Bridge \(Self.appVersion) - Profile: \(model.profileName)")
    }

    /// Marketing version from the bundle (single source: MARKETING_VERSION in project.yml).
    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
}
