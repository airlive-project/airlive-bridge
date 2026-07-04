// ProgramEncoder.swift — the program's H.264 encoder for everything that has no raw bitstream.
//
// LAW: the PROGRAM streams to EVERY output, no exceptions.  The passthrough outputs
// (OBS / RTSP / SRT) forward the camera's original H.264; when the program source has
// none — AirPlay mirror, HDMI/USB capture (decoded frames only), or an EMPTY/black
// program — this encoder turns the decoded frames into real H.264 so those outputs keep
// carrying the program instead of going dark.  Two feeds, one engine:
//   • BLACK     — the model's 30 fps black frame when nothing live is on program;
//   • TRANSCODE — the program channel's decoded frames (AirPlay / capture).
//
// Cost: one hardware VideoToolbox encode on the Mac — negligible next to the decode we
// already do; a static black frame compresses to a few kbit/s regardless of the ceiling.
//
// Wire shape matches the camera exactly (see H264NAL.swift): format payload =
// `[2-byte BE len][SPS][2-byte BE len][PPS]`, samples = AVCC.  Format is re-emitted
// before every IDR (~1 s cadence) so a late-joining receiver locks on within a second.
// The session is (re)built lazily to the INCOMING frame's dimensions, so a portrait
// AirPlay mirror is encoded at its native size — never stretched into 16:9.

import Foundation
import CoreVideo
import VideoToolbox
import os.lock

final class ProgramEncoder {

    /// Both fire on MAIN (same contract as the camera's onProgramFormat/onProgramSample hop).
    var onFormat: ((Data) -> Void)?
    var onSample: ((Data, Int64) -> Void)?   // (AVCC payload, pts µs)

    /// Serializes start/stop/encode (MAIN) against the VT output callback (VT's own thread,
    /// Default QoS).  An unfair lock, NOT NSLock: main is user-interactive, so waiting on a
    /// default-QoS holder is a priority inversion — os_unfair_lock donates priority across it
    /// (Xcode's Thread Performance Checker flagged exactly this on the NSLock version).
    private struct State {
        var stopped = true
        var session: VTCompressionSession?
        var sessionW: Int32 = 0
        var sessionH: Int32 = 0
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    // ~1 s GOP at 30 fps: an IDR + fresh SPS/PPS so OBS/VLC joining mid-stream sync fast.
    private static let keyFrameInterval = 30
    /// Real-content ceiling (the wire's 1080p ballpark); black undershoots it by orders
    /// of magnitude, so one number serves both feeds.
    private static let averageBitRate = 8_000_000

    func start() {
        state.withLockUnchecked { $0.stopped = false }
        // The session itself is built lazily by encode() — it must match the frame size.
    }

    func stop() {
        let s = state.withLockUnchecked { st -> VTCompressionSession? in
            st.stopped = true
            let s = st.session
            st.session = nil
            st.sessionW = 0; st.sessionH = 0
            return s
        }
        if let s {
            VTCompressionSessionInvalidate(s)   // drops in-flight frames; no further callbacks
        }
    }

    /// Encode one frame (MAIN thread — the model's black feeder or the program frame tap).
    /// The session is created / recreated to the frame's own dimensions, so a source
    /// switch (1080p black → portrait mirror) re-negotiates cleanly: fresh session ⇒
    /// first frame is an IDR with new SPS/PPS ⇒ receivers re-sync.
    func encode(_ pixelBuffer: CVPixelBuffer, timeNs: UInt64) {
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        guard w > 0, h > 0 else { return }

        var session = state.withLockUnchecked { st -> VTCompressionSession? in
            guard !st.stopped else { return nil }
            return (st.sessionW == w && st.sessionH == h) ? st.session : nil
        }
        if session == nil {
            // Not running, or the frame size changed — (re)build to this frame's dims.
            let stopped = state.withLockUnchecked { $0.stopped }
            guard !stopped, let fresh = makeSession(width: w, height: h) else { return }
            let old = state.withLockUnchecked { st -> VTCompressionSession? in
                guard !st.stopped else { return fresh }   // stopped mid-build — discard the new one
                let old = st.session
                st.session = fresh; st.sessionW = w; st.sessionH = h
                return old
            }
            if old === fresh { VTCompressionSessionInvalidate(fresh); return }
            if let old { VTCompressionSessionInvalidate(old) }
            session = fresh
        }
        guard let session else { return }

        let pts = CMTime(value: CMTimeValue(timeNs), timescale: 1_000_000_000)
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let self, let sb = sampleBuffer else { return }
            self.emit(sb)
        }
    }

    private func makeSession(width: Int32, height: Int32) -> VTCompressionSession? {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let session = s else {
            print("[ProgramEncoder] ❌ VTCompressionSessionCreate \(width)×\(height) failed (\(status))")
            return nil
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: Self.keyFrameInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)   // no B-frames — same as the camera's wire
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: Self.averageBitRate as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    // MARK: - VT output → wire payloads (VT callback thread)

    private func emit(_ sample: CMSampleBuffer) {
        let dead = state.withLockUnchecked { $0.stopped }
        guard !dead, CMSampleBufferGetNumSamples(sample) > 0 else { return }

        // Keyframe? (attachment absent or NotSync == false ⇒ sync sample)
        var isKeyframe = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = atts.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        // Re-emit SPS/PPS before every IDR — the camera does the same, and it's what lets a
        // receiver that connected mid-stream start decoding at the next keyframe.
        if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sample),
           let payload = Self.formatPayload(from: fmt) {
            DispatchQueue.main.async { [weak self] in self?.onFormat?(payload) }
        }

        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let p = pointer, length > 0 else { return }
        let avcc = Data(bytes: p, count: length)   // VT already emits AVCC (4-byte BE lengths)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let ptsMicros = Int64(CMTimeGetSeconds(pts) * 1_000_000)
        DispatchQueue.main.async { [weak self] in self?.onSample?(avcc, ptsMicros) }
    }

    /// `[2-byte BE len][SPS][2-byte BE len][PPS]` — the ARLV formatDescription payload.
    private static func formatPayload(from fmt: CMFormatDescription) -> Data? {
        var out = Data()
        for index in 0..<2 {   // SPS, PPS
            var setPointer: UnsafePointer<UInt8>?
            var setSize = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: index, parameterSetPointerOut: &setPointer,
                parameterSetSizeOut: &setSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let sp = setPointer, setSize > 0, setSize <= Int(UInt16.max) else { return nil }
            out.append(UInt8(setSize >> 8)); out.append(UInt8(setSize & 0xFF))
            out.append(sp, count: setSize)
        }
        return out
    }
}
