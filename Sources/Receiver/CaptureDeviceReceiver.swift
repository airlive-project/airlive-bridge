// CaptureDeviceReceiver.swift — a channel fed by a UVC capture card (HDMI in).
//
// The thermally-best, dependency-free source: the iPhone outputs a CLEAN HDMI
// signal (wired, no wireless encode), a capture card digitises it, and we capture
// that card with AVFoundation — straight to a BGRA `CVPixelBuffer` that feeds the
// SAME `publishFrame` / mirror / program path as every other channel (multiview /
// CUT / NDI just work).  No network, no Bonjour, no back-channel — so the control
// methods are no-ops (HDMI can't carry tally/settings back; that's the Airlive
// app's job).

import Foundation
import AVFoundation
import CoreVideo

final class CaptureDeviceReceiver: NSObject, ChannelReceiver, AVCaptureVideoDataOutputSampleBufferDelegate {
    private weak var channel: BridgeChannel?
    private let deviceID: String?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "studio.airlive.bridge.capture.session")
    private let sampleQueue = DispatchQueue(label: "studio.airlive.bridge.capture.sample", qos: .userInteractive)
    private var running = false

    init(channel: BridgeChannel, deviceID: String?) {
        self.channel = channel
        self.deviceID = deviceID
        super.init()
    }

    // MARK: - ChannelReceiver

    func start() {
        sessionQueue.async { [weak self] in self?.requestAndBuild() }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.running = false
        }
        channel?.publishFrame(nil)                       // blank the mirrors
        let clear = { [weak self] in self?.channel?.isConnected = false; self?.channel?.latestFrame = nil }
        if Thread.isMainThread { clear() } else { DispatchQueue.main.async(execute: clear) }
    }

    // No back-channel / no Bonjour for a wired capture source.
    func send(_ msg: ControlMessage) {}
    func rename(_ newName: String) {}
    func updateOrder(_ index: Int) {}
    func updateDelay(_ preset: LatencyPreset) {}
    func updateAuth(require: Bool, password: String, disconnectNow: Bool) {}

    // MARK: - Session (queue-confined)

    private func requestAndBuild() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else { print("[Capture] camera/capture access denied — grant it in System Settings › Privacy › Camera"); return }
            self.sessionQueue.async { self.build() }
        }
    }

    private func build() {
        guard !running else { return }
        guard let device = CaptureDevices.discover().first(where: { deviceID == nil || $0.uniqueID == deviceID })
            ?? CaptureDevices.discover().first else {
            print("[Capture] no capture device found"); return
        }
        do {
            session.beginConfiguration()
            session.sessionPreset = .high            // capture card's native (1080p/4K) feed
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }

            let output = AVCaptureVideoDataOutput()
            // BGRA, IOSurface-backed → zero-copy into CALayer.contents (the mirror).
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            if session.canAddOutput(output) { session.addOutput(output) }

            session.commitConfiguration()
            session.startRunning()
            running = true
            print("[Capture] ✅ capturing \(device.localizedName)")
        } catch {
            print("[Capture] ❌ \(error)")
        }
    }

    // MARK: - Frames → mirror + program tap (mirrors BridgeChannelReceiver.present)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        channel?.publishFrame(buffer)                    // off-main mirror (zero-copy)
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let timeNs = UInt64(max(0, seconds) * 1_000_000_000)
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel else { return }
            if !channel.isConnected { channel.isConnected = true }
            channel.onProgramFrame?(buffer, timeNs)      // program-bus (NDI)
            if channel.latestFrame == nil { channel.latestFrame = buffer }   // flip the no-signal gate once
        }
    }
}
