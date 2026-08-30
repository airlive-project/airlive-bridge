// PlaceholderFrame.swift — what the camera shows when no program is being published.
//
// A virtual camera is opened by the CONFERENCING app, which has no idea whether the
// Bridge is running.  Showing pure black there reads as "this camera is broken", so
// the state is stated in words instead: the operator sees why there is no picture.

import Foundation
import CoreVideo
import CoreGraphics
import CoreImage
import CoreText

enum PlaceholderFrame {

    /// Returns the placeholder in the camera's published format.
    ///
    /// A branded image is used when one is bundled — drop `placeholder.png` (1920×1080)
    /// into the extension's resources and it is what people see. Otherwise the state is
    /// written out in text, which is still better than a black rectangle nobody can read.
    static func make(width: Int, height: Int) -> CVPixelBuffer? {
        guard let rgb = drawRGB(width: width, height: height) else {
            vcamLog.error("placeholder: could not be drawn — the camera will show black")
            return nil
        }
        guard let converted = convertToCameraFormat(rgb, width: width, height: height) else {
            // NEVER hand back the RGB buffer as a consolation: the stream is declared as
            // 4:2:0 bi-planar, and a consumer handed a packed RGB buffer under that
            // declaration shows nothing at all. Black is at least honest.
            vcamLog.error("placeholder: colour conversion failed — the camera will show black")
            return nil
        }
        vcamLog.notice("placeholder ready (\(bundledImage() != nil ? "branded image" : "text"))")
        return converted
    }

    /// The bundled brand image, if there is one.
    private static func bundledImage() -> CGImage? {
        guard let url = Bundle.main.url(forResource: "placeholder", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// RGB → the camera's 4:2:0 bi-planar video-range format, by hand.
    ///
    /// Deliberately arithmetic rather than VideoToolbox. This runs ONCE, inside a sandboxed
    /// system extension, and the whole picture depends on it: a conversion that quietly fails
    /// there leaves the camera showing nothing, which is exactly what happened. Twenty lines
    /// of BT.709 that cannot fail beat a framework call that can.
    private static func convertToCameraFormat(_ src: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kVCamPixelFormat, attrs as CFDictionary, &out) == kCVReturnSuccess,
              let dst = out else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let rgbBase = CVPixelBufferGetBaseAddress(src),
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(dst, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(dst, 1) else { return nil }

        let rgbStride = CVPixelBufferGetBytesPerRow(src)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(dst, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(dst, 1)
        let rgb = rgbBase.assumingMemoryBound(to: UInt8.self)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        // BT.709, video range — the same colour the stream declares. Fixed point, /256.
        @inline(__always) func clamp(_ v: Int) -> UInt8 { UInt8(min(255, max(0, v))) }

        for y in 0..<height {
            let row = y * rgbStride
            for x in 0..<width {
                // 32BGRA, little-endian byte order: B, G, R, A
                let p = row + x * 4
                let b = Int(rgb[p]), g = Int(rgb[p + 1]), r = Int(rgb[p + 2])
                luma[y * lumaStride + x] = clamp(((47 * r + 157 * g + 16 * b + 128) >> 8) + 16)
            }
        }
        // One chroma pair per 2×2 block, averaged so text edges do not fringe.
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                var rs = 0, gs = 0, bs = 0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let p = min(y + dy, height - 1) * rgbStride + min(x + dx, width - 1) * 4
                        bs += Int(rgb[p]); gs += Int(rgb[p + 1]); rs += Int(rgb[p + 2])
                    }
                }
                let r = rs / 4, g = gs / 4, b = bs / 4
                let o = (y / 2) * chromaStride + (x / 2) * 2
                chroma[o]     = clamp(((-26 * r - 87 * g + 112 * b + 128) >> 8) + 128)   // Cb
                chroma[o + 1] = clamp(((112 * r - 102 * g - 10 * b + 128) >> 8) + 128)   // Cr
            }
        }
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

        // A bundled brand image wins outright — it is the product's face in someone else's
        // window, and whoever drew it decided what belongs there.
        if let image = bundledImage() {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return px
        }

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
