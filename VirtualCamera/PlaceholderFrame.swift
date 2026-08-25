// PlaceholderFrame.swift — what the camera shows when no program is being published.
//
// A virtual camera is opened by the CONFERENCING app, which has no idea whether the
// Bridge is running.  Showing pure black there reads as "this camera is broken", so
// the state is stated in words instead: the operator sees why there is no picture.

import Foundation
import CoreVideo
import CoreGraphics
import CoreText

enum PlaceholderFrame {

    static func make(width: Int, height: Int) -> CVPixelBuffer? {
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

        draw("Airlive Virtual Camera", in: ctx, size: 56, y: Double(height) / 2 + 18,
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
