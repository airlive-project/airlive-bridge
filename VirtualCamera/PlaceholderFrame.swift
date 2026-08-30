// PlaceholderFrame.swift — what the camera shows when no program is being published.
//
// A virtual camera is opened by the CONFERENCING app, which has no idea whether the
// Bridge is running.  Showing pure black there reads as "this camera is broken", so
// the state is stated in words instead: the operator sees why there is no picture.

import Foundation
import CoreVideo
import CoreGraphics
import CoreText
import VideoToolbox

enum PlaceholderFrame {

    /// Returns the placeholder in the camera's published format.  Text is laid out in
    /// RGB — CoreGraphics cannot draw into a bi-planar buffer — and converted ONCE, at
    /// creation; the result is cached by the caller, so this costs nothing per frame.
    static func make(width: Int, height: Int) -> CVPixelBuffer? {
        guard let rgb = drawRGB(width: width, height: height) else { return nil }
        return convertToCameraFormat(rgb, width: width, height: height) ?? rgb
    }

    /// One-shot RGB→camera-format conversion.  A session is created and thrown away: this
    /// runs exactly once in the life of the extension.
    private static func convertToCameraFormat(_ src: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var dst: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kVCamPixelFormat, attrs as CFDictionary, &dst) == kCVReturnSuccess,
              let dst else { return nil }
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                           pixelTransferSessionOut: &session) == noErr,
              let session else { return nil }
        defer { VTPixelTransferSessionInvalidate(session) }
        guard VTPixelTransferSessionTransferImage(session, from: src, to: dst) == noErr else { return nil }
        return dst
    }

    private static func drawRGB(width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var px: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &px)
        guard let px else { return nil }

        CVPixelBufferLockBaseAddress(px, [])
        defer { CVPixelBufferUnlockBaseAddress(px, []) }
        guard let base = CVPixelBufferGetBaseAddress(px),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base, width: width, height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(px),
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return px }

        // Near-black, not pure black: distinguishes "we are alive and drawing" from a
        // dead camera that never produced a frame at all.
        ctx.setFillColor(CGColor(red: 0.043, green: 0.047, blue: 0.055, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        draw("Airlive Bridge Virtual Camera", in: ctx, size: 56, y: Double(height) / 2 + 18,
             width: width, gray: 0.92)
        draw("No program — open Airlive Bridge and put a camera on air",
             in: ctx, size: 28, y: Double(height) / 2 - 46, width: width, gray: 0.55)
        return px
    }

    private static func draw(_ text: String, in ctx: CGContext, size: CGFloat,
                             y: Double, width: Int, gray: CGFloat) {
        // CoreText attribute keys, not AppKit's: a system extension has no business
        // linking AppKit just to lay out two lines of text.
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: gray, green: gray, blue: gray, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(x: (Double(width) - Double(bounds.width)) / 2, y: y)
        CTLineDraw(line, ctx)
    }
}
