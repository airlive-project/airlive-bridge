// ProgramRecorder.swift - records the PROGRAM to a .mov on this Mac.
//
// Ported from Airlive Studio's recorder (StudioRecorder), with Studio's settings replaced by one
// fixed rule: every camera reaches the Bridge in the same resolution and frame rate, so there is
// nothing to choose. HEVC at a fixed bitrate, the size of the first frame, video only (the
// Bridge carries no programme audio).
//
// Made for editing (operator, 2026-10-07: a recording that will not go into an editor is not
// shippable), so it works the way OBS's does:
//   - CONSTANT frame rate. Every program frame goes into the 1/30 s slot of the moment it left the
//     Bridge; timestamps are exactly n/30, so editors read it as plain 30 fps footage. A slot no
//     frame reached (the network held one back) repeats the previous frame; a second frame in a
//     slot (a late frame landing next to an on-time one, or the phone's and the Mac's clocks
//     drifting half a frame apart) is dropped. After more than a second with no frame at all
//     (Mac asleep, source gone) the file picks up where it stopped instead of filling the gap.
//     NOT a free-running 30 Hz clock sampling the newest frame: two 30 Hz clocks beat against each
//     other, and the file stuttered in runs wherever their ticks lined up (measured 2026-10-07:
//     13 repeats in 324 frames, six of them within one second).
//   - SEPARATE from the outputs. The program path only puts the frame on a shelf (a lock and an
//     append); the recorder picks it up on its own queue. Nothing the encoder or the disk does
//     can reach the virtual camera, NDI or HDMI.
//   - Tagged Rec.709 in the FILE only - the label a camera wire and OBS's own files carry. The
//     program buffers and every output are untouched; the pixels are not converted.
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
    /// Counts takes on main, so a late failure report from the previous take never stops this one.
    private var take = 0
    /// Where takes are written. Persisted; default ~/Movies/Airlive Bridge.
    @Published var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: Self.folderKey) }
    }

    /// 1080p HEVC: three times the camera wire's 5 Mbps, so re-encoding loses next to nothing.
    private static let bitrate = 16_000_000
    /// The file's constant rate: the rate every Airlive camera streams at (the live wire is
    /// always 30 - CLAUDE.md fps policy).
    private static let fps: Int32 = 30
    private static let folderKey = "bridge.record.folder"

    private enum Phase { case idle, starting, recording, finishing }
    private var phase: Phase = .idle                       // writerQueue-owned
    /// The take on writerQueue, and a Start pressed while the previous file was still being
    /// finalised - armed the moment it is (writerQueue).
    private var currentTake = 0
    private var queuedStart: (folder: URL, take: Int)?
    /// Signalled when the recorder is back at rest - the quit waits on it (writerQueue).
    private var idleWaiter: DispatchSemaphore?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var size: (w: Int, h: Int) = (0, 0)
    /// Picks frames up from the shelf (writerQueue). Its rate only sets how often; WHERE each
    /// lands in the file comes from the frame's own release time.
    private var pickupTimer: DispatchSourceTimer?
    /// Pickup runs twice a frame period, so a frame waits at most half a frame on the shelf.
    private static let pickupInterval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000 / Int64(fps) / 2))
    /// The longest gap filled with repeats: one second of frames. Longer is a pause, not a hiccup.
    private static let maxFilledGapSlots = Int64(fps)
    /// The take's time zero (the first frame's release) and the next free slot.
    private var origin: CFTimeInterval = 0
    private var nextSlot: Int64 = 0
    private var stats = (written: 0, repeated: 0, dropped: 0, skipped: 0)
    /// The last frame written: what an empty slot repeats.
    private var lastWritten: CVPixelBuffer?
    /// Only for a frame that does not match the take's size (an AirPlay mirror or a capture card
    /// cut in mid-take): the encoder refuses a frame of another size, and losing the take over it
    /// would be far worse than one scaled source.
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private let writerQueue = DispatchQueue(label: "studio.airlive.bridge.recorder", qos: .userInitiated)

    /// The shelf: program frames with the moment they left the Bridge, put there by the program
    /// path and picked up by the recorder. Locked rather than queue-hopped, so the program path
    /// pays a lock and an append per frame while recording and a lock and a bool when not - never
    /// a wait on the recorder. Bounded: a stalled recorder loses its own oldest frames, never
    /// holds the decoder's buffers hostage.
    private let shelfLock = NSLock()
    private var wantsFrames = false                         // shelfLock
    private var shelf: [(buffer: CVPixelBuffer, time: CFTimeInterval)] = []   // shelfLock
    private static let shelfLimit = 8
    /// Turning frames off also empties the shelf, so a stopped take lets go of its frames.
    private func setWantsFrames(_ on: Bool) {
        shelfLock.lock()
        wantsFrames = on
        if !on { shelf.removeAll() }
        shelfLock.unlock()
    }
    private func drainShelf() -> [(buffer: CVPixelBuffer, time: CFTimeInterval)] {
        shelfLock.lock(); defer { shelfLock.unlock() }
        let frames = shelf
        shelf.removeAll(keepingCapacity: true)
        return frames
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
        take += 1
        let take = self.take
        setWantsFrames(true)
        let dir = folder
        writerQueue.async { [weak self] in
            guard let self else { return }
            switch self.phase {
            case .idle:
                self.arm(dir, take: take)
            case .finishing:
                // Stop, then Start before the last file was written out. Silently doing nothing
                // here once showed REC with no file behind it (review, 2026-10-07).
                self.queuedStart = (dir, take)
                print("[Recorder] previous take still being saved - this one starts as soon as it is")
            case .starting, .recording:
                break   // a second Start is refused on main by `isRecording`
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        startedAt = nil
        setWantsFrames(false)
        writerQueue.async { [weak self] in self?.finish() }
    }

    /// The app is quitting: end the take and wait until its file is closed, so it opens in an
    /// editor. A file left unfinished has no proper end and some editors refuse it. Bounded, so
    /// a writer that never answers cannot hold the quit forever. Main thread.
    func finishBeforeQuit(timeout: TimeInterval = 3) {
        stop()
        let done = DispatchSemaphore(value: 0)
        writerQueue.async { [weak self] in
            guard let self, self.phase != .idle else { done.signal(); return }
            self.idleWaiter = done   // finish() is already queued ahead of this
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            print("[Recorder] ⚠️ quit: the file was not closed within \(Int(timeout)) s")
        }
    }

    private func arm(_ dir: URL, take: Int) {
        pendingFolder = dir
        currentTake = take
        origin = 0
        nextSlot = 0
        stats = (0, 0, 0, 0)
        lastWritten = nil
        // Frames shelved while the previous take was still being saved are stale; this take
        // starts with the next one.
        _ = drainShelf()
        phase = .starting
        startPickup()
        print("[Recorder] armed - waiting for the first program frame")
    }

    /// Program frame tap, on the program path's queue: shelve the frame and return. Timed here,
    /// with one clock for every source (camera frames and no-signal frames carry timestamps from
    /// different clocks), and inside the lock, so the shelf stays in time order with two feeders.
    func feed(_ buffer: CVPixelBuffer) {
        shelfLock.lock()
        if wantsFrames {
            if shelf.count >= Self.shelfLimit { shelf.removeFirst() }
            shelf.append((buffer, CACurrentMediaTime()))
        }
        shelfLock.unlock()
    }

    // MARK: - writerQueue only

    private var pendingFolder: URL?

    private func startPickup() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: writerQueue)
        t.schedule(deadline: .now() + Self.pickupInterval, repeating: Self.pickupInterval,
                   leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.pickUp() }
        t.resume()
        pickupTimer = t
    }

    private func stopPickup() {
        pickupTimer?.cancel()
        pickupTimer = nil
    }

    /// Place every shelved frame in its slot: fill skipped slots with the previous frame, drop a
    /// frame whose slot is already taken.
    private func pickUp() {
        for (frame, time) in drainShelf() {
            if phase == .starting {
                build(from: frame)
                origin = time
            }
            guard phase == .recording else { return }
            var slot = Int64(((time - origin) * Double(Self.fps)).rounded())
            if slot < nextSlot { stats.dropped += 1; continue }
            if slot - nextSlot > Self.maxFilledGapSlots {
                // More than a second without a single frame: not a network hiccup but a pause
                // (Mac asleep, a debugger, the program gone). Thousands of repeats would only
                // swamp the encoder; continue from here instead.
                print("[Recorder] no program frame for \(slot - nextSlot) frames - continuing without filling the gap")
                origin += Double(slot - nextSlot) / Double(Self.fps)
                slot = nextSlot
            }
            if let previous = lastWritten {
                while nextSlot < slot {                // a slot no frame reached: hold the last one
                    if append(previous, slot: nextSlot) { stats.repeated += 1 }
                    guard phase == .recording else { return }
                    nextSlot += 1
                }
            }
            append(frame, slot: slot)
            guard phase == .recording else { return }   // a failed append has already reset
            lastWritten = frame
            nextSlot = slot + 1
        }
    }

    private func build(from buffer: CVPixelBuffer) {
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
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.bitrate,
                AVVideoExpectedSourceFrameRateKey: Self.fps,
            ],
            // A label in the file, so every editor reads the colours the same way.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = CMTimeScale(Self.fps)   // the track counts in whole frames
        // No source attributes: the program's own buffers go in as they are (the decoder's 4:2:0),
        // with no conversion on the normal path.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { return fail("The encoder refused a \(w)x\(h) track") }
        writer.add(input)
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: url)   // no empty file left behind
            return fail("Could not start writing: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.outputURL = url
        self.size = (w, h)
        self.phase = .recording
        print("[Recorder] ▶︎ recording \(w)x\(h) HEVC @ \(Self.bitrate / 1_000_000) Mbps, constant \(Self.fps) fps, Rec.709 → \(url.path)")
    }

    /// True when the frame went into the file.
    @discardableResult
    private func append(_ buffer: CVPixelBuffer, slot: Int64) -> Bool {
        guard phase == .recording, let input, let adaptor else { return false }
        // A writer can die between appends (disk full, recording drive unplugged). Checked on
        // every frame, so REC goes out at once instead of glowing over a file nothing reaches.
        if let writer, writer.status == .failed {
            fail("Recording stopped: \(writer.error?.localizedDescription ?? "the file could not be written")")
            return false
        }
        guard input.isReadyForMoreMediaData else {
            stats.skipped += 1
            print("[Recorder] ⚠️ encoder busy - frame \(slot) not written")
            return false
        }
        guard let frame = fitted(buffer) else { return false }
        if adaptor.append(frame, withPresentationTime: CMTime(value: slot, timescale: Self.fps)) {
            stats.written += 1
            return true
        }
        if let error = writer?.error { fail("Recording stopped: \(error.localizedDescription)") }
        return false
    }

    /// The buffer itself when it matches the take's size; otherwise a scaled copy.
    private func fitted(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(buffer) == size.w, CVPixelBufferGetHeight(buffer) == size.h { return buffer }
        if transfer == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
            // Bars, not a stretch: a portrait mirror or a 4:3 capture cut into a 16:9 take keeps
            // its shape, as it does on the virtual camera.
            if let session {
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode,
                                     value: kVTScalingMode_Letterbox)
            }
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
        stopPickup()
        lastWritten = nil
        switch phase {
        case .recording:
            guard let writer else { return reset() }
            // The writer can fail on its own between appends (disk full); finishing a failed
            // writer throws, so report it instead.
            guard writer.status == .writing else {
                return fail("Recording stopped: \(writer.error?.localizedDescription ?? "the file could not be written")")
            }
            phase = .finishing
            print("[Recorder] \(stats.written) frames written at \(Self.fps) fps - \(stats.repeated) repeated (no frame for that slot), \(stats.dropped) dropped (two in one slot), \(stats.skipped) skipped (encoder busy)")
            // The end of the file is the end of the last frame, not its start.
            writer.endSession(atSourceTime: CMTime(value: nextSlot, timescale: Self.fps))
            input?.markAsFinished()
            let url = outputURL
            let finishingTake = currentTake
            writer.finishWriting { [weak self] in
                if writer.status == .completed {
                    print("[Recorder] ⏹ saved \(url?.path ?? "?")")
                } else {
                    let reason = writer.error?.localizedDescription ?? "unknown error"
                    print("[Recorder] ❌ could not finish the file: \(reason)")
                    DispatchQueue.main.async {
                        // Not over a take started meanwhile (a queued Start can already be running).
                        guard let self, self.take == finishingTake else { return }
                        self.failure = "Could not save the recording: \(reason)"
                    }
                }
                self?.writerQueue.async { self?.reset() }
            }
        case .starting:
            reset()   // armed but no program frame ever arrived: nothing was written
        case .finishing:
            queuedStart = nil   // Stop pressed again before the queued take began: drop it
        case .idle:
            break
        }
    }

    /// Log loudly, drop back to idle, and tell the footer - a take that silently is not happening
    /// is the worst way for a recorder to fail.
    private func fail(_ reason: String) {
        print("[Recorder] ❌ \(reason)")
        stopPickup()
        writer?.cancelWriting()
        let failedTake = currentTake
        reset()
        DispatchQueue.main.async { [weak self] in
            // Only the take that failed reports - never over one the operator started meanwhile.
            // Reported even after Stop (a writer that died before it could finish).
            guard let self, self.take == failedTake else { return }
            self.failure = reason
            guard self.isRecording else { return }
            self.isRecording = false
            self.startedAt = nil
            self.setWantsFrames(false)
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
        lastWritten = nil
        phase = .idle
        if let queued = queuedStart {          // a Start that came while this file was saving
            queuedStart = nil
            arm(queued.folder, take: queued.take)
        } else {
            idleWaiter?.signal()
            idleWaiter = nil
        }
    }

    private static func filename() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // fixed format (QA1480), never "7-PM"
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Airlive_Bridge_\(f.string(from: Date())).mov"
    }
}
