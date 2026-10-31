// LocalNetworkAccess.swift - whether macOS lets the Bridge onto the local network.
//
// Since macOS 15 an app needs the operator's permission (Privacy & Security > Local Network) to
// advertise itself over Bonjour and talk to devices on the LAN. Without it the phones never find
// the Bridge - and nothing else on screen says why: the channels simply stay empty. macOS asks
// once, at the first launch, before the operator has done anything; "Don't Allow" there is easy.
//
// Apple's documented signal for a refusal is the DNS-SD error kDNSServiceErr_PolicyDenied on the
// Bonjour side of a listener or browser (TN3179, "Understanding local network privacy"). Every
// channel's listener reports here; the Mac connection row at the foot of the Channels rail shows it in
// red, with a button to the setting.

import Foundation
import Network
import dnssd

final class LocalNetworkAccess: ObservableObject {
    static let shared = LocalNetworkAccess()

    /// True once a listener was refused by local network privacy; false again when one comes up.
    @Published private(set) var blocked = false

    /// From any queue: a channel listener's state, as NWListener reported it.
    func note(_ state: NWListener.State) {
        let refused: Bool
        switch state {
        case .waiting(let error), .failed(let error): refused = Self.isPolicyDenied(error)
        case .ready: refused = false
        default: return
        }
        DispatchQueue.main.async {
            guard self.blocked != refused else { return }
            self.blocked = refused
            print(refused ? "[Network] ⚠️ macOS refused the Bridge local network access - phones cannot find it"
                          : "[Network] local network access granted")
        }
    }

    static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) }
        return false
    }

    /// The Local Network pane of Privacy & Security.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
}
