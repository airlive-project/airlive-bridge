// CameraLadders.swift - the values each camera setting can take, for every Bridge control surface.
//
// The on-screen camera panel and the Stream Deck dials must land on the SAME values, so the ladders
// live here once instead of in either. They mirror the phone's own pickers
// (AirliveCameraApp/VerticalParamPanel): standard cinema stops filtered by the capability ranges the
// camera already sends, so the operator only ever lands on a value the sensor offers - no invented
// `1/268` - and no new wire field is needed.

import Foundation

struct CameraLadders {
    private let caps: DeviceCapabilities
    private let fps: Double

    /// Device-read ranges for THIS camera. Falls back to the wire defaults when an older camera sends
    /// none, or before the first snapshot.
    init(_ snapshot: StateSnapshot?) {
        caps = snapshot?.capabilities ?? DeviceCapabilities()
        fps = Double(snapshot?.fps ?? 30)
    }

    private static let isoCinema: [Double] = [
        32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320,
        400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400
    ]
    /// ISO 1/3-stop stops within [isoMin, isoMax], KEEPING the true endpoints so a max that falls
    /// between cinema stops stays reachable (matches ISOPanel.stops).
    var iso: [Double] {
        let lo = Double(caps.isoMin).rounded(), hi = Double(caps.isoMax).rounded()
        guard hi > lo + 0.5 else { return [lo] }
        var s = Self.isoCinema.filter { $0 > lo + 0.5 && $0 < hi - 0.5 }
        s.insert(lo, at: 0); s.append(hi)
        return s
    }

    private static let shutterCinema: [Double] = [
        24, 25, 30, 48, 50, 60, 100, 120, 180, 250, 500, 1000, 2000, 3000, 4000, 6000, 8000
    ]
    /// Shutter denominators = cinema stops ∪ fps-relative quick picks (1/fps, 1/2fps, 1/4fps, 1/50),
    /// clamped to [max(minDenom, fps), maxDenom] - the slowest shutter can't exceed one frame, so the
    /// floor is the current fps (matches ShutterPanel.stops).
    var shutter: [Double] {
        let lo = max(Double(caps.shutterMinDenom), fps)
        let hi = Double(caps.shutterMaxDenom)
        guard hi > lo else { return [lo] }
        let quick: [Double] = [fps, 50, fps * 2, fps * 4]
        let all = Set(Self.shutterCinema + quick).filter { $0 >= lo - 0.5 && $0 <= hi + 0.5 }
        return all.isEmpty ? [lo] : all.sorted()
    }

    /// WB temperature - 100 K stops across the device envelope (matches WBPanel.stops).
    var temperature: [Double] {
        let lo = Double(caps.wbTempMin), hi = Double(caps.wbTempMax)
        guard hi > lo else { return [lo] }
        return Array(stride(from: lo, through: hi, by: 100))
    }

    /// Tint - ±1 stops across the device envelope (matches TintPanel.stops).
    var tint: [Double] {
        let lo = Double(caps.wbTintMin), hi = Double(caps.wbTintMax)
        guard hi > lo else { return [lo] }
        return Array(stride(from: lo, through: hi, by: 1))
    }

    /// Focus - 0.000…1.000 in 0.01 steps (101 stops, matches FocusPanel.stops).
    static let focus: [Double] = Array(stride(from: 0.0, through: 1.0, by: 0.01))
    var focus: [Double] { Self.focus }

    /// Zoom - up to THIS device's real max (`caps.zoomMax` = `videoMaxZoomFactor`); 0 from an older
    /// camera → the 1–10 fallback.  0.1× steps to 10×, 0.5× above (zoom is CONTINUOUS on the phone -
    /// any value is valid; the coarser high-end step just keeps a 100×+ ladder scrubbable).
    var zoom: [Double] {
        let maxZ = caps.zoomMax > 1 ? Double(caps.zoomMax) : 10.0
        var out = Array(stride(from: 1.0, through: Swift.min(maxZ, 10.0), by: 0.1))
        if maxZ > 10 { out += Array(stride(from: 10.5, through: maxZ, by: 0.5)) }
        return out
    }

    /// EV compensation - 0.1-EV steps across the device's bias range (the panel's EV drag step).
    var exposureBias: [Double] {
        let lo = Double(min(caps.evBiasMin, caps.evBiasMax)), hi = Double(max(caps.evBiasMin, caps.evBiasMax))
        guard hi > lo else { return [lo] }
        // Built from integer tenths: striding by 0.1 accumulates float error, and the ends would
        // land on -1.9999 instead of -2.0.
        return (Int((lo * 10).rounded()) ... Int((hi * 10).rounded())).map { Double($0) / 10 }
    }
}
