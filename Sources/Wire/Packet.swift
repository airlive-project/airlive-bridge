// Packet.swift — Airlive Bridge wire format.
//
// STANDALONE COPY of AirliveCore/Sources/AirliveCore/Packet.swift.  Bridge must
// never link or reference the airlive repo (the camera/studio/AirliveCore apps
// are frozen and owned by another team), so the wire contract is duplicated here
// verbatim and kept in sync by hand.
//
// Wire format (18-byte header, all multi-byte fields big-endian):
//   [4 magic="ARLV"][1 version][1 type][4 payload_length][8 timestamp_us][N payload]
//
// Bridge-only additive change: `StateSnapshot.outputRotation` (clockwise
// 0/90/180/270) — a presentation-only rotation hint with a STORED default of 0
// so it stays wire-compatible with the frozen camera/studio (a sender that omits
// the JSON key still decodes).

import Foundation

// Wire format: [4 magic][1 version][1 type][4 payload_length][8 timestamp_us][N payload]
public struct AirlivePacket {
    public static let magic: UInt32 = 0x41524C56 // "ARLV"
    /// Bumped whenever the binary framing changes incompatibly.  Carried in
    /// every header so a newer Studio talking to an older Camera (or vice
    /// versa, across an app-store update) DETECTS the mismatch and resyncs
    /// past it instead of silently mis-framing garbage as video.
    public static let protocolVersion: UInt8 = 1
    public static let headerSize = 18            // 4 magic +1 version +1 type +4 len +8 ts
    /// Hard upper bound on a network-sourced payload length.  A corrupt /
    /// hostile / desynced header that lands a huge `length` would otherwise
    /// make the parser wait forever for bytes that never come (and grow the
    /// buffer unbounded).  16 MB is well above any real access unit
    /// (1080p HEVC keyframe ≪ 1 MB) — over it, the header is treated as
    /// corrupt and the parser resyncs.
    public static let maxPayloadLength = 16 * 1024 * 1024

    public enum PacketType: UInt8 {
        case formatDescription = 0
        case sample            = 1
        /// JSON-encoded `ControlMessage` (Codable) carrying either a full
        /// state snapshot (iPhone → Mac, sent on connect and after any
        /// locally-initiated change) or a single set-command (Mac →
        /// iPhone, sent when the operator turns a knob in the Studio UI).
        /// Same TCP socket as `.sample` frames — full-duplex on Apple's
        /// `NWConnection`.
        case control           = 2
        // ── Receiver-password auth (challenge-response, HMAC) ──────────────
        // Additive: `protocolVersion` is NOT bumped, so a receiver with auth
        // OFF never sends `authChallenge` and an old↔new pair behaves exactly
        // as before.  Replicated from AirliveCore/Packet.swift (FROZEN) +
        // docs/STREAM-AUTH-SPEC.md.  Wire payloads:
        //   authChallenge (receiver→camera): 32 raw bytes, single-use nonce.
        //   authResponse  (camera→receiver): 32 raw bytes, the HMAC tag.
        //   authResult    (receiver→camera): JSON-encoded `AuthResult`.
        case authChallenge     = 3
        case authResponse      = 4
        case authResult        = 5
    }

    public let type: PacketType
    public let timestampMicros: Int64
    public let payload: Data

    public init(type: PacketType, timestampMicros: Int64 = 0, payload: Data) {
        self.type = type
        self.timestampMicros = timestampMicros
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        var magic = Self.magic.bigEndian
        out.append(contentsOf: withUnsafeBytes(of: &magic) { Data($0) })
        out.append(Self.protocolVersion)
        out.append(type.rawValue)
        var length = UInt32(payload.count).bigEndian
        out.append(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        var ts = timestampMicros.bigEndian
        out.append(contentsOf: withUnsafeBytes(of: &ts) { Data($0) })
        out.append(payload)
        return out
    }
}

public final class PacketParser {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) -> [AirlivePacket] {
        buffer.append(data)
        var packets: [AirlivePacket] = []

        while buffer.count >= AirlivePacket.headerSize {
            // Copy header to a plain [UInt8] — no alignment or startIndex issues
            var h = [UInt8](repeating: 0, count: AirlivePacket.headerSize)
            _ = h.withUnsafeMutableBytes { buffer.copyBytes(to: $0, count: AirlivePacket.headerSize) }

            let magic = UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])
            guard magic == AirlivePacket.magic else { buffer.removeFirst(); continue }

