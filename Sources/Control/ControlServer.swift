// ControlServer.swift - lets a controller on this Mac (the Stream Deck plugin) drive the switcher.
//
// A WebSocket listener bound to 127.0.0.1: nothing on the LAN can reach it, and a loopback bind
// raises no firewall prompt. Commands in, state out, both event-driven - the server sends when a
// bus, a name or a connection changes, never per frame. The wire format is in ControlProtocol.
//
// No work for nobody: the model is observed only while at least one controller is connected. An
// idle Bridge pays for a listening socket and nothing else.
//
// Everything runs on the main queue - the listener, the connections, the model it drives. The
// messages are tiny and rare, and the model is main-thread only, so a queue of its own would only
// add hops.

import Foundation
import Network
import Combine

final class ControlServer: ObservableObject {

    /// The Settings switch. On by default: a plugin that silently does nothing until the operator
    /// finds a switch is a support ticket, and the socket only accepts this Mac.
    @Published var enabled: Bool { didSet { persist(); apply() } }

    /// Why the listener is not running although `enabled` is on (the port is taken, most likely by
    /// a second Bridge). Shown under the switch; nil while healthy.
    @Published private(set) var failure: String?

    private let model: BridgeModel
    private let dials: CameraDials
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]

    private var modelSubs = Set<AnyCancellable>()
    private var channelSubs = Set<AnyCancellable>()
    private var flushScheduled = false
    private var lastState: ControlState?
    private var lastAuto: ControlAuto?
    private var lastCamera: ControlCamera?
    private let encoder = JSONEncoder()

    private static let enabledKey = "control.enabled"
    /// Commands are a few dozen bytes. The cap keeps a confused client from making the Bridge
    /// buffer megabytes before the JSON decode rejects them.
    private static let maxMessageBytes = 4096

    init(model: BridgeModel) {
        self.model = model
        dials = CameraDials(model: model)
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        dials.onChange = { [weak self] in self?.scheduleFlush() }
        apply()
    }

    private func persist() { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }

    /// Bring the listener up or down to match `enabled`. Publishes nothing synchronously: it runs
    /// inside the Toggle's view update (see ShortcutCenter.refreshPermission for what that breaks).
    private func apply() {
        closeAll()
        guard enabled else {
            DispatchQueue.main.async { [weak self] in self?.failure = nil }
            return
        }
        startListening()
    }

    // MARK: - Listener

    private func startListening() {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Self.maxMessageBytes
        // Refuse web pages. Loopback keeps the LAN out but not the operator's own browser: any site
        // they have open may open ws://127.0.0.1 from JavaScript, and the protocol is public. A
        // browser ALWAYS sends Origin on a WebSocket handshake; the plugin's Node client never does
        // (both checked 2026-10-03). So a handshake carrying Origin is a page, and it is turned away.
        ws.setClientRequestHandler(.main) { _, headers in
            let origin = headers.first { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }
            guard let origin else { return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil) }
            print("[Control] ⚠️ refused a web page (Origin: \(origin.value))")
            return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                 port: NWEndpoint.Port(rawValue: ControlProtocol.port)!)
        params.allowLocalEndpointReuse = true

        let l: NWListener
        do {
            l = try NWListener(using: params)
        } catch {
            report("❌ listener init failed: \(error)", shown: "Could not start: \(error.localizedDescription)")
            return
        }
        l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, l === self.listener else { return }
            switch state {
            case .ready:
                print("[Control] ✅ listening on 127.0.0.1:\(ControlProtocol.port)")
                self.failure = nil
            case .failed(let error):
                // Loud, and visible in Settings: a Stream Deck that stops answering with no word
                // anywhere is exactly the phantom this app refuses to ship.
                self.report("❌ listener failed on port \(ControlProtocol.port): \(error)",
                            shown: "Port \(ControlProtocol.port) is in use by another app")
                l.cancel()
                self.listener = nil
            default:
                break
            }
        }
        listener = l
        l.start(queue: .main)
    }

    /// Log the detail, show the operator the short version.
    private func report(_ log: String, shown: String) {
        print("[Control] \(log)")
        DispatchQueue.main.async { [weak self] in self?.failure = shown }
    }

    private func closeAll() {
        listener?.cancel()
        listener = nil
        clients.values.forEach { $0.cancel() }
        clients.removeAll()
        stopObserving()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        clients[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                print("[Control] controller connected (\(self.clients.count) total)")
                self.greet(connection)
            case .failed(let error):
                print("[Control] controller dropped: \(error)")
                connection.cancel()
            case .cancelled:
                self.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func forget(_ connection: NWConnection) {
        guard clients.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        print("[Control] controller disconnected (\(clients.count) left)")
        if clients.isEmpty { stopObserving() }
    }

    /// A new controller gets the whole picture at once, whatever the others were last sent.
    private func greet(_ connection: NWConnection) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let state = ControlState(model: model)
        let auto = ControlAuto(model.autoSwitcher)
        let camera = ControlCamera(model: model, dials: dials)
        send(ControlHello(version: version), to: [connection])
        send(state, to: [connection])
        send(auto, to: [connection])
        send(camera, to: [connection])
        // The first controller starts the observation; record what it was just sent so the
        // subscription's opening flush does not send it all again.
        if clients.count == 1 {
            lastState = state
            lastAuto = auto
            lastCamera = camera
        }
        startObserving()
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard let self, let connection else { return }
            if let error {
                print("[Control] receive failed: \(error)")
                connection.cancel()
                return
            }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if meta?.opcode == .close {
                connection.cancel()
                return
            }
            if let data, !data.isEmpty { self.handle(data) }
            self.receive(on: connection)
        }
    }

    private func send<M: Encodable>(_ message: M, to connections: [NWConnection]) {
        guard !connections.isEmpty else { return }
        let data: Data
        do {
            data = try encoder.encode(message)
        } catch {
            print("[Control] ❌ encode failed: \(error)")
            return
        }
        let context = NWConnection.ContentContext(
            identifier: "control", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        for connection in connections {
            connection.send(content: data, contentContext: context, isComplete: true,
                            completion: .contentProcessed { error in
                if let error { print("[Control] send failed: \(error)") }
            })
        }
    }

    // MARK: - Commands

    /// Every verb lands on the call a key press already makes, so a Stream Deck key and a keyboard
    /// key can never disagree about what "cut" means - including auto stepping aside for a hand cut.
    private func handle(_ data: Data) {
        let command: ControlCommand
        do {
            command = try JSONDecoder().decode(ControlCommand.self, from: data)
        } catch {
            print("[Control] ⚠️ ignored command \(String(decoding: data.prefix(200), as: UTF8.self)): \(error)")
            return
        }
        switch command.cmd {
        // Positions are 1-based and checked here, not just range-checked downstream: `Int.min - 1`
        // traps before any range check gets to look at it.
        case .preview:
            guard let slot = command.slot, slot >= 1 else { return missing("slot", in: command) }
            model.programSelect(slot - 1)
        case .program:
            guard let slot = command.slot, slot >= 1 else { return missing("slot", in: command) }
            model.cutDirect(slot - 1)
        case .cut:
            model.cutAction()
        case .auto:
            model.autoSwitcher.toggle()
        case .lens:
            guard let lens = command.lens, lens >= 1 else { return missing("lens", in: command) }
            model.lensSelect(lens - 1)
        case .adjust:
            guard let param = command.param else { return missing("param", in: command) }
            guard let steps = command.steps else { return missing("steps", in: command) }
            if !dials.adjust(param, steps: steps) { refusedNoCamera(command) }
        case .reset:
            guard let param = command.param else { return missing("param", in: command) }
            if !dials.reset(param) { refusedNoCamera(command) }
        }
    }

    /// Not an error - the operator turned a dial with no controllable camera in Preview - but it
    /// should be findable when someone asks why a dial did nothing.
    private func refusedNoCamera(_ command: ControlCommand) {
        print("[Control] \(command.cmd.rawValue) \(command.param?.rawValue ?? ""): no controllable camera in Preview")
    }

    private func missing(_ field: String, in command: ControlCommand) {
        print("[Control] ⚠️ ignored \(command.cmd.rawValue): no \(field)")
    }

    // MARK: - State out

    private func startObserving() {
        guard modelSubs.isEmpty else { return }
        model.$channels
            .sink { [weak self] channels in self?.observe(channels) }
            .store(in: &modelSubs)
        let triggers: [AnyPublisher<Void, Never>] = [
            model.$programID.map { _ in () }.eraseToAnyPublisher(),
            model.$previewID.map { _ in () }.eraseToAnyPublisher(),
            model.autoSwitcher.$isOn.map { _ in () }.eraseToAnyPublisher(),
            model.autoSwitcher.$canRun.map { _ in () }.eraseToAnyPublisher(),
            model.autoSwitcher.$remaining.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .sink { [weak self] in self?.scheduleFlush() }
            .store(in: &modelSubs)
    }

    private func stopObserving() {
        modelSubs.removeAll()
        channelSubs.removeAll()
        lastState = nil
        lastAuto = nil
        lastCamera = nil
    }

    /// Re-subscribe to the per-channel fields a key draws from. Rebuilt whenever the list changes,
    /// so an added channel is watched and a removed one lets go.
    private func observe(_ channels: [BridgeChannel]) {
        channelSubs.removeAll()
        for channel in channels {
            let fields: [AnyPublisher<Void, Never>] = [
                channel.$name.map { _ in () }.eraseToAnyPublisher(),
                channel.$isConnected.map { _ in () }.eraseToAnyPublisher(),
                channel.$controlConnected.map { _ in () }.eraseToAnyPublisher(),
                // The optimistic lens pick, so a lens key lights the moment it is pressed.
                channel.$pendingLens.map { _ in () }.eraseToAnyPublisher(),
                // Every camera state report: the delivery mode feeds the keys, the settings feed
                // the dials. A camera in auto reports once a second; flush sends only what changed.
                channel.$remote.map { _ in () }.eraseToAnyPublisher(),
            ]
            Publishers.MergeMany(fields)
                .sink { [weak self] in self?.scheduleFlush() }
                .store(in: &channelSubs)
        }
        scheduleFlush()
    }

    /// Coalesce: a CUT moves both buses and re-tallies every camera, and that must leave as ONE
    /// message. It also moves the read past `@Published`'s willSet, so the flush sees new values.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard !clients.isEmpty else { return }
        let connections = Array(clients.values)
        let state = ControlState(model: model)
        if state != lastState {
            lastState = state
            send(state, to: connections)
        }
        let auto = ControlAuto(model.autoSwitcher)
        if auto != lastAuto {
            lastAuto = auto
            send(auto, to: connections)
        }
        let camera = ControlCamera(model: model, dials: dials)
        if camera != lastCamera {
            lastCamera = camera
            send(camera, to: connections)
        }
    }
}
