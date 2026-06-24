// AirPlayBonjour.swift — advertise the UxPlay RAOP/AirPlay services over Foundation's
// NSNetService instead of the vendored dns_sd, which returns -65555 (NoAuth) on macOS
// 26. NSNetService / Network.framework share the app's already-granted Local Network
// authorization (the same grant that makes _airlive._tcp work), so publishing from the
// app's own signed binary is attributed correctly where raw DNSServiceRegister was
// silently denied.
//
// CRITICAL: this advertises UxPlay's EXISTING httpd port — it does NOT bind a socket.
// The iPhone resolves host+port from these records and connects to UxPlay's real
// server. (NWListener can't advertise a foreign port; NSNetService can.)

import Foundation

final class AirPlayBonjour: NSObject, NetServiceDelegate {
    private var raop: NetService?
    private var airplay: NetService?

    /// `raopInstance` = "HWADDR@name"; `airplayInstance` = bare device name.
    /// `port` = UxPlay's httpd port (both services share it).
    func publish(port: Int,
                 raopInstance: String, raopTXT: [String: Data],
                 airplayInstance: String, airplayTXT: [String: Data]) {
        stop()

        let r = NetService(domain: "local.", type: "_raop._tcp.",
                           name: raopInstance, port: Int32(port))
        r.delegate = self
        r.setTXTRecord(NetService.data(fromTXTRecord: raopTXT))
        r.publish()
        raop = r

        let a = NetService(domain: "local.", type: "_airplay._tcp.",
                           name: airplayInstance, port: Int32(port))
        a.delegate = self
        a.setTXTRecord(NetService.data(fromTXTRecord: airplayTXT))
        a.publish()
        airplay = a
    }

    func stop() {
        raop?.stop(); raop = nil
        airplay?.stop(); airplay = nil
    }

    // Loud logging — no silent failure (CLAUDE.md rule).
    func netServiceDidPublish(_ s: NetService) {
        print("[AirPlayBonjour] ✅ published \(s.type)'\(s.name)' on port \(s.port)")
    }
    func netService(_ s: NetService, didNotPublish err: [String: NSNumber]) {
        print("""
        [AirPlayBonjour] ❌ FAILED to publish \(s.type)'\(s.name)': \(err)
        — if this is a NoAuth/TCC denial, run once in Terminal then relaunch:
          tccutil reset NSLocalNetwork studio.airlive.bridge.AirliveBridge
        """)
    }
}