            // Version mismatch = an incompatible peer build.  Resync past it
            // (drop a byte) rather than mis-framing its payload as ours.
            guard h[4] == AirlivePacket.protocolVersion else { buffer.removeFirst(); continue }

            guard let type = AirlivePacket.PacketType(rawValue: h[5]) else {
                buffer.removeFirst(); continue
            }

            let length = Int(UInt32(h[6]) << 24 | UInt32(h[7]) << 16 | UInt32(h[8]) << 8 | UInt32(h[9]))
            // Reject an absurd length (corrupt/desynced header) — never wait
            // forever for bytes that aren't coming.
            guard length <= AirlivePacket.maxPayloadLength else { buffer.removeFirst(); continue }
            let timestamp = Int64(h[10]) << 56 | Int64(h[11]) << 48 | Int64(h[12]) << 40 | Int64(h[13]) << 32
                          | Int64(h[14]) << 24 | Int64(h[15]) << 16 | Int64(h[16]) << 8  | Int64(h[17])

            let total = AirlivePacket.headerSize + length
            guard buffer.count >= total else { break }

            let s = buffer.index(buffer.startIndex, offsetBy: AirlivePacket.headerSize)
            let e = buffer.index(buffer.startIndex, offsetBy: total)
            let payload = Data(buffer[s..<e])
            packets.append(AirlivePacket(type: type, timestampMicros: timestamp, payload: payload))
            buffer.removeFirst(total)
        }

        return packets
    }
}

// MARK: - Control channel

/// Full snapshot of the iPhone's camera state.  Sent from iPhone → Mac on
/// connection-establish so the Studio UI mirrors the actual camera values
/// instead of the Mac-side defaults.  Re-sent after every locally-
/// initiated change so the operator sees auto-readback values too
/// (auto-exposure ISO ticks, auto-WB temperature, etc.).
public struct StateSnapshot: Codable, Equatable, Sendable {
    public var iso: Float
    public var shutterDenom: Float
    public var wbKelvin: Float
    public var tint: Float
    public var lens: String?
    public var zoom: Float
    public var focusAuto: Bool
    public var focusPosition: Float
    public var fps: Int
    public var exposureAuto: Bool
    public var whiteBalanceAuto: Bool
    public var resolution: String          // "1080" / "4K"
    public var colorSpace: String          // "Apple Log" / "Rec.709" / "HLG BT.2020" / "P3 D65"
    public var lutName: String?
    public var lutEnabled: Bool
    public var isoCompensation: Bool
    public var availableLenses: [String]   // e.g. ["0.5x", "1x", "2x"]
    public var deviceModel: String
    /// Degrees the RECEIVER rotates the (always-landscape) frame clockwise to
    /// present it matching the operator's screen orientation — the Option B
    /// vertical-stream hint.  The iPhone NEVER rotates its own buffer (thermal
    /// rule); this is a presentation flag only, exactly like a video file's tkhd
    /// transform.  0 = native landscape.  Defaulted in the init so older
    /// senders/receivers stay wire-compatible (additive Codable field).
    /// STORED default `= 0` (not just the init default) is REQUIRED: the
    /// synthesized `Decodable` only treats a missing JSON key as optional when
    /// the stored property has a default — otherwise an OLD sender (no key) throws
    /// `DecodingError.keyNotFound` and its whole control message fails to decode.
    public var outputRotation: Int = 0

    // ── Delivery mode + operator gates (additive, STORED defaults — see
    //    docs/DELIVERY-MODE-DESIGN.md).  A camera that omits these keys decodes the
    //    SAFE LEGACY assumption: video on, control + tally allowed.  STORED defaults
    //    (not just init defaults) are REQUIRED so an old sender's missing key doesn't
    //    throw keyNotFound — same rule as `outputRotation` above. ──────────────────
    /// Is the camera CURRENTLY encoding + sending its own Airlive video on this link?
    /// `false` = Control-only (encoder OFF; video, if any, arrives out-of-band via
    /// AirPlay).  ⚠️ The UI MUST key its video tile off THIS field, never off the mode
    /// it requested — the camera is the source of truth (protocol invariant W1).
    public var videoActive: Bool = true
    /// Operator-set camera name (Settings → Live); the human label Bridge shows for this
    /// control link and binds an AirPlay tile to.  `""` → Bridge falls back to deviceModel.
    public var deviceName: String = ""
    /// Operator's "Remote control: on/off" gate.  `false` = the camera drops ALL remote
    /// set-commands; Bridge greys its control panel and shows why (never sends into a void).
    public var remoteControlAllowed: Bool = true
    /// Operator's "Tally light: on/off" gate.  `false` = the camera ignores tally; Bridge
    /// greys / hides its tally affordance.
    public var tallyEnabled: Bool = true

