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
    @EnvironmentObject var shortcuts: ShortcutCenter
    @State private var showShortcuts = false

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
        // Hairline right under the title bar so it reads as separated from the
        // columns (the mode-bar divider moved into the title bar with the switch).
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.stroke),
                 alignment: .top)
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
            ToolbarItem(placement: .automatic) {
                Button { showShortcuts.toggle() } label: {
                    Image(systemName: "keyboard")
                }
                .help("Shortcuts")
                .popover(isPresented: $showShortcuts, arrowEdge: .bottom) {
                    ShortcutSettings(shortcuts: shortcuts)
                }
            }
        }
        .toolbarBackground(Theme.bgApp, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .navigationTitle("")
    }
}
