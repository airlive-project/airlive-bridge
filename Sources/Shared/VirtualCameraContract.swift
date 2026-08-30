// VirtualCameraContract.swift — the ONE description of the virtual camera.
//
// Compiled into BOTH targets: the extension publishes a camera with this identity, size,
// cadence and pixel format, and the Bridge finds it by that identity and hands it frames in
// that format.  Every value here is agreed across a process boundary, so a disagreement is
// not a compile error — it is a camera that is never found, or a picture that is never shown.
//
// It used to be written twice, once per target, with a comment in each copy saying the two
// must match.  A comment is not a mechanism.  (project.yml lists this file explicitly in the
// extension's sources; that is the only reason one file can serve two targets.)

import CoreVideo

/// Wire size of the virtual camera.  Fixed 1080p: the program feed is already a 1080p proxy,
/// and a camera that changes resolution mid-session confuses callers.
let kVCamWidth: Int32 = 1920
let kVCamHeight: Int32 = 1080

/// Cadence the source stream publishes at.
let kVCamFrameRate: Int32 = 30

/// The camera's pixel format: 8-bit 4:2:0 bi-planar, VIDEO RANGE — bit for bit what the
/// Bridge's H.264 decoder produces, and what every hardware webcam delivers.
///
/// It used to be 32BGRA, which forced a YCbCr→RGB pass on every frame.  That pass has to pick
/// a matrix and a range, and picking either one differently from the source shifts the whole
/// picture: the operator saw a flatter, washed-out image here while OBS — which gets the
/// untouched bitstream — looked right.  Publishing the source's own format means there is no
/// matrix to get wrong, no range to guess, and no per-frame GPU work at all.
let kVCamPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

/// Identity of the device and its two streams.  The DEVICE uuid is what the Bridge matches on
/// to find us among all the machine's cameras, and it anchors the user's per-app camera
/// permission — it must NEVER change across releases, or every app forgets its grant.
let kVCamDeviceUUID = "6F1B7A54-2C3E-4B7E-9E4D-A1C0D2E3F4A5"
let kVCamSourceStreamUUID = "3A2B1C0D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
let kVCamSinkStreamUUID = "5C4D3E2F-1A0B-4C9D-8E7F-6A5B4C3D2E1F"

/// The camera's name, as every app lists it.  The operator has to recognise the same words in
/// Zoom's picker as on the Bridge's card, so the two read it from here.
let kVCamDeviceName = "Airlive Bridge Virtual Camera"