    public init(iso: Float, shutterDenom: Float, wbKelvin: Float, tint: Float,
                lens: String?, zoom: Float, focusAuto: Bool, focusPosition: Float,
                fps: Int, exposureAuto: Bool, whiteBalanceAuto: Bool,
                resolution: String, colorSpace: String,
                lutName: String?, lutEnabled: Bool, isoCompensation: Bool,
                availableLenses: [String], deviceModel: String,
                outputRotation: Int = 0,
                videoActive: Bool = true, deviceName: String = "",
                remoteControlAllowed: Bool = true, tallyEnabled: Bool = true) {
        self.iso = iso
        self.shutterDenom = shutterDenom
        self.wbKelvin = wbKelvin
        self.tint = tint
        self.lens = lens
        self.zoom = zoom
        self.focusAuto = focusAuto
        self.focusPosition = focusPosition
        self.fps = fps
        self.exposureAuto = exposureAuto
        self.whiteBalanceAuto = whiteBalanceAuto
        self.resolution = resolution
        self.colorSpace = colorSpace
        self.lutName = lutName
        self.lutEnabled = lutEnabled
        self.isoCompensation = isoCompensation
        self.availableLenses = availableLenses
        self.deviceModel = deviceModel
        self.outputRotation = outputRotation
        self.videoActive = videoActive
        self.deviceName = deviceName
        self.remoteControlAllowed = remoteControlAllowed
        self.tallyEnabled = tallyEnabled
    }

    /// The human label for this control link: the operator-set `deviceName`, falling
    /// back to the device model when the operator hasn't named it.
    public var displayName: String {
        let n = deviceName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? deviceModel : n
    }
}

/// Canonical delivery-mode strings carried by `setDeliveryMode` and reflected by
/// `StateSnapshot.videoActive`.  Matches the camera contract (docs/DELIVERY-MODE-DESIGN.md).
public enum DeliveryMode: String, Sendable, CaseIterable, Identifiable {
    case videoAndControl
    case controlOnly
    public var id: String { rawValue }
}

/// One control message — either a full `state` broadcast (iPhone → Mac)
/// or a single `set...` command (Mac → iPhone).  Codable as JSON so the
/// wire format stays human-readable when debugging packet captures.
///
/// Discriminated union via the `type` field; only the matching value
/// payload (one of state / floatValue / intValue / stringValue /
/// boolValue / lutPayload) is read.  Optional fields keep the JSON
/// compact (omitted fields don't get encoded).
public struct ControlMessage: Codable {
    public let type: String
    public var state: StateSnapshot?
    public var floatValue: Float?
    public var intValue: Int?
    public var stringValue: String?
    public var boolValue: Bool?
    public var lutName: String?

    public init(type: String,
                state: StateSnapshot? = nil,
                floatValue: Float? = nil,
                intValue: Int? = nil,
                stringValue: String? = nil,
                boolValue: Bool? = nil,
                lutName: String? = nil) {
        self.type = type
        self.state = state
        self.floatValue = floatValue
        self.intValue = intValue
        self.stringValue = stringValue
        self.boolValue = boolValue
        self.lutName = lutName
    }

    // MARK: Convenience constructors

