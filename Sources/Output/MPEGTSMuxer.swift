// MPEGTSMuxer.swift — wrap the program's H.264 in MPEG-TS for SRT (no re-encode).
//
// SRT carries an MPEG-TS payload by convention, so a generic SRT receiver
// (ffmpeg, OBS media source, vMix, a cloud ingest) can demux it.  We take the
// camera's ORIGINAL H.264 access units (the same raw taps the OBS relay / RTSP use)
// and packetize them into 188-byte TS packets — PAT + PMT + PES with PCR.  Zero
// decode, zero encode.
//
// Single program, single video elementary stream (no audio):
//   PAT  on PID 0x0000  →  program 1  →  PMT PID 0x1000
//   PMT  on PID 0x1000  →  PCR_PID 0x0100, stream_type 0x1B (H.264) on PID 0x0100
//   PES  on PID 0x0100  →  one PES per access unit, Annex-B ES (start-code NALs),
//                          SPS/PPS + AUD prepended on keyframes so a mid-join
//                          receiver can decode.
//
// MUST be validated against a real demuxer (ffprobe / VLC) once libsrt is present —
// TS bit-twiddling can't be exercised from a unit build.

import Foundation

final class MPEGTSMuxer {
    var sps: [UInt8]?
    var pps: [UInt8]?

    private let pmtPID: UInt16 = 0x1000
    private let videoPID: UInt16 = 0x0100
    private var ccPAT: UInt8 = 0
    private var ccPMT: UInt8 = 0
    private var ccVideo: UInt8 = 0
    /// Resend PAT/PMT roughly every 100 ms (90 kHz units) so receivers joining
    /// mid-stream lock on quickly without waiting for the next keyframe.
    private var lastPSI90k: UInt32 = 0
    private let psiInterval90k: UInt32 = 9_000

    /// One access unit → TS bytes (PAT/PMT prepended periodically).
    func mux(nals: [[UInt8]], pts90k: UInt32, isKeyframe: Bool) -> Data {
        var ts = Data()
        if isKeyframe || pts90k &- lastPSI90k >= psiInterval90k {
            ts.append(section(pid: 0x0000, table: patSection(), cc: &ccPAT))
            ts.append(section(pid: pmtPID, table: pmtSection(), cc: &ccPMT))
            lastPSI90k = pts90k
        }

        // Annex-B elementary stream: AUD, then SPS/PPS on keyframes, then the NALs.
        var es: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0]   // access unit delimiter
        if isKeyframe, let sps, let pps {
            es += [0, 0, 0, 1] + sps
            es += [0, 0, 0, 1] + pps
        }
        for nal in nals { es += [0, 0, 0, 1] + nal }

