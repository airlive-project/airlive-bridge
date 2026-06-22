// AirliveBridgeApp.swift — app entry.
//
// Airlive Bridge receives the Airlive Camera (iPhone) stream and re-publishes it
// as NDI / SRT / RTSP, with remote camera control built in (downstream outputs
// are one-way, so control lives here). Mac MVP; see README.md / ROADMAP.md.

import SwiftUI

@main
struct AirliveBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
