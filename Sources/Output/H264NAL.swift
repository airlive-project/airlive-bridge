// H264NAL.swift — H.264 byte-stream helpers shared by the remux outputs.
//
// The program is forwarded as the camera's ORIGINAL H.264 (no re-encode): samples
// arrive AVCC-framed (4-byte big-endian length per NAL) and the format payload is
// the wire's `[2-byte len][SPS][2-byte len][PPS]`.  RTSP (RTP/RFC 6184) and SRT
// (MPEG-TS) both need the raw NAL units + the parameter sets, so the parsing lives
// here once.
//
// Everything works on `[UInt8]` (a fresh copy of the payload) to avoid Data-slice
// index pitfalls.

import Foundation

enum H264NAL {
    /// Split an AVCC sample (`[4-byte BE len][NAL]…`) into raw NAL units (each NAL
    /// includes its 1-byte header).  Stops cleanly at the first truncated record.
    static func nalUnits(fromAVCC data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var out: [[UInt8]] = []
        var i = 0
        while i + 4 <= bytes.count {
            let len = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16)
                    | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            let start = i + 4
            guard len > 0, start + len <= bytes.count else { break }
            out.append(Array(bytes[start ..< start + len]))
            i = start + len
        }
        return out
    }

    /// Parse the format payload (`[2-byte BE len][param set]…`) into the SPS + PPS
    /// (the first two parameter sets).  Returns nil if fewer than two are present.
    static func parameterSets(fromFormat data: Data) -> (sps: [UInt8], pps: [UInt8])? {
        let bytes = [UInt8](data)
        var sets: [[UInt8]] = []
        var i = 0
        while i + 2 <= bytes.count {
            let len = (Int(bytes[i]) << 8) | Int(bytes[i + 1])
            let start = i + 2
            guard len > 0, start + len <= bytes.count else { break }
            sets.append(Array(bytes[start ..< start + len]))
            i = start + len
        }
        guard sets.count >= 2 else { return nil }
        return (sets[0], sets[1])
    }

    /// The NAL type (low 5 bits of the header byte): 5 = IDR, 7 = SPS, 8 = PPS.
    static func type(of nal: [UInt8]) -> UInt8 { (nal.first ?? 0) & 0x1F }

    /// Convert microseconds to a 90 kHz RTP/PCR timestamp (90000/1e6 = 9/100).
    static func ts90kHz(microseconds: Int64) -> UInt32 {
        UInt32(truncatingIfNeeded: microseconds * 9 / 100)
    }
}
