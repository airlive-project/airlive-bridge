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

    /// Drop any buffered bytes.  MUST be called when the connection feeding the
    /// parser changes (commit / takeover): the buffer is per-stream state, and
    /// leftover bytes from a dead connection would be parsed as a prefix of the
    /// next connection's stream and desync its framing.
    public func reset() { buffer.removeAll(keepingCapacity: true) }

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

            let length = Int(UInt32(h[6]) << 24 | UInt32(h[7]) << 16 | UInt32(h[8]) << 8 | UInt32(h[9]))
            // Reject an absurd length (corrupt/desynced header) — never wait forever for
            // bytes that aren't coming.  Checked BEFORE the type so the unknown-type skip
            // below can only trust a SANE total.
            guard length <= AirlivePacket.maxPayloadLength else { buffer.removeFirst(); continue }
            let total = AirlivePacket.headerSize + length

            guard let type = AirlivePacket.PacketType(rawValue: h[5]) else {
                // FORWARD-COMPAT (PROTOCOL-COMPAT-SPEC §3): valid magic+version + sane length
                // but a packet type from a NEWER peer → skip the WHOLE packet, not one byte.
                // One-byte resync walked the parser THROUGH the unknown packet's payload, where
                // any embedded "ARLV" bytes mis-framed as packets.  New packet types stay gated
                // on the hello caps (never sent to peers that didn't advertise them); this skip
                // degrades a gating bug to "ignored", not "corrupted stream".
                if buffer.count >= total { buffer.removeFirst(total); continue }
                break   // whole packet not here yet — skip it on a later append
            }

            let timestamp = Int64(h[10]) << 56 | Int64(h[11]) << 48 | Int64(h[12]) << 40 | Int64(h[13]) << 32
                          | Int64(h[14]) << 24 | Int64(h[15]) << 16 | Int64(h[16]) << 8  | Int64(h[17])

            guard buffer.count >= total else { break }

            let s = buffer.index(buffer.startIndex, offsetBy: AirlivePacket.headerSize)
            let e = buffer.index(buffer.startIndex, offsetBy: total)
            let payload = Data(buffer[s..<e])
            packets.append(AirlivePacket(type: type, timestampMicros: timestamp, payload: payload))
            buffer.removeFirst(total)
        }

        // Invariant backstop (parity with the OBS plugin + AirliveCore parser).  With the loop
        // above this is UNREACHABLE: every `break` requires buffer.count < total ≤ header +
        // maxPayloadLength < 2×max.  It exists so a FUTURE edit that accidentally lets the buffer
        // grow degrades to a loud drop-and-resync instead of holding tens of MB.
        if buffer.count > 2 * AirlivePacket.maxPayloadLength {
            print("[PacketParser] ⚠️ buffer exceeded \(2 * AirlivePacket.maxPayloadLength) bytes without a parsable packet — dropping buffered data to resync (invariant breach — investigate)")
            buffer.removeAll(keepingCapacity: false)
        }

        return packets
    }
}

// MARK: - Protocol generation (hello)

/// The PROTOCOL GENERATION ladder — see docs/PROTOCOL-COMPAT-SPEC.md.  Distinct from
/// `AirlivePacket.protocolVersion` (the FRAMING epoch, which never bumps): the generation
/// counts additive protocol surface — +1 per release that adds verbs/fields/types/TXT keys.
/// Used ONLY for the update-prompt UX (`peer.proto < my.minProto` → "please update"); feature
/// availability is decided by hello `caps`, never by comparing these.  MIRRORS AirliveCore.
public enum AirliveProto {
    /// Generation this build speaks.  1 = everything pre-hello; 2 = hello.
    public static let generation = 2
    /// Oldest peer generation this build fully supports.  Starts at 1 and stays 1 indefinitely
    /// (the skew promise); raising it is a DEPRECATION needing the spec's announced window.
    public static let minGeneration = 1
}

/// One-shot per-connection introduction (PROTOCOL-COMPAT-SPEC §2): who the peer is, which
/// protocol generation it speaks, and — the part that matters — which FEATURES (`caps`) it
/// supports.  New protocol surface is used only when BOTH sides advertised the cap; the version
/// ints exist only for the update-prompt UX.  A peer that never sends one is a LEGACY build:
/// `proto=1, caps=[]`.  MIRRORS AirliveCore byte-for-byte.
public struct HelloMessage: Codable, Equatable, Sendable {
    public var app: String = ""            // "camera" | "studio" | "bridge" | "obs"
    public var appVersion: String = ""     // display/logs ONLY — never compared
    public var proto: Int = 1
    public var minProto: Int = 1
    public var caps: [String] = []

