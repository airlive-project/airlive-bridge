// CaptureDevices.swift — enumerate UVC video-capture devices (HDMI capture cards).
//
// An iPhone's clean HDMI out reaches the Mac through an HDMI capture card, which
// presents as a standard UVC AVCaptureDevice — exactly what OBS's "Video Capture
// Device" picks up.  We list externals (the capture cards) plus the Mac's own
// camera, so the "+ → HDMI / USB Capture" menu can offer them.

import AVFoundation

enum CaptureDevices {
    /// All selectable video-capture devices (external UVC first in practice).
    static func discover() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
        } else {
            types.append(.externalUnknown)   // pre-14 name for UVC capture devices
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                mediaType: .video,
                                                position: .unspecified).devices
    }
}
