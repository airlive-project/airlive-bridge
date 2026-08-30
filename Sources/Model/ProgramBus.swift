// ProgramBus.swift — what the per-frame path reads, and the only thread-safe way to read it.

import Foundation

/// How the program reaches the passthrough outputs (OBS / RTSP / SRT).
enum ProgramFeedMode {
    case passthrough   // the camera's own H.264, forwarded untouched
    case transcode     // no bitstream to forward (AirPlay mirror, capture card) — re-encode
    case black         // nothing on air
}

/// The slice of `BridgeModel` that every frame touches.
///
/// `BridgeModel` is main-isolated: `programOutputs` is `@Published`, and SwiftUI rebuilds that
/// array on main whenever the operator adds, removes or reorders a card, or a profile loads.
/// The frame path is deliberately NOT on main — sharing the UI thread is exactly what made the
/// outgoing picture judder — so it must not read that array directly: one thread would be
/// walking the storage while the other rebuilds it, which is an intermittent crash triggered by
/// something as ordinary as dragging a card during a show.
///
/// So the model PUBLISHES here from main, and the frame path READS here, under a lock.  Copying
/// an array of references once per operator action costs nothing; getting it wrong costs a
/// broadcast.
final class ProgramBus {

    private let lock = NSLock()
    private var _outputs: [VideoOutput] = []
    private var _feedMode: ProgramFeedMode = .black
    private var _lastFormatPayload: Data?

    // MARK: - Published from main

    func publish(outputs: [VideoOutput]) { lock.lock(); _outputs = outputs; lock.unlock() }
    func publish(feedMode: ProgramFeedMode) { lock.lock(); _feedMode = feedMode; lock.unlock() }

    // MARK: - Read from the frame path (any thread)

    var outputs: [VideoOutput] { lock.lock(); defer { lock.unlock() }; return _outputs }
    var feedMode: ProgramFeedMode { lock.lock(); defer { lock.unlock() }; return _feedMode }

    /// Latest program SPS/PPS payload — handed to a passthrough output the moment it starts, so a
    /// mid-stream toggle-on can decode.  CRITICAL: the camera sends formatDescription ONCE per
    /// connection (deliberate, thermal) and its LAN GOP is 6–10 s — an output that missed the one
    /// format packet would mux slices with NO SPS/PPS forever (found live: SRT "non-existing PPS").
    var lastFormatPayload: Data? {
        get { lock.lock(); defer { lock.unlock() }; return _lastFormatPayload }
        set { lock.lock(); _lastFormatPayload = newValue; lock.unlock() }
    }

    /// True while some passthrough consumer actually needs the ENCODED program: a connected OBS
    /// relay, an RTSP client that is PLAYING, or a live SRT peer.  NDI, HDMI and the virtual
    /// camera all take decoded frames and need none of it — so with only those on air the
    /// transcoder must not run at all.
    var hasLivePassthroughConsumer: Bool {
        outputs.contains { out in
            if let relay = out as? AirliveRelayOutput { return relay.isConnected }   // real TCP peer
            if let rtsp = out as? RTSPOutput { return rtsp.hasPlayingClient }         // a client is PLAYING
            if let srt = out as? SRTOutput { return srt.isLive }                      // caller-mode: connected peer
            return false
        }
    }
}
