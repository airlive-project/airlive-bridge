// ContentView.swift — the three-zone window.
//
//   ┌──────────┬───────────────────────────┬──────────────┐
//   │ Channels │   Selected channel        │  Publish to  │
//   │  (rail)  │   preview + tally + delay │   (rail)     │
//   │          │   + camera control        │              │
//   └──────────┴───────────────────────────┴──────────────┘
//
// Left and right are fixed-width recessed rails; the center expands.  The model
// is injected from the app entry as an `@EnvironmentObject` so any zone can
// observe channels / selection without prop-drilling.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: BridgeModel

    var body: some View {
        HStack(spacing: 0) {
            // No explicit dividers between zones — the rails' darker `bgRail`
            // already separates them, and standalone Dividers were crossing
            // the preview's rounded corners (the "overlapping lines" artifact).
            ChannelsRail(model: model)
            CenterPane(model: model)
            OutputsRail(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgApp)
        .preferredColorScheme(.dark)
        // GLOBAL Solo ⇄ Multiview switch lives in the window TITLE BAR (centered)
        // — an app-wide either/or, and it reclaims the empty strip a separate row
        // wasted.  Native segmented control reads correctly as title-bar chrome.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $model.mode) {
                    ForEach(AppMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
        }
    }
}
