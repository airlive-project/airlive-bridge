// AirliveBridgeApp.swift — app entry.
//
// Airlive Bridge receives the Airlive Camera (iPhone) stream and re-publishes it
// as NDI / SRT / RTSP, with remote camera control built in (downstream outputs
// are one-way, so control lives here). Mac MVP; see README.md / ROADMAP.md.
//
// Owns the single `BridgeModel` as a `@StateObject` and injects it into the view
// tree as an environment object — the three zones (Channels | Selected channel +
// control | Outputs) all observe it from there.

import SwiftUI

@main
struct AirliveBridgeApp: App {
    @StateObject private var model = BridgeModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