    public init(app: String, appVersion: String,
                proto: Int = AirliveProto.generation,
                minProto: Int = AirliveProto.minGeneration,
                caps: [String] = []) {
        self.app = app
        self.appVersion = appVersion
        self.proto = proto
        self.minProto = minProto
        self.caps = caps
    }

    // Tolerant reader — any subset of keys decodes to defaults (a sparse hello never throws).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app        = try c.decodeIfPresent(String.self,   forKey: .app) ?? ""
        appVersion = try c.decodeIfPresent(String.self,   forKey: .appVersion) ?? ""
        proto      = try c.decodeIfPresent(Int.self,      forKey: .proto) ?? 1
        minProto   = try c.decodeIfPresent(Int.self,      forKey: .minProto) ?? 1
        caps       = try c.decodeIfPresent([String].self, forKey: .caps) ?? []
    }
}

// MARK: - Control channel

/// Device-read capability ranges/options for the connected iPhone.  MIRRORS the camera's
/// `AirliveCore` definition byte-for-byte (same fields, same defaults) so the JSON decodes both
/// ways.  All values come from `device.formats` / the active format on the camera — the single
/// source of truth its own pickers use.  See docs/REMOTE-CONTROL-CAPABILITIES-HANDOFF.md.
public struct DeviceCapabilities: Codable, Equatable, Sendable {
    public var isoMin: Float = 25
    public var isoMax: Float = 3200
    public var shutterMinDenom: Float = 24
    public var shutterMaxDenom: Float = 8000
    public var wbTempMin: Float = 2000
    public var wbTempMax: Float = 10000
    public var wbTintMin: Float = -150
    public var wbTintMax: Float = 150
    /// fps options for the CURRENT (codec × colourSpace × resolution), e.g. [24, 25, 30, 50, 60].
    /// NOTE: [Int] collapses NTSC fractional rates (29.97→30, 23.98→24, 59.94→60); a receiver
    /// that must offer exact NTSC reads `supportedFpsExact` instead.
    public var supportedFps: [Int] = []
    /// Resolutions THIS device supports for the current codec+colourSpace ("1080" / "4K").
    public var resolutions: [String] = []
    /// Codecs available in the current colour space ("H.264" / "HEVC" / "ProRes 422").
    public var codecs: [String] = []
    /// EV-bias (exposure-compensation) bounds, device-read.  Fallback ±2.
    public var evBiasMin: Float = -2
    public var evBiasMax: Float = 2
    /// EXACT fps options as Float, including NTSC 23.98 / 29.97 / 59.94 that `supportedFps`
    /// ([Int]) rounds away.  A capability-driven remote picker needing broadcast NTSC reads
    /// this; empty from an older sender.
    public var supportedFpsExact: [Float] = []
    /// LUT names the operator marked for QUICK ACCESS (the eye-toggled subset the on-device menu
    /// shows — NOT the full imported library), so a remote picker mirrors what the operator
    /// curated.  The `setLUT` verb already applies any name; this is the list to pick from.
    /// Empty from an older sender.
    public var availableLuts: [String] = []
    /// Max zoom factor of the active format (`videoMaxZoomFactor`), so a remote zoom ladder
    /// matches THIS device instead of a guessed 1–10.  `0` = not provided (older sender) →
    /// the receiver uses its own fallback.
    public var zoomMax: Float = 0
    /// Stabilization levels pickable remotely — "Standard" / "High".  Never "Off": disabling
    /// stabilization while `activeFormat` changes wedges the iOS 26 / iPhone 15+ daemon
    /// (-17281).  Empty from an older sender.
    public var stabilizations: [String] = []
    /// Colour spaces pickable at the CURRENT codec+resolution (device-read, the same list the
    /// camera's own Settings picker shows) — exact rawValues "Rec.709" / "P3 D65" /
    /// "Rec.2020 HLG" / "Apple Log" for `setColorSpace`.  Empty from an older sender.
    public var colorSpaces: [String] = []

