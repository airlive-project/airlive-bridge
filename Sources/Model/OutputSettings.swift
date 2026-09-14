// OutputSettings.swift - Bridge latency presets.
//
// Ported from AirliveStudioApp/Sources/OutputSettings.swift, trimmed to only `LatencyPreset` - the
// jitter-buffer rungs the operator picks ONCE for the room (BridgeModel.latencyBuffer, shown in the
// channel rail's footer) and every channel then carries.  Studio's resolution / bitrate /
// recording-folder machinery is YouTube-streamer-specific and not part of Bridge's foundation.
//
// A per-channel ADDITIONAL offset lives separately (BridgeChannel.extraDelayMs) for lining one
// source up with a slower one; that one is genuinely per camera.

import Foundation

/// System latency presets, expressed in MILLISECONDS (not frames - a 30 fps and
/// a 60 fps camera held to the same delay must line up; frame-count presets
/// silently desync mixed-rate sources).
///
/// Every value is a REAL shipping industry standard, not an invented round
/// number:
///   - 0   - WebRTC playout-delay `min=0` ("render ASAP"); OBS `async_unbuffered`.
///   - 60  - under two frames at 30 fps: absorbs ONE late packet and nothing more.
///   - 120 - SRT's default `SRTO_LATENCY` (the industry's standard fixed-latency
///           default); also about NDI's ~5-frame buffer.
///   - 200 - top of WebRTC's "interactive streaming" target band (100-200 ms).
///   - 400 - WebRTC's "buffer against glitches" / one-way target.
enum LatencyPreset: Int, CaseIterable, Identifiable {
    case lowest = 0      // WebRTC min=0 / OBS unbuffered - wired / strong 5 GHz
    case low    = 60     // under two frames at 30 fps: swallows ONE late packet, no more
    case normal = 120    // SRT default - the standard fixed-latency baseline
    case high   = 200    // WebRTC interactive upper bound - busy Wi-Fi
    case safe   = 400    // WebRTC buffer-against-glitches - hostile network

    var id: Int { rawValue }

    /// The rung's NAME, with no number in it.  The number is a separate column in the list and a
    /// separate span in the row, because five names of different lengths with numbers glued on the
    /// end read as five ragged sentences - and a column of figures is scannable in a way prose is not.
    var name: String {
        switch self {
        case .lowest: return "Unbuffered"
        case .low:    return "Low"
        case .normal: return "Normal"
        case .high:   return "High"
        case .safe:   return "Safe"
        }
    }

    /// The number alone.  The unit travels beside it, never inside the label: "Latency buffer (ms)"
    /// was a bracket doing the job a unit should do next to the figure it belongs to.
    var ms: String { String(rawValue) }

    /// Same value as seconds, for the receiver's PTS / jitter-buffer math.
    var seconds: Double { Double(rawValue) / 1000.0 }
}
