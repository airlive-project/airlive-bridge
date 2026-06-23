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
        VStack(spacing: 0) {
            modeBar
            HStack(spacing: 0) {
                // No explicit dividers between zones — the rails' darker `bgRail`
                // already separates them, and standalone Dividers were crossing
                // the preview's rounded corners (the "overlapping lines" artifact).
                ChannelsRail(model: model)
                CenterPane(model: model)
                OutputsRail(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgApp)
        .preferredColorScheme(.dark)
    }

    /// GLOBAL Solo ⇄ Multiview switch in the top strip — OUR background colour
    /// (not native toolbar grey), a compact centered control (full-width read too
    /// heavy).  A hairline under it ties the strip to the rest of the chrome.
    private var modeBar: some View {
        SegmentedBar(selection: $model.mode,
                     options: AppMode.allCases,
                     label: { $0.label })
            .frame(width: 320)
            .frame(maxWidth: .infinity)   // center the compact control
            .padding(.vertical, Spacing.sm)
            .background(Theme.bgApp)
            .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.stroke),
                     alignment: .bottom)
    }
}