    public init(isoMin: Float = 25, isoMax: Float = 3200,
                shutterMinDenom: Float = 24, shutterMaxDenom: Float = 8000,
                wbTempMin: Float = 2000, wbTempMax: Float = 10000,
                wbTintMin: Float = -150, wbTintMax: Float = 150,
                supportedFps: [Int] = [], resolutions: [String] = [],
                codecs: [String] = [],
                evBiasMin: Float = -2, evBiasMax: Float = 2,
                supportedFpsExact: [Float] = [],
                availableLuts: [String] = [], zoomMax: Float = 0,
                stabilizations: [String] = [], colorSpaces: [String] = []) {
        self.isoMin = isoMin; self.isoMax = isoMax
        self.shutterMinDenom = shutterMinDenom; self.shutterMaxDenom = shutterMaxDenom
        self.wbTempMin = wbTempMin; self.wbTempMax = wbTempMax
        self.wbTintMin = wbTintMin; self.wbTintMax = wbTintMax
        self.supportedFps = supportedFps
        self.resolutions = resolutions
        self.codecs = codecs
        self.evBiasMin = evBiasMin; self.evBiasMax = evBiasMax
        self.supportedFpsExact = supportedFpsExact
        self.availableLuts = availableLuts
        self.zoomMax = zoomMax
        self.stabilizations = stabilizations
        self.colorSpaces = colorSpaces
    }

    // Custom decoder so a PARTIAL `capabilities` object (any subset of keys, from an older/newer
    // sender) decodes to defaults instead of THROWING keyNotFound and dropping the whole state
    // packet — Swift's synthesized Decodable uses `decode`, not `decodeIfPresent`.  Mirrors the
    // camera's AirliveCore exactly (see docs/REMOTE-CONTROL-CAPABILITIES-HANDOFF.md).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isoMin          = try c.decodeIfPresent(Float.self, forKey: .isoMin) ?? 25
        isoMax          = try c.decodeIfPresent(Float.self, forKey: .isoMax) ?? 3200
        shutterMinDenom = try c.decodeIfPresent(Float.self, forKey: .shutterMinDenom) ?? 24
        shutterMaxDenom = try c.decodeIfPresent(Float.self, forKey: .shutterMaxDenom) ?? 8000
        wbTempMin       = try c.decodeIfPresent(Float.self, forKey: .wbTempMin) ?? 2000
        wbTempMax       = try c.decodeIfPresent(Float.self, forKey: .wbTempMax) ?? 10000
        wbTintMin       = try c.decodeIfPresent(Float.self, forKey: .wbTintMin) ?? -150
        wbTintMax       = try c.decodeIfPresent(Float.self, forKey: .wbTintMax) ?? 150
        supportedFps    = try c.decodeIfPresent([Int].self,    forKey: .supportedFps) ?? []
        resolutions     = try c.decodeIfPresent([String].self, forKey: .resolutions) ?? []
        codecs          = try c.decodeIfPresent([String].self, forKey: .codecs) ?? []
        evBiasMin       = try c.decodeIfPresent(Float.self,    forKey: .evBiasMin) ?? -2
        evBiasMax       = try c.decodeIfPresent(Float.self,    forKey: .evBiasMax) ?? 2
        supportedFpsExact = try c.decodeIfPresent([Float].self, forKey: .supportedFpsExact) ?? []
        availableLuts   = try c.decodeIfPresent([String].self, forKey: .availableLuts) ?? []
        zoomMax         = try c.decodeIfPresent(Float.self,   forKey: .zoomMax) ?? 0
        stabilizations  = try c.decodeIfPresent([String].self, forKey: .stabilizations) ?? []
        colorSpaces     = try c.decodeIfPresent([String].self, forKey: .colorSpaces) ?? []

