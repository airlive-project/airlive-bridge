// ChannelKind.swift — what KIND of source a channel receives.
//
// Two ways an iPhone can feed a Bridge channel:
//   • .airlive — the Airlive Camera app over our ARLV protocol (cool, Apple Log,
//     remote-controllable, clean feed — the product's core path).
//   • .airplay — ANY iPhone via AirPlay Screen Mirroring (the Bridge advertises
//     each channel as a named Apple TV; the operator picks "Cam N" in Screen
//     Mirroring). No app needed; heavier on the phone, no remote control — the
//     "bring any device" path.
//
// AirPlay is NOT implemented yet (its receiver is a GPLv3 UxPlay C-stack that has
// to be vendored + built — see ROADMAP). Until then it shows as "soon" in the add
// menu, mirroring how SRT/RTSP outputs were staged — never a dead, clickable stub.

import Foundation

enum ChannelKind: String, CaseIterable, Identifiable {
    case airlive
    case airplay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .airlive: return "Airlive Camera"
        case .airplay: return "Screen Mirroring"
        }
    }

    /// One-line description for the add menu.
    var subtitle: String {
        switch self {
        case .airlive: return "iPhone running the Airlive app"
        case .airplay: return "Any iPhone via AirPlay"
        }
    }

    var symbolName: String {
        switch self {
        case .airlive: return "camera"
        case .airplay: return "rectangle.on.rectangle"
        }
    }

    /// AirPlay's receiver backend (UxPlay) isn't wired yet — gate it off so the menu
    /// shows the option but can't create a non-functional channel.
    var isImplemented: Bool { self == .airlive }
}