    public static func state(_ s: StateSnapshot) -> ControlMessage {
        ControlMessage(type: "state", state: s)
    }
    public static func setISO(_ v: Float) -> ControlMessage {
        ControlMessage(type: "setISO", floatValue: v)
    }
    public static func setShutter(_ v: Float) -> ControlMessage {
        ControlMessage(type: "setShutter", floatValue: v)
    }
    public static func setWB(_ v: Float) -> ControlMessage {
        ControlMessage(type: "setWB", floatValue: v)
    }
    public static func setTint(_ v: Float) -> ControlMessage {
        ControlMessage(type: "setTint", floatValue: v)
    }
    public static func setLens(_ label: String) -> ControlMessage {
        ControlMessage(type: "setLens", stringValue: label)
    }
    public static func setZoom(_ v: Float) -> ControlMessage {
        ControlMessage(type: "setZoom", floatValue: v)
    }
    public static func setFocusAuto(_ v: Bool) -> ControlMessage {
        ControlMessage(type: "setFocusAuto", boolValue: v)
    }
    public static func setFocusPosition(_ v: Float) -> ControlMessage {
        ControlMessage(type: "setFocusPosition", floatValue: v)
    }
    public static func setFPS(_ v: Int) -> ControlMessage {
        ControlMessage(type: "setFPS", intValue: v)
    }
    public static func setExposureAuto(_ v: Bool) -> ControlMessage {
        ControlMessage(type: "setExposureAuto", boolValue: v)
    }
    public static func setWhiteBalanceAuto(_ v: Bool) -> ControlMessage {
        ControlMessage(type: "setWhiteBalanceAuto", boolValue: v)
    }
    public static func setResolution(_ v: String) -> ControlMessage {
        ControlMessage(type: "setResolution", stringValue: v)
    }
    public static func setLUT(name: String?, enabled: Bool) -> ControlMessage {
        ControlMessage(type: "setLUT", boolValue: enabled, lutName: name)
    }
    public static func setIsoCompensation(_ v: Bool) -> ControlMessage {
        ControlMessage(type: "setIsoCompensation", boolValue: v)
    }
    /// Tally cue for the iPhone's on-screen "you are LIVE / staged" bar.
    /// Values: `"none"`, `"preview"`, `"program"` — iPhone renders a
    /// thick vertical stripe along the leading edge of its viewfinder
    /// so the operator behind the camera can see at a glance whether
    /// their CAM is on air, queued, or off.
    public static func setCue(_ v: String) -> ControlMessage {
        ControlMessage(type: "setCue", stringValue: v)
    }
    /// Ask the camera to emit an IDR (keyframe) NOW, so a passthrough relay (OBS)
    /// can resync immediately after a CUT instead of waiting for the next natural
    /// keyframe.  FORWARD-SAFE: a camera that doesn't recognise the type ignores it
    /// (the relay then resyncs on the next natural keyframe — no regression), so the
    /// Bridge can ship this before the camera handler exists.
    public static func forceKeyframe() -> ControlMessage {
        ControlMessage(type: "forceKeyframe")
    }
    /// Request the camera's delivery mode: `"videoAndControl"` (default — sends its own
    /// H.264 proxy) or `"controlOnly"` (encoder OFF; control + tally only, video via
    /// AirPlay).  Rides `stringValue`, exactly like `setLens`.  ⚠️ The request is NOT the
    /// truth: the camera APPLIES it then re-broadcasts the actual state in
    /// `StateSnapshot.videoActive` — always key the UI off `videoActive`.  Forward-safe:
    /// an old camera hits `default: break` and keeps streaming.
    public static func setDeliveryMode(_ mode: String) -> ControlMessage {
        ControlMessage(type: "setDeliveryMode", stringValue: mode)
    }
    public static func setDeliveryMode(_ mode: DeliveryMode) -> ControlMessage {
        setDeliveryMode(mode.rawValue)
    }

    // MARK: Encode / decode helpers — wrap JSON in an AirlivePacket payload

    public func encodeAsPacket() -> AirlivePacket {
        // Loud-fail: a JSON encode failure (e.g. a NaN/Inf float in a set-command)
        // would otherwise send a 0-byte control packet the receiver silently
        // drops — a control command lost without a trace.  Wire format unchanged;
        // this only adds a log on the (rare) failure path.
        let data: Data
        do {
            data = try JSONEncoder().encode(self)
        } catch {
            print("[ControlMessage] ❌ encode failed for type=\(type): \(error) — sending empty payload")
            data = Data()
        }
        return AirlivePacket(type: .control, payload: data)
    }

    public static func decode(from payload: Data) -> ControlMessage? {
        do {
            return try JSONDecoder().decode(ControlMessage.self, from: payload)
        } catch {
            print("[ControlMessage] ❌ decode failed (\(payload.count) bytes) — command dropped: \(error)")
            return nil
        }
    }
}
