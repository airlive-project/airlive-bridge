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
            ChannelsRail(model: model)

            Divider().background(Theme.strokeDivider)

            CenterPane(model: model)

            Divider().background(Theme.strokeDivider)

            OutputsRail(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgApp)
        .preferredColorScheme(.dark)
    }
}
