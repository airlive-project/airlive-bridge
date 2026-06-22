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
enum OutputKind: String {
    case ndi
    case srt
    case rtsp
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

    /// Bring the transport up (open socket / create NDI sender / start encoder).
    func start()
    /// Tear the transport down and release all resources.
    func stop()
    /// Publish one decoded frame.  `timeNs` is a monotonic host time in
    /// nanoseconds.  No-op when not live.
    func send(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64)
}
