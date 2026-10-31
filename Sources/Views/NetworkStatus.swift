// NetworkStatus.swift - how THIS Mac is on the network, as the "Mac connection" row at the foot of
// the Channels rail: Ethernet (quiet), Wi-Fi (yellow, with the reason behind an ⓘ), Offline (red), or
// Local Network access blocked (red, with the button that opens the setting).
//
// It lived in the title bar first, which a full-screen window hides - the one moment an operator
// is most likely to be on air - so it moved into the window itself (operator, 2026-10-25).
//
// Only the Mac's own link, never the cameras' (operator, 2026-10-16). On Wi-Fi every camera frame
// crosses the air twice (phone to router, router to Mac), which is where the bursts and stutters
// in the field logs come from; on a cable it crosses once.
//
// The link comes from Apple's NWPathMonitor, which names the interface macOS actually routes
// through: with both a cable and Wi-Fi up, macOS prefers the cable, and so does this row. It is
// decided by interface TYPE, never by name - en0 is Wi-Fi on a MacBook and Ethernet on a Mac mini.

import SwiftUI
import AppKit
import Network

/// The Mac's current link, published on main and only when it changes.
final class NetworkStatus: ObservableObject {
    enum Link: Equatable {
        case ethernet, wifi, none
        /// Up, but over something that is neither (Thunderbolt bridge, USB tether): nothing to say.
        case other
    }

    @Published private(set) var link: Link = .other

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let link = Self.link(of: path)
            DispatchQueue.main.async {
                guard let self, self.link != link else { return }
                self.link = link
                print("[Network] this Mac is on \(link)")
            }
        }
        monitor.start(queue: DispatchQueue(label: "studio.airlive.bridge.network-status", qos: .utility))
    }

    deinit { monitor.cancel() }

    private static func link(of path: NWPath) -> Link {
        guard path.status == .satisfied else { return .none }
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        if path.usesInterfaceType(.wifi) { return .wifi }
        return .other
    }
}

/// What the row (and the collapsed rail's icon) says about the Mac's link right now. Blocked
/// outranks the link: on a cable or Wi-Fi alike, no phone can find the Bridge.
private struct NetworkLook {
    let icon: String
    let text: String
    let color: Color

    static let wifiReason = "Ethernet is recommended for a stable stream: on Wi-Fi every camera frame crosses the air twice, phone to router and router to Mac."

    static func of(link: NetworkStatus.Link, blocked: Bool) -> NetworkLook? {
        if blocked { return NetworkLook(icon: "nosign", text: "Access off", color: Theme.accentRed) }
        switch link {
        case .ethernet: return NetworkLook(icon: "cable.connector", text: "Ethernet", color: Theme.textSecondary)
        case .wifi:     return NetworkLook(icon: "wifi", text: "Wi-Fi", color: Theme.accentYellow)
        case .none:     return NetworkLook(icon: "wifi.slash", text: "Offline", color: Theme.accentRed)
        case .other:    return nil
        }
    }
}

/// The "Mac connection" row - named for the MAC's link to the router, so nobody reads it as the
/// cameras' (operator, 2026-10-25). Same height, weight and dividers as the Latency buffer and
/// password rows below it, label left and state right. "Access off", not "Local access off": with
/// the label and the Allow button the longer one overflows the 280 pt rail. Nothing is shown for a link that is neither cable nor
/// Wi-Fi - there is nothing to advise.
struct NetworkFooter: View {
    @ObservedObject var status: NetworkStatus
    @ObservedObject private var localNetwork = LocalNetworkAccess.shared

    var body: some View {
        if let look = NetworkLook.of(link: status.link, blocked: localNetwork.blocked) {
            HStack(spacing: Spacing.sm) {
                Text("Mac connection")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: Spacing.sm)
                HStack(spacing: 5) {
                    Image(systemName: look.icon)
                        .font(.system(size: 11, weight: .medium))
                    Text(look.text)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(look.color)
                if localNetwork.blocked {
                    Button { NSWorkspace.shared.open(LocalNetworkAccess.settingsURL) } label: {
                        Text("Allow")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, Spacing.sm)
                            .frame(height: 24)
                    }
                    .bridgeButton()
                } else if status.link == .wifi {
                    InfoDot(text: NetworkLook.wifiReason)
                }
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: 44)
            .background(Theme.bgPanel)
            .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.stroke), alignment: .top)
        }
    }
}

/// The same state as one icon, for the collapsed Channels strip. Blocked is a button there too,
/// since allowing access is the one thing here the operator must do.
struct NetworkIcon: View {
    @ObservedObject var status: NetworkStatus
    @ObservedObject private var localNetwork = LocalNetworkAccess.shared

    var body: some View {
        if let look = NetworkLook.of(link: status.link, blocked: localNetwork.blocked) {
            Button {
                if localNetwork.blocked { NSWorkspace.shared.open(LocalNetworkAccess.settingsURL) }
            } label: {
                Image(systemName: look.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(look.color)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help(look))
            // The cell lives INSIDE the `if`: an other-link Mac (Thunderbolt bridge, tether) has
            // nothing to show, and an empty cell left a stray hairline on the strip.
            .railFooterCell()
        }
    }

    private func help(_ look: NetworkLook) -> String {
        if localNetwork.blocked { return "Local Network access is off - click to allow" }
        if status.link == .wifi { return "Mac connection: Wi-Fi - " + NetworkLook.wifiReason }
        return "Mac connection: " + look.text
    }
}
