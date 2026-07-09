// Output.swift — the downstream-output contract.
//
// A `VideoOutput` is one re-publishing sink for a channel's decoded frames:
// NDI on the LAN, SRT to a remote ingest, or RTSP for a local server.  A
// channel owns zero or more of them and fans every decoded frame out to each.
//
// Concrete implementations (NDIOutput / SRTOutput / RTSPOutput) land in later
// phases — they depend on SDKs (NDI xcframework, HaishinKit) added to
// project.yml per phase.  This protocol is the stable seam they conform to so
// the channel/model layer is written against it now and never changes when the
// real outputs arrive.

import Foundation
import CoreVideo

/// The kind of downstream transport an output publishes to.  Raw values are
/// stable identifiers (persistable, shown in the UI as a badge).
///
/// Only `.ndi` is functional today; `.srt`, `.rtsp` and `.vcam` exist so the
/// "Publish to" rail can show the operator the FULL protocol surface as visually
/// complete (but non-functional / "Soon") placeholders — the real transports
/// land in later phases.  `CaseIterable` so the "Add output" menu can list every
/// kind without a hand-maintained array that could drift from this enum.
enum OutputKind: String, CaseIterable, Identifiable {
    case ndi
    case obs    // OBS via our ARLV protocol (passthrough relay of the program H.264)
    case hdmi   // fullscreen program on an external display (HDMI / any second screen)
    case srt
    case rtsp
    case vcam   // macOS Virtual Camera (sink-as-webcam)

    var id: String { rawValue }

    /// Operator-facing protocol name for badges, cards and the add menu.  The
    /// rawValue is a lowercase wire/identifier token; this is the human label.
    var displayName: String {
        switch self {
        case .ndi:  return "NDI"
        case .obs:  return "OBS Airlive Bridge"
        case .hdmi: return "HDMI Out"
        case .srt:  return "SRT"
        case .rtsp: return "RTSP"
        case .vcam: return "Virtual Camera"
        }
    }

    /// Short tag for the compact output-card badge.  `displayName` can be long
    /// ("OBS Airlive Bridge") and overflows the fixed badge slot — the long name
    /// lives in the card's name field; the badge stays a tight code.
    var badgeLabel: String {
        switch self {
        case .hdmi: return "HDMI"          // rawValue "hdmi" is already the tag, but be explicit
        default:    return rawValue.uppercased()   // ndi → "NDI", obs → "OBS", …
        }
    }

    /// SF Symbol for the kind badge / add menu.  All chosen names exist on
    /// macOS 13 (no SF5 / macOS-14-only glyphs, no gen-numbered variants) so they
    /// render on the deployment target — a blank badge would look broken.
    var symbolName: String {
        switch self {
        case .ndi:  return "antenna.radiowaves.left.and.right"
        case .obs:  return "tv"
        case .hdmi: return "display"
        case .srt:  return "dot.radiowaves.right"
        case .rtsp: return "network"
        case .vcam: return "video"
        }
    }

    /// Whether this transport is actually implemented.  Drives the "Soon" pill /
    /// disabled controls on placeholder cards and the add menu — the single
    /// source of truth so the card and the menu can never disagree about which
    /// kinds are real.
    var isImplemented: Bool { self == .ndi || self == .obs || self == .rtsp || self == .srt || self == .hdmi }
}

/// One downstream re-publishing sink.  Reference type (`AnyObject`) because an
/// output owns live resources — an NDI sender, an SRT socket, an encoder — that
/// have identity and a start/stop lifecycle; it is not a value.
///
/// Frame contract: the channel calls `send(_:timeNs:)` for every decoded frame
/// while the output `isLive`.  `timeNs` is a monotonic host timestamp in
/// nanoseconds used to pace / stamp the outgoing stream; the output must not
/// retain `pixelBuffer` past the call (copy if it needs to defer encoding).
protocol VideoOutput: AnyObject {
    /// Stable identity — survives rename and list reorder.
    var id: UUID { get }
    /// Operator-facing display name (e.g. "NDI: Studio LAN").  Renameable.
    var label: String { get set }
    /// Which transport this output publishes to.
    var kind: OutputKind { get }
    /// True once `start()` has brought the transport up and frames are flowing.
    var isLive: Bool { get }

    /// Last transport failure as an operator-facing one-liner (nil = healthy).
    /// Set by start/bind/connect failures and CLEARED on the next success — the
    /// card renders it in red, so a failed toggle never collapses into the same
    /// silent "off" look as a never-clicked one.
    var lastError: String? { get }

    /// Bring the transport up (open socket / create NDI sender / start encoder).
    func start()
    /// Tear the transport down and release all resources.
    func stop()
    /// Publish one decoded frame.  `timeNs` is a monotonic host time in
    /// nanoseconds.  No-op when not live.
    func send(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64)

    /// Raw-H.264 passthrough hooks — used ONLY by the OBS relay (it forwards the
    /// program camera's existing encode, no transcode).  Buffer outputs (NDI)
    /// ignore them via the default no-op below.  `relayFormat` carries the
    /// length-prefixed SPS/PPS the camera resends each keyframe.
    func relayFormat(_ payload: Data)
    func relaySample(_ payload: Data, timestampMicros: Int64)

    /// Passthrough-CUT gating — implemented by EVERY raw-H.264 relay (OBS / RTSP / SRT), no-op for
    /// buffer outputs (NDI).  `awaitFormat` drops forwarded samples until the new source's SPS/PPS
    /// arrives after a program CUT, so the new camera's H.264 is never decoded against the previous
    /// camera's parameter sets (#20 — was relay-only, now covers RTSP/SRT too).  `clearLastFormat`
    /// forgets the cached format when the program moves to a source with no raw H.264.
    func awaitFormat()
    func clearLastFormat()

    /// Clear `lastError` — the operator ✕-dismissed the message on the card.  A NEW failure re-sets it,
    /// so dismissing hides the current line without silencing future ones.  No-op by default.
    func clearError()

    /// Transport-specific config string from the output card's second field — e.g.
    /// the SRT destination `srt://host:port`.  Defaults to a no-op (NDI group / RTSP
    /// path are not wired today); only SRT stores it.
    var config: String { get set }
}

extension VideoOutput {
    func relayFormat(_ payload: Data) {}
    func relaySample(_ payload: Data, timestampMicros: Int64) {}
    func awaitFormat() {}
    func clearLastFormat() {}
    func clearError() {}
    var config: String { get { "" } set {} }
    var lastError: String? { nil }
}
