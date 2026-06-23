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
            // No explicit dividers between zones — the rails carry faint edge
            // hairlines (see ChannelsRail / OutputsRail).
            ChannelsRail(model: model)
            CenterPane(model: model)
            OutputsRail(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgApp)
        .preferredColorScheme(.dark)
        // GLOBAL Solo ⇄ Multiview switch lives IN the title bar — our themed
        // control, on our dark background, so the title bar is the working strip
        // (no separate empty row, no grey chrome).
        .toolbar {
            ToolbarItem(placement: .principal) {
                SegmentedBar(selection: $model.mode,
                             options: AppMode.allCases,
                             label: { $0.label })
                    .frame(width: 320)
            }
        }
        .toolbarBackground(Theme.bgApp, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .navigationTitle("")
    }
}
