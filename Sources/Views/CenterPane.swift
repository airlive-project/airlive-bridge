// CenterPane.swift — CENTER zone: the multiview.
//
// Multiview is the ONLY center view since Solo mode was removed for launch
// (2026-07-03): Solo's "each channel routed somewhere on its own" needs a real
// per-output source design (aux buses) and ships later.  The old per-channel
// detail view (preview + tally row + control stack) lived here — git has it if
// Solo returns in a new shape.
//
// MultiviewGrid owns everything the operator works with: PVW/PGM panes, the CUT
// button, per-tile staging, and camera control for the staged channel.

import SwiftUI

struct CenterPane: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        MultiviewGrid(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bgApp)
    }
}
