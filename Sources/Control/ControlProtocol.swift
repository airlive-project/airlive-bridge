// ControlProtocol.swift - the JSON a local controller and the Bridge exchange.
//
// The first controller is the Stream Deck plugin; the protocol is written for "a client on this
// Mac" rather than for that one plugin, so a second surface never needs a second channel. The
// Bridge is the switcher, the controller is only a remote for it: every command lands on the SAME
// model call a key press or a click already makes, and there is no switching logic on this side.
//
// Transport: WebSocket, loopback only, one JSON object per text message (see ControlServer).
//
//   Bridge -> controller
//     {"type":"hello","app":"Airlive Bridge","version":"1.3.1","proto":1,"caps":["preview",...]}
//     {"type":"state","channels":[{"slot":1,"name":"Cam 1","connected":true,"picture":true}],
//      "program":1,"preview":2}
//     {"type":"auto","on":true,"available":true,"remaining":12}
//     {"type":"camera","slot":2,"name":"Cam 2","controllable":true,
//      "lenses":["0.5x","1x","5x"],"lens":"1x",
//      "params":{"iso":{"text":"400","auto":true,"position":0.48}, ...}}
//
//   controller -> Bridge
//     {"cmd":"preview","slot":2}   stage multiview tile 2 in Preview (plain digit 2)
//     {"cmd":"program","slot":2}   cut tile 2 straight to Program (Cmd+2)
//     {"cmd":"cut"}                Preview to Program (Space)
//     {"cmd":"auto"}               toggle auto cut (the AUTO button)
//     {"cmd":"lens","lens":1}      the Preview camera's first lens (Shift+1)
//     {"cmd":"adjust","param":"iso","steps":-2}   two ladder stops down on the Preview camera
//     {"cmd":"reset","param":"iso"}              that setting back to auto (zoom 1x, EV 0)
//
// Camera params: iso, shutter, temperature, tint, focus, zoom, ev (DialParam). `camera` describes
// the Preview camera, the one the Bridge's control panel drives; `text` is the panel's own readout.
//
// Slots and lens positions are 1-based, the numbers the operator sees on the keys. A controller
// checks `caps` before sending a verb, never `proto`: that is the same capability rule the camera
// protocol follows, so a newer plugin degrades cleanly against an older Bridge.

import Foundation

enum ControlProtocol {
    /// Fixed so the plugin can find the Bridge without discovery. Next to the relay's 47788; a
    /// loopback-only bind never reaches the firewall or the LAN.
    static let port: UInt16 = 47790
    static let generation = 1
    static let caps = ControlCommand.Verb.allCases.map(\.rawValue)
}

// MARK: - Controller -> Bridge

struct ControlCommand: Decodable {
    enum Verb: String, Decodable, CaseIterable { case preview, program, cut, auto, lens, adjust, reset }
    let cmd: Verb
    /// 1-based multiview position, for `preview` / `program`.
    let slot: Int?
    /// 1-based position in the Preview camera's lens list, for `lens`.
    let lens: Int?
    /// The camera setting, for `adjust` / `reset`.
    let param: DialParam?
    /// Ladder stops to move, signed, for `adjust`.
    let steps: Int?
}

// MARK: - Bridge -> controller

struct ControlHello: Encodable {
    let type = "hello"
    let app = "Airlive Bridge"
    let version: String
    let proto = ControlProtocol.generation
    let caps = ControlProtocol.caps
}

/// Everything a camera key needs to draw itself. Sent whole on every change: a desk has at most
/// 16 tiles, so a full snapshot is a few hundred bytes and the controller never has to merge.
struct ControlState: Encodable, Equatable {
    let type = "state"
    let channels: [ChannelState]
    /// Slots on the buses, nil when the bus is empty (right after launch there is no Program).
    let program: Int?
    let preview: Int?

    struct ChannelState: Encodable, Equatable {
        let slot: Int
        let name: String
        /// Any transport is up, video or control.
        let connected: Bool
        /// Video is arriving: the model's own "has a picture" test (see AutoSwitcher).
        let picture: Bool
    }

    init(model: BridgeModel) {
        let list = model.multiviewChannels
        func slot(of id: UUID?) -> Int? {
            guard let id, let index = list.firstIndex(where: { $0.id == id }) else { return nil }
            return index + 1
        }
        channels = list.enumerated().map { index, channel in
            ChannelState(slot: index + 1,
                         name: channel.name,
                         connected: channel.anyConnected,
                         picture: channel.isConnected && channel.videoActive)
        }
        program = slot(of: model.programID)
        preview = slot(of: model.previewID)
    }
}

/// The AUTO key. Separate from `state` because the countdown ticks once a second while auto runs,
/// and re-sending every camera's state with it would redraw every key on the deck each second.
struct ControlAuto: Encodable, Equatable {
    let type = "auto"
    let on: Bool
    /// Two or more cameras have a picture, so auto can run (the button's enabled state).
    let available: Bool
    /// Whole seconds to the next cut; 0 while off.
    let remaining: Int

    init(_ auto: AutoSwitcher) {
        on = auto.isOn
        available = auto.canRun
        remaining = auto.remaining
    }
}

/// The Preview camera's settings, for the dials. Its own message because it changes on its own
/// schedule: a camera in auto reports its exposure once a second, and that must not redraw the keys.
struct ControlCamera: Encodable, Equatable {
    let type = "camera"
    /// The Preview camera's multiview slot; nil when nothing is staged.
    let slot: Int?
    let name: String?
    /// A dial command would reach the phone and be obeyed (control link up, remote control allowed
    /// on the phone, first state report in). False for a camera without a back-channel.
    let controllable: Bool
    /// The camera's lenses, widest first (the order `lens` positions count in); empty while not
    /// controllable.
    let lenses: [String]
    /// The highlighted lens: the operator's pick while it is in flight, else what the camera reports
    /// - the same `selectedLens` the Bridge's lens tiles light up.
    let lens: String?
    /// Keyed by `DialParam` raw value; empty while not controllable.
    let params: [String: Param]

    struct Param: Encodable, Equatable {
        let text: String
        let auto: Bool
        /// Place on the value ladder, 0…1.
        let position: Double
    }

    init(model: BridgeModel, dials: CameraDials) {
        let channel = model.previewChannel()
        slot = channel.flatMap { c in model.multiviewChannels.firstIndex { $0.id == c.id } }.map { $0 + 1 }
        name = channel?.name
        guard let target = dials.target, dials.isControllable(target), let snapshot = target.remote else {
            controllable = false
            lenses = []
            lens = nil
            params = [:]
            return
        }
        controllable = true
        lenses = snapshot.availableLenses
        lens = target.selectedLens
        var out: [String: Param] = [:]
        for param in DialParam.allCases {
            let value = dials.value(param, of: target, snapshot)   // before isAuto: it settles pending
            out[param.rawValue] = Param(text: CameraDials.display(param, value),
                                        auto: dials.isAuto(param, of: target, snapshot),
                                        position: dials.position(param, value: value, snapshot))
        }
        params = out
    }
}
