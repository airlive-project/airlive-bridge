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
            // GLOBAL mode bar — Solo vs Multiview is an app-wide either/or
            // (mutually-exclusive output paths), so it sits across the top, not
            // tucked inside one column.
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

    /// Centered Solo ⇄ Multiview switch.  Left gutter stays clear of the window's
    /// traffic-light controls.
    private var modeBar: some View {
        SegmentedBar(selection: $model.mode,
                     options: AppMode.allCases,
                     label: { $0.label })
            .frame(width: 240)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(Theme.bgRail)
            .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.stroke),
                     alignment: .bottom)
    }
}