        ts.append(pes(es: es, pts90k: pts90k, isKeyframe: isKeyframe))
        return ts
    }

    // MARK: - PSI sections (PAT / PMT) carried in a single TS packet each

    private func patSection() -> [UInt8] {
        // table_id 0x00, program 1 → pmtPID
        var s: [UInt8] = [0x00]
        let body: [UInt8] = [
            0x00, 0x01,                      // transport_stream_id
            0xC1,                            // version 0, current_next 1
            0x00, 0x00,                      // section_number, last_section_number
            0x00, 0x01,                      // program_number 1
            UInt8(0xE0 | (pmtPID >> 8)), UInt8(pmtPID & 0xFF),  // reserved | PMT PID
        ]
        let len = body.count + 4             // + CRC32
        s.append(UInt8(0xB0 | (len >> 8)))   // section_syntax_indicator | len hi
        s.append(UInt8(len & 0xFF))
        s.append(contentsOf: body)
        appendCRC32(&s)
        return s
    }

    private func pmtSection() -> [UInt8] {
        var s: [UInt8] = [0x02]              // table_id PMT
        let body: [UInt8] = [
            0x00, 0x01,                      // program_number 1
            0xC1, 0x00, 0x00,                // version/current, section/last
            UInt8(0xE0 | (videoPID >> 8)), UInt8(videoPID & 0xFF),  // PCR_PID
            0xF0, 0x00,                      // program_info_length 0
            0x1B,                            // stream_type H.264
            UInt8(0xE0 | (videoPID >> 8)), UInt8(videoPID & 0xFF),  // elementary PID
            0xF0, 0x00,                      // ES_info_length 0
        ]
        let len = body.count + 4
        s.append(UInt8(0xB0 | (len >> 8)))
        s.append(UInt8(len & 0xFF))
        s.append(contentsOf: body)
        appendCRC32(&s)
        return s
    }

    /// A PSI section fits in one TS packet: pointer_field(0) + section, payload-only,
    /// stuffed to 188.
    private func section(pid: UInt16, table: [UInt8], cc: inout UInt8) -> Data {
        var payload: [UInt8] = [0x00]        // pointer_field
        payload += table
        var pkt = [UInt8](repeating: 0xFF, count: 188)
        pkt[0] = 0x47
        pkt[1] = UInt8(0x40 | (pid >> 8))    // PUSI | PID hi
        pkt[2] = UInt8(pid & 0xFF)
        pkt[3] = 0x10 | (cc & 0x0F)          // payload only | CC
        cc = cc &+ 1
        for (i, b) in payload.enumerated() where 4 + i < 188 { pkt[4 + i] = b }
        return Data(pkt)
    }

    // MARK: - PES over TS (video PID, PCR on the first packet of a keyframe AU)

    private func pes(es: [UInt8], pts90k: UInt32, isKeyframe: Bool) -> Data {
        var pesBytes: [UInt8] = [
            0x00, 0x00, 0x01, 0xE0,          // start code + stream_id (video)
            0x00, 0x00,                      // PES_packet_length 0 (unbounded video)
            0x80,                            // marker bits '10'
            0x80,                            // PTS_DTS_flags = '10' (PTS only)
            0x05,                            // PES_header_data_length
        ]
        pesBytes += encodePTS(pts90k)
        pesBytes += es

        var out = Data()
        var offset = 0
        var first = true
        while offset < pesBytes.count {
            var pkt = [UInt8](repeating: 0xFF, count: 188)
            pkt[0] = 0x47
            pkt[1] = UInt8((first ? 0x40 : 0x00) | (videoPID >> 8))   // PUSI on first
            pkt[2] = UInt8(videoPID & 0xFF)

            // Adaptation field on the first packet (carry PCR + random-access on
            // keyframes); on the last packet only if stuffing is needed to fill 188.
            let remaining = pesBytes.count - offset
            var adaptation: [UInt8] = []
            if first {
                adaptation = adaptationField(pcr90k: pts90k, randomAccess: isKeyframe, stuffTo: nil)
            }
            let headerLen = 4 + adaptation.count
            let space = 188 - headerLen
            if remaining < space {
                // Last packet: grow the adaptation field to stuff the gap.
                let stuff = space - remaining
                adaptation = first
                    ? adaptationField(pcr90k: pts90k, randomAccess: isKeyframe, stuffTo: adaptation.count + stuff)
                    : adaptationField(pcr90k: nil, randomAccess: false, stuffTo: stuff)
            }
            let afc: UInt8 = adaptation.isEmpty ? 0x10 : 0x30        // payload / adapt+payload
            pkt[3] = afc | (ccVideo & 0x0F)
            ccVideo = ccVideo &+ 1

            var i = 4
            for b in adaptation where i < 188 { pkt[i] = b; i += 1 }
            let take = min(188 - i, pesBytes.count - offset)
            for k in 0 ..< take { pkt[i + k] = pesBytes[offset + k] }
            offset += take
            out.append(Data(pkt))
            first = false
        }
        return out
    }

    /// Adaptation field bytes (length-prefixed). `stuffTo` = desired TOTAL field
    /// length INCLUDING the length byte (nil = minimal).
    private func adaptationField(pcr90k: UInt32?, randomAccess: Bool, stuffTo: Int?) -> [UInt8] {
        var flags: UInt8 = 0
        if randomAccess { flags |= 0x40 }
        var field: [UInt8] = [flags]
        if let pcr90k {
            field[0] |= 0x10                 // PCR_flag
            let base = UInt64(pcr90k)        // 33-bit base @90kHz, extension 0
            field.append(UInt8((base >> 25) & 0xFF))
            field.append(UInt8((base >> 17) & 0xFF))
            field.append(UInt8((base >> 9) & 0xFF))
            field.append(UInt8((base >> 1) & 0xFF))
            field.append(UInt8(((base & 0x1) << 7) | 0x7E))   // reserved bits + ext hi
            field.append(0x00)                                // ext lo
        }
        // field is now [flags][optional PCR]; prepend the length byte.
        var afLen = field.count
        if let stuffTo {
            let target = max(stuffTo, afLen + 1)             // include length byte
            let stuff = target - 1 - field.count             // bytes of 0xFF stuffing
            if stuff > 0 { field += [UInt8](repeating: 0xFF, count: stuff) }
            afLen = field.count
        }
        return [UInt8(afLen)] + field
    }

    private func encodePTS(_ pts: UInt32) -> [UInt8] {
        let p = UInt64(pts)                  // 33-bit value (top bit 0 for our range)
        return [
            UInt8(0x21 | ((p >> 29) & 0x0E)),            // '0010' PTS[32..30] '1'
            UInt8((p >> 22) & 0xFF),                     // PTS[29..22]
            UInt8(0x01 | ((p >> 14) & 0xFE)),            // PTS[21..15] '1'
            UInt8((p >> 7) & 0xFF),                      // PTS[14..7]
            UInt8(0x01 | ((p << 1) & 0xFE)),             // PTS[6..0] '1'
        ]
    }

    // MARK: - MPEG-2 systems CRC32

    private func appendCRC32(_ section: inout [UInt8]) {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in section {
            crc ^= UInt32(b) << 24
            for _ in 0 ..< 8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : (crc << 1)
            }
        }
        section.append(UInt8((crc >> 24) & 0xFF))
        section.append(UInt8((crc >> 16) & 0xFF))
        section.append(UInt8((crc >> 8) & 0xFF))
        section.append(UInt8(crc & 0xFF))
    }
}
