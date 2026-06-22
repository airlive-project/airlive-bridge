// ContentView.swift — placeholder shell.
//
// Real three-zone layout (Channels | Selected channel + control | Outputs) lands
// in phase 1 once the receiver core is ported from Studio. See docs/DESIGN.md.

import SwiftUI

struct ContentView: View {
    var body: some View {
        HStack(spacing: 0) {
            // Left — Channels (create receiver slots the iPhone connects to).
            VStack(alignment: .leading) {
                Text("Channels").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("+ Create channel").foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .frame(width: 180)
            .background(.black.opacity(0.15))

            Divider()

            // Center + right zones come with the port.
            VStack(spacing: 8) {
                Text("Airlive Bridge")
                Text("scaffold — receiver/control/outputs land in phase 1")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