        // Clamp wire-supplied envelopes to sane physical maxima BEFORE anything builds a ladder from
        // them.  CameraControlPanel materializes `Array(stride(from: min, through: max, by: step))` for
        // WB temp/tint and zoom; a corrupt/hostile bound (e.g. zoomMax=1e8, auth is off by default)
        // would allocate hundreds of millions of Doubles synchronously during a SwiftUI body eval →
        // main-thread freeze / OOM.  Real devices sit far inside these; the clamp only bites a
        // malformed packet.  (Inversion is handled separately by each ladder's `guard hi > lo`.)
        wbTempMin = min(max(wbTempMin, 1000), 50000)
        wbTempMax = min(max(wbTempMax, 1000), 50000)
        wbTintMin = min(max(wbTintMin, -1000), 1000)
        wbTintMax = min(max(wbTintMax, -1000), 1000)
        zoomMax   = min(max(zoomMax, 0), 1000)
    }
}

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
    public var colorSpace: String          // EXACT raw: "Apple Log" / "Rec.709" / "P3 D65" / "Rec.2020 HLG"
                                           // (NOT "HLG BT.2020" — old lying comment; camera sends ColorSpaceMode.rawValue)
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
    /// Device-read capability ranges/options (ISO/shutter/WB bounds + fps/resolution/codec
    /// options) so the remote UI renders DEVICE-ACCURATE controls for THIS iPhone instead of
    /// hardcoded per-model tables.  Additive: a STORED default keeps an OLD sender (no
    /// `capabilities` key) decodable.  See docs/REMOTE-CONTROL-CAPABILITIES-HANDOFF.md.
    public var capabilities: DeviceCapabilities = .init()
    /// Current record-master codec ("H.264" / "HEVC" / "ProRes 422") — additive so Bridge can
    /// highlight / round-trip the ACTIVE codec, not just the OPTIONS in `capabilities.codecs`.
    /// "" from an older sender (decodeIfPresent below).
    public var codec: String = ""
    /// Current exposure-compensation (EV bias) applied to auto-exposure; bounds are in
    /// `capabilities.evBiasMin/Max`.  Additive; 0 from an older sender.
    public var exposureBias: Float = 0
    /// Current video-stabilization level ("Standard" / "High") — readback so a remote controller
    /// shows the active mode; options in `capabilities.stabilizations`.  "" from an older sender.
    public var stabilization: String = ""

    public init(iso: Float, shutterDenom: Float, wbKelvin: Float, tint: Float,
                lens: String?, zoom: Float, focusAuto: Bool, focusPosition: Float,
                fps: Int, exposureAuto: Bool, whiteBalanceAuto: Bool,
                resolution: String, colorSpace: String,
                lutName: String?, lutEnabled: Bool, isoCompensation: Bool,
                availableLenses: [String], deviceModel: String,
                outputRotation: Int = 0,
                videoActive: Bool = true, deviceName: String = "",
                remoteControlAllowed: Bool = true, tallyEnabled: Bool = true,
                capabilities: DeviceCapabilities = .init(),
                codec: String = "", exposureBias: Float = 0,
                stabilization: String = "") {
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
        self.capabilities = capabilities
        self.codec = codec
        self.exposureBias = exposureBias
        self.stabilization = stabilization
    }

    // Custom decoder — a STORED DEFAULT is NOT enough: Swift's synthesized Decodable calls
    // `decode` (not `decodeIfPresent`) and THROWS keyNotFound on a missing additive key, dropping
    // the WHOLE state packet from an older sender.  Core fields stay `decode` (present in every
    // version); additive fields use `decodeIfPresent ?? default`.  Mirrors the camera's AirliveCore.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iso              = try c.decode(Float.self, forKey: .iso)
        shutterDenom     = try c.decode(Float.self, forKey: .shutterDenom)
        wbKelvin         = try c.decode(Float.self, forKey: .wbKelvin)
        tint             = try c.decode(Float.self, forKey: .tint)
        lens             = try c.decodeIfPresent(String.self, forKey: .lens)
        zoom             = try c.decode(Float.self, forKey: .zoom)
        focusAuto        = try c.decode(Bool.self, forKey: .focusAuto)
        focusPosition    = try c.decode(Float.self, forKey: .focusPosition)
        fps              = try c.decode(Int.self, forKey: .fps)
        exposureAuto     = try c.decode(Bool.self, forKey: .exposureAuto)
        whiteBalanceAuto = try c.decode(Bool.self, forKey: .whiteBalanceAuto)
        resolution       = try c.decode(String.self, forKey: .resolution)
        colorSpace       = try c.decode(String.self, forKey: .colorSpace)
        lutName          = try c.decodeIfPresent(String.self, forKey: .lutName)
        lutEnabled       = try c.decode(Bool.self, forKey: .lutEnabled)
        isoCompensation  = try c.decode(Bool.self, forKey: .isoCompensation)
        availableLenses  = try c.decode([String].self, forKey: .availableLenses)
        deviceModel      = try c.decode(String.self, forKey: .deviceModel)
        // ── Additive (tolerate missing keys from older senders) ──
        outputRotation       = try c.decodeIfPresent(Int.self,    forKey: .outputRotation) ?? 0
        videoActive          = try c.decodeIfPresent(Bool.self,   forKey: .videoActive) ?? true
        deviceName           = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        remoteControlAllowed = try c.decodeIfPresent(Bool.self,   forKey: .remoteControlAllowed) ?? true
        tallyEnabled         = try c.decodeIfPresent(Bool.self,   forKey: .tallyEnabled) ?? true
        capabilities         = try c.decodeIfPresent(DeviceCapabilities.self, forKey: .capabilities) ?? .init()
        codec                = try c.decodeIfPresent(String.self, forKey: .codec) ?? ""
        exposureBias         = try c.decodeIfPresent(Float.self,  forKey: .exposureBias) ?? 0
        stabilization        = try c.decodeIfPresent(String.self, forKey: .stabilization) ?? ""
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
public struct ControlMessage: Codable, Sendable {
    public let type: String
    public var state: StateSnapshot?
    public var floatValue: Float?
    public var intValue: Int?
    public var stringValue: String?
    public var boolValue: Bool?
    public var lutName: String?
    /// One-shot per-connection introduction (type == "hello") — additive: old peers decode a
    /// message with this key fine (unknown JSON keys ignored) and hit `default: break`.
    public var hello: HelloMessage?
    /// Normalised point payload for tap-to-focus / tap-to-expose verbs (`setFocusPoint` /
    /// `setExposurePoint`) — additive, same old-peer tolerance as `hello`.  See the
    /// constructors for the coordinate space.
    public var pointX: Float?
    public var pointY: Float?

