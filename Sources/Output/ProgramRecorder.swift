// ProgramRecorder.swift - records the PROGRAM to a .mov on this Mac.
//
// Ported from Airlive Studio's recorder (StudioRecorder), with Studio's settings replaced by one
// fixed rule: every camera reaches the Bridge in the same resolution and frame rate, so there is
// nothing to choose. HEVC at a fixed bitrate, the size of the first frame, video only (the
// Bridge carries no programme audio).
//
// What it records is exactly what the program outputs are handed - the same buffer the virtual
// camera, NDI and HDMI get, at the same moment (`BridgeModel.feedProgram`). Each frame is stamped
// with the time it actually left the Bridge, not with a tidy grid, so the file is also an honest
// measurement: its frame intervals ARE the Bridge's output cadence. That is the question it was
// built to answer - is a hitch seen in OBS already present when the frame leaves the Bridge?
//
// The whole AVAssetWriter lifecycle runs on ONE serial queue, gated by `phase` (Studio's lesson
// from the iPhone writer: a frame can never append after the session has finished).

import Foundation
import AVFoundation
import CoreVideo
import VideoToolbox
import Combine

final class ProgramRecorder: ObservableObject {

    /// Recording or not, for the footer. Main thread.
    @Published private(set) var isRecording = false
    /// When the current take started, for the elapsed-time readout. Main thread.
    @Published private(set) var startedAt: Date?
    /// Why the last take could not start or finish; cleared by the next start. Main thread.
    @Published private(set) var failure: String?
    /// Where takes are written. Persisted; default ~/Movies/Airlive Bridge.
    @Published var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: Self.folderKey) }
    }

    /// 1080p HEVC for a monitoring-grade archive and a timing check, not a post-production master.
    private static let bitrate = 16_000_000
    private static let folderKey = "bridge.record.folder"

    private enum Phase { case idle, starting, recording, finishing }
    private var phase: Phase = .idle                       // writerQueue-owned
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var size: (w: Int, h: Int) = (0, 0)
    /// Only for a frame that does not match the take's size (an AirPlay mirror or a capture card
    /// cut in mid-take): the encoder refuses a frame of another size, and losing the take over it
    /// would be far worse than one scaled source.
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var lastPTS: CMTime = .invalid
    private let writerQueue = DispatchQueue(label: "studio.airlive.bridge.recorder", qos: .userInitiated)

    /// Read on the receiver queue for every program frame, so it is a locked flag rather than the
    /// main-thread `isRecording`: idle, the tap costs a lock and a bool, not a queue hop per frame.
    private let wantsLock = NSLock()
    private var _wantsFrames = false
    private var wantsFrames: Bool {
        get { wantsLock.lock(); defer { wantsLock.unlock() }; return _wantsFrames }
        set { wantsLock.lock(); _wantsFrames = newValue; wantsLock.unlock() }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.folderKey)
        folder = saved.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Airlive Bridge", isDirectory: true)
    }

    // MARK: - Control (main thread)

    func toggle() { isRecording ? stop() : start() }

    /// Arm. The file is created on the first program frame, at that frame's real size, so a take
    /// that never received a frame leaves nothing behind.
    func start() {
        guard !isRecording else { return }
        failure = nil
        isRecording = true
        startedAt = Date()
        wantsFrames = true
        let dir = folder
        writerQueue.async { [weak self] in
            guard let self, self.phase == .idle else { return }
            self.pendingFolder = dir
            self.phase = .starting
            print("[Recorder] armed - waiting for the first program frame")
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        startedAt = nil
        wantsFrames = false
        writerQueue.async { [weak self] in self?.finish() }
    }

    /// Program frame tap. Called off main, on the receiver queue; costs one flag read when idle.
    func feed(_ buffer: CVPixelBuffer, timeNs: UInt64) {
        guard wantsFrames else { return }
        writerQueue.async { [weak self] in
            guard let self else { return }
            let pts = CMTime(value: CMTimeValue(timeNs), timescale: 1_000_000_000)
            switch self.phase {
            case .starting:
                self.build(from: buffer, firstPTS: pts)
                if self.phase == .recording { self.append(buffer, pts: pts) }
            case .recording:
                self.append(buffer, pts: pts)
            case .idle, .finishing:
                break
            }
        }
    }

    // MARK: - writerQueue only

    private var pendingFolder: URL?

    private func build(from buffer: CVPixelBuffer, firstPTS pts: CMTime) {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard let dir = pendingFolder else { return fail("no folder") }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return fail("Cannot write to \(dir.path): \(error.localizedDescription)")
        }
        let url = dir.appendingPathComponent(Self.filename())
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            return fail("Cannot create \(url.lastPathComponent): \(error.localizedDescription)")
        }
        // Fragmented, so a crash or a power cut mid-take still leaves a playable file.
        writer.movieFragmentInterval = CMTime(seconds: 4, preferredTimescale: 600)

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Self.bitrate],
        ])
        input.expectsMediaDataInRealTime = true
        // No source attributes: the program's own buffers go in as they are (the decoder's 4:2:0),
        // with no conversion on the normal path.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { return fail("The encoder refused a \(w)x\(h) track") }
        writer.add(input)
        guard writer.startWriting() else {
            return fail("Could not start writing: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: pts)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.outputURL = url
        self.size = (w, h)
        self.lastPTS = .invalid
        self.phase = .recording
        print("[Recorder] ▶︎ recording \(w)x\(h) HEVC @ \(Self.bitrate / 1_000_000) Mbps → \(url.path)")
    }

    private func append(_ buffer: CVPixelBuffer, pts: CMTime) {
        guard phase == .recording, let input, let adaptor else { return }
        // Timestamps must strictly increase; a repeat would fail the whole writer.
        if lastPTS.isValid, CMTimeCompare(pts, lastPTS) <= 0 { return }
        guard input.isReadyForMoreMediaData else {
            print("[Recorder] ⚠️ encoder busy - frame at \(pts.seconds) not written")
            return
        }
        guard let frame = fitted(buffer) else { return }
        if adaptor.append(frame, withPresentationTime: pts) {
            lastPTS = pts
        } else if let error = writer?.error {
            fail("Recording stopped: \(error.localizedDescription)")
        }
    }

    /// The buffer itself when it matches the take's size; otherwise a scaled copy.
    private func fitted(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(buffer) == size.w, CVPixelBufferGetHeight(buffer) == size.h { return buffer }
        if transfer == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
            transfer = session
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: size.w,
                kCVPixelBufferHeightKey as String: size.h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let transfer, let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out, VTPixelTransferSessionTransferImage(transfer, from: buffer, to: out) == noErr else {
            print("[Recorder] ⚠️ could not scale a \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) frame")
            return nil
        }
        return out
    }

    private func finish() {
        switch phase {
        case .recording:
            phase = .finishing
            guard let writer else { return reset() }
            input?.markAsFinished()
            let url = outputURL
            writer.finishWriting { [weak self] in
                if writer.status == .completed {
                    print("[Recorder] ⏹ saved \(url?.path ?? "?")")
                } else {
                    let reason = writer.error?.localizedDescription ?? "unknown error"
                    print("[Recorder] ❌ could not finish the file: \(reason)")
                    DispatchQueue.main.async { self?.failure = "Could not save the recording: \(reason)" }
                }
                self?.writerQueue.async { self?.reset() }
            }
        case .starting:
            reset()   // armed but no program frame ever arrived: nothing was written
        case .idle, .finishing:
            break
        }
    }

    /// Log loudly, drop back to idle, and tell the footer - a take that silently is not happening
    /// is the worst way for a recorder to fail.
    private func fail(_ reason: String) {
        print("[Recorder] ❌ \(reason)")
        writer?.cancelWriting()
        reset()
        wantsFrames = false
        DispatchQueue.main.async { [weak self] in
            self?.failure = reason
            self?.isRecording = false
            self?.startedAt = nil
        }
    }

    private func reset() {
        writer = nil
        input = nil
        adaptor = nil
        outputURL = nil
        pendingFolder = nil
        transfer.map { VTPixelTransferSessionInvalidate($0) }
        transfer = nil
        pool = nil
        lastPTS = .invalid
        phase = .idle
    }

    private static func filename() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // fixed format (QA1480), never "7-PM"
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Airlive_Bridge_\(f.string(from: Date())).mov"
    }
}
