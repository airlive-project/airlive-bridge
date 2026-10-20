// TitlebarNetworkStatus.swift - how THIS Mac is on the network, at the right of the main window's
// title bar: "Mac: Ethernet" (quiet), "Mac: Wi-Fi - Ethernet recommended" (yellow) or
// "Mac: No network" (red).
//
// Only the Mac's own link, never the cameras' (operator, 2026-10-16). On Wi-Fi every camera frame
// crosses the air twice (phone to router, router to Mac), which is where the bursts and stutters
// in the field logs come from; on a cable it crosses once.
//
// The link comes from Apple's NWPathMonitor, which names the interface macOS actually routes
// through: with both a cable and Wi-Fi up, macOS prefers the cable, and so does this badge. It is
// decided by interface TYPE, never by name - en0 is Wi-Fi on a MacBook and Ethernet on a Mac mini.
//
// The title bar only lends the slot (NSTitlebarAccessoryViewController, AppKit's documented way to
// put a view in a window's title bar); what sits in it is our own view in the Bridge's style.

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

/// The badge itself: icon and word in the state's colour, nothing around them.
struct NetworkBadge: View {
    @ObservedObject var status: NetworkStatus
    @ObservedObject private var localNetwork = LocalNetworkAccess.shared

    var body: some View {
        if localNetwork.blocked {
            // Outranks the link: on Wi-Fi or Ethernet alike, no phone can find the Bridge. A
            // click opens the setting, since this is the one thing here the operator must change.
            Button { NSWorkspace.shared.open(LocalNetworkAccess.settingsURL) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Local Network access off - click to allow")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Theme.accentRed)
            }
            .buttonStyle(.plain)
            .fixedSize()
        } else if let look {
            HStack(spacing: 5) {
                if let icon = look.icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(look.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(look.color)
            // Plain text, no box (operator, 2026-10-16): the colour says it all.
            .fixedSize()
        }
    }

    private struct Look {
        let icon: String?
        let title: String
        let color: Color
    }

    /// "Mac:" first, so nobody reads it as the cameras' link. Only Wi-Fi carries a sign and says
    /// what to do, because a hover tip cannot show in a title bar; the all-good state is quiet
    /// (operator, 2026-10-19).
    private var look: Look? {
        switch status.link {
        case .ethernet: return Look(icon: nil, title: "Mac: Ethernet", color: Theme.textPrimary.opacity(0.5))
        case .wifi:     return Look(icon: "exclamationmark.triangle.fill",
                                    title: "Mac: Wi-Fi - Ethernet recommended", color: Theme.accentYellow)
        case .none:     return Look(icon: nil, title: "Mac: No network", color: Theme.accentRed)
        case .other:    return nil
        }
    }
}

/// Puts the badge in the title bar of the window it is attached to, once.
/// Attach as `.background(TitlebarNetworkStatus(status: ...))` on the main window's root view.
struct TitlebarNetworkStatus: NSViewRepresentable {
    let status: NetworkStatus

    func makeNSView(context: Context) -> Anchor { Anchor(status: status) }
    func updateNSView(_ nsView: Anchor, context: Context) {}

    /// Installs the accessory when it lands in a window - not from a SwiftUI update pass, so the
    /// title bar is never changed in the middle of a layout.
    final class Anchor: NSView {
        private let status: NetworkStatus
        private var installed = false
        /// Fits the longest state ("Local Network access off - click to allow" and its sign) plus
        /// the trailing margin, at 11 pt.
        private static let slotWidth: CGFloat = 300

        init(status: NetworkStatus) {
            self.status = status
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !installed, let window else { return }
            installed = true
            // A fixed slot as wide as the widest state (see slotWidth), the badge pinned to its right
            // edge: the title bar lays the accessory out once, so the slot must not depend on which
            // state happened to be showing at launch.
            let host = NSHostingView(rootView: NetworkBadge(status: status)
                // The rails' own side margin, so the word lines up with the column edges below.
                .padding(.trailing, Spacing.lg)
                .frame(width: Self.slotWidth, alignment: .trailing)
                .frame(maxHeight: .infinity))
            host.frame.size = NSSize(width: Self.slotWidth, height: host.fittingSize.height)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = host
            accessory.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(accessory)
        }
    }
}