    public init(type: String,
                state: StateSnapshot? = nil,
                floatValue: Float? = nil,
                intValue: Int? = nil,
                stringValue: String? = nil,
                boolValue: Bool? = nil,
                lutName: String? = nil,
                hello: HelloMessage? = nil,
                pointX: Float? = nil,
                pointY: Float? = nil) {
        self.type = type
        self.state = state
        self.floatValue = floatValue
        self.intValue = intValue
        self.stringValue = stringValue
        self.boolValue = boolValue
        self.lutName = lutName
        self.hello = hello
        self.pointX = pointX
        self.pointY = pointY
    }

    // MARK: Convenience constructors

    public static func state(_ s: StateSnapshot) -> ControlMessage {
        ControlMessage(type: "state", state: s)
    }
    /// One-shot introduction, first control message of a connection (receiver → camera right
    /// after accept/auth).  MIRRORS AirliveCore.
    public static func hello(_ h: HelloMessage) -> ControlMessage {
        ControlMessage(type: "hello", hello: h)
    }
    /// Exposure compensation (EV bias) for auto-exposure — biases the AE target brighter/darker.
    /// Bounds are advertised in `capabilities.evBiasMin/Max`.
    public static func setExposureBias(_ v: Float) -> ControlMessage {
        ControlMessage(type: "setExposureBias", floatValue: v)
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
    /// Fractional NTSC rates (23.98 / 29.97 / 59.94) ride `floatValue` — the camera's "setFPS"
    /// handler reads floatValue FIRST and falls back to intValue for integer rates.
    public static func setFPS(exact v: Float) -> ControlMessage {
        ControlMessage(type: "setFPS", floatValue: v)
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
    /// Video-stabilization level — "Standard" or "High" (NOT "Cinematic"/"Off"; "High" maps to
    /// .cinematic camera-side, unknown strings are silently ignored).  A runtime connection-
    /// property change on the camera (no format reconfigure) → safe mid-take.
    public static func setStabilization(_ v: String) -> ControlMessage {
        ControlMessage(type: "setStabilization", stringValue: v)
    }
    /// Capture colour space — EXACT `StateSnapshot.colorSpace` rawValues: "Rec.709" / "P3 D65" /
    /// "Rec.2020 HLG" / "Apple Log" (options in `capabilities.colorSpaces`).  ⚠️ Full device
    /// reconfigure on the camera (the -17281-guarded path) — REFUSED mid-take like
    /// `setResolution`/`setFPS`; the camera re-broadcasts unchanged state → UI must snap back.
    public static func setColorSpace(_ v: String) -> ControlMessage {
        ControlMessage(type: "setColorSpace", stringValue: v)
    }
    /// Tap-to-focus at a normalised image point.  COORDINATE SPACE: Apple's
    /// `focusPointOfInterest` convention — (0,0) top-left … (1,1) bottom-right of the SENSOR
    /// frame in its native LANDSCAPE orientation (the same frame the wire ships;
    /// `outputRotation` is presentation-only, so a receiver showing a rotated feed must map its
    /// tap back through that rotation BEFORE sending).  Camera clamps to 0…1; focus retargets
    /// and stays auto, exposure retargets ONLY while exposure is auto (local-tap semantics).
    public static func setFocusPoint(x: Float, y: Float) -> ControlMessage {
        ControlMessage(type: "setFocusPoint", pointX: x, pointY: y)
    }
    /// Tap-to-expose (AE point of interest) — same coordinate space and clamping as
    /// `setFocusPoint`.  REFUSED while exposure is MANUAL (camera re-syncs state).
    public static func setExposurePoint(x: Float, y: Float) -> ControlMessage {
        ControlMessage(type: "setExposurePoint", pointX: x, pointY: y)
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
