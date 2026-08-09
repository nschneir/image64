import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What can go wrong at the edges of the pipeline, where the engine touches the
/// file system.
///
/// Both cases carry the URL because both front ends report them to a human who
/// needs to know *which* file: the CLI prints the path, the app puts it in an
/// alert.
public enum ImageLoadingError: Error, Equatable, Sendable {
    /// The URL could not be decoded as an image — missing, unreadable, or not a
    /// format ImageIO knows.
    case unreadable(URL)

    /// The image could not be written to the URL — no such directory, no
    /// permission, or the encoder refused the data.
    case unwritable(URL)
}

/// The bridge between image files and the engine's byte buffers.
///
/// Everything colour-managed happens here and nowhere else: pixels enter as
/// whatever the file says they are, get resampled and adjusted in Core Image,
/// and leave as plain sRGB bytes in an `RGBBuffer`. Downstream stages (dither,
/// cell constraint, packing) compare bytes with no notion of a colour space, so
/// this is the only place a profile can be got wrong.
///
/// ## Coordinate conventions
///
/// `cropRect` is in **source pixel coordinates with y = 0 at the top**, which is
/// how a crop overlay drawn over a displayed image reports it and how the CLI
/// accepts it. Core Image's space is bottom-up, so `prepare` flips y explicitly
/// on the way in; `RGBBuffer` row 0 is likewise the top row of the result.
public enum ImageLoading {

    // MARK: - Colour management

    /// The one colour space the engine speaks. The C64 palettes are plain sRGB
    /// byte triples, so anything else would mean quantizing against colours
    /// measured in a different space.
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Shared because building a `CIContext` allocates GPU resources and the app
    /// re-prepares on every slider tick. `CIContext` is documented as thread-safe.
    ///
    /// `workingColorSpace` is where `CIColorControls` does its arithmetic, and
    /// it is not cosmetic: left unset, Core Image picks a wider space and a
    /// saturation boost on colodore cyan drives the red channel below zero,
    /// where it clamps to 0 instead of the 46 sRGB gives — a 46-unit difference
    /// in an exported picture. Pinned by
    /// `testAdjustmentsAreComputedInTheSRGBWorkingSpace`.
    ///
    /// `outputColorSpace` is belt-and-braces: `renderRGB` passes sRGB to
    /// `render(toBitmap:)` explicitly, which is what actually governs the bytes
    /// that come back. Both are set so the context is right whichever way it is
    /// later asked to render.
    private static let context = CIContext(options: [
        .workingColorSpace: sRGB,
        .outputColorSpace: sRGB,
    ])

    // MARK: - Loading

    /// Decodes the image at `url` with ImageIO.
    ///
    /// - Throws: `ImageLoadingError.unreadable` if the file is missing, is not an
    ///   image, or holds no decodable frame.
    public static func loadCGImage(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ImageLoadingError.unreadable(url)
        }
        return image
    }

    // MARK: - Prepare

    /// Crops, resamples, and colour-adjusts `image` into the engine's input
    /// buffer.
    ///
    /// The order is fixed: crop, then Lanczos resize to the exact target
    /// geometry, then the colour controls, then read back as sRGB bytes.
    /// Adjusting after the resize means the slider values apply to the pixels
    /// the user actually sees in the preview, and it is far less work — the
    /// adjustment runs on at most 320×200 pixels rather than on a 24-megapixel
    /// original.
    ///
    /// The resize is deliberately anamorphic. A multicolour target is 160×200
    /// from a 320×200-shaped crop, so the horizontal factor is half the vertical
    /// one; `CILanczosScaleTransform` expresses that as a vertical `scale` plus
    /// an `aspectRatio` correction for the horizontal axis, and Lanczos is used
    /// rather than the cheaper filters because a 4× downscale of a photograph is
    /// exactly where a box filter aliases.
    ///
    /// - Parameters:
    ///   - cropRect: the region of `image` to use, in source pixels, **y = 0 at
    ///     the top**. Clipped to the image; if it misses the image entirely (or
    ///     is empty) the whole image is used, because a degenerate rectangle
    ///     mid-drag must not take the app down.
    ///   - brightness: −1…+1, mapped to `CIColorControls.inputBrightness` as
    ///     `0.25 · b` — the full ±1 of the filter blows a photograph out, a
    ///     quarter of it is a usable range end to end.
    ///   - contrast: −1…+1, mapped to `inputContrast` as `1 + 0.5 · c`, so 0 is
    ///     the filter's neutral 1.0 and −1 is a flat-but-not-grey 0.5.
    ///   - saturation: −1…+1, mapped to `inputSaturation` as `1 + s`, so −1 is
    ///     exactly greyscale and +1 is double saturation.
    /// - Returns: a `targetWidth`×`targetHeight` buffer of sRGB bytes, row 0 the
    ///   top row. Alpha is dropped; because Core Image hands back premultiplied
    ///   RGBA, transparent source areas read as black.
    public static func prepare(
        _ image: CGImage,
        cropRect: CGRect,
        targetWidth: Int, targetHeight: Int,
        brightness: Double, contrast: Double,
        saturation: Double
    ) -> RGBBuffer {
        precondition(
            targetWidth > 0 && targetHeight > 0,
            "prepare needs a positive target size, got \(targetWidth)×\(targetHeight)")

        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = cropRect.intersection(imageRect)
        let crop = (clipped.isNull || clipped.isEmpty) ? imageRect : clipped

        // Core Image's origin is bottom-left; ours is top-left. The flip is the
        // whole difference between cropping the sky and cropping the ground.
        let flipped = CGRect(
            x: crop.origin.x,
            y: imageRect.height - crop.origin.y - crop.height,
            width: crop.width, height: crop.height)

        let source =
            CIImage(cgImage: image)
            .cropped(to: flipped)
            // Move the crop's corner to the origin so the scale below is about
            // size alone and the result lands in the render bounds.
            .transformed(
                by: CGAffineTransform(translationX: -flipped.origin.x, y: -flipped.origin.y))
            // Clamped *before* the resampler, and this is load-bearing. Lanczos
            // has a wide kernel, so pixels near the border sample beyond the
            // extent; on a finite image that is transparent black, and since
            // Core Image works premultiplied and this function drops alpha, the
            // result is a darkened frame all the way round every non-1:1 resize
            // (measured at up to 24 units on a solid field — an order of
            // magnitude past the ±2 the tests allow, and plainly visible as a
            // border in the exported picture). Clamping replaces that void with
            // the edge pixels repeated, which changes no interior pixel.
            //
            // The clamp goes after the crop, not before it, so the pixels
            // outside the user's crop rectangle stay out of the picture: what
            // the border resamples against is the crop's own edge, not whatever
            // the crop was drawn to exclude.
            .clampedToExtent()

        let verticalScale = Double(targetHeight) / Double(crop.height)
        let horizontalScale = Double(targetWidth) / Double(crop.width)
        let scaled = source.applyingFilter(
            "CILanczosScaleTransform",
            parameters: [
                kCIInputScaleKey: verticalScale,
                kCIInputAspectRatioKey: horizontalScale / verticalScale,
            ])

        let adjusted = scaled.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputBrightnessKey: 0.25 * brightness,
                kCIInputContrastKey: 1 + 0.5 * contrast,
                kCIInputSaturationKey: 1 + saturation,
            ])

        return renderRGB(adjusted, width: targetWidth, height: targetHeight)
    }

    /// Renders the `width`×`height` region of `image` at the Core Image origin
    /// to sRGB bytes.
    ///
    /// `CIContext.render(toBitmap:)` writes the region top-down — bitmap row 0
    /// is the region's *highest* y, which after `prepare`'s crop flip is the top
    /// row of the source — so the bytes drop straight into `RGBBuffer` with no
    /// second reversal. (Pinned by `testPreparedBufferIsTopDown`; the two flips
    /// here and in the crop rect are easy to get individually wrong in a way
    /// that a uniform test image cannot see.)
    private static func renderRGB(_ image: CIImage, width: Int, height: Int) -> RGBBuffer {
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        bytes.withUnsafeMutableBytes { raw in
            context.render(
                image, toBitmap: raw.baseAddress!, rowBytes: rowBytes,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8, colorSpace: sRGB)
        }

        var pixels: [RGB] = []
        pixels.reserveCapacity(width * height)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            pixels.append(RGB(r: bytes[index], g: bytes[index + 1], b: bytes[index + 2]))
        }
        return RGBBuffer(width: width, height: height, pixels: pixels)
    }

    // MARK: - Output

    /// Builds a `CGImage` from `buffer`, each pixel replicated `scaleX`×`scaleY`
    /// times.
    ///
    /// Nearest-neighbour by construction (`interpolationQuality = .none`):
    /// this is what draws the preview and what writes the PNG export, and a
    /// C64 picture magnified with smoothing is a lie about what the hardware
    /// shows. It is also how a multicolour image gets its 2:1 pixels — 160×200
    /// at `scaleX: 2, scaleY: 1` is the correct aspect.
    public static func cgImage(from buffer: RGBBuffer, scaleX: Int, scaleY: Int) -> CGImage {
        precondition(scaleX > 0 && scaleY > 0, "scale must be positive")

        var bytes = [UInt8](repeating: 255, count: buffer.width * buffer.height * 4)
        for (pixel, index) in zip(buffer.pixels, stride(from: 0, to: bytes.count, by: 4)) {
            bytes[index] = pixel.r
            bytes[index + 1] = pixel.g
            bytes[index + 2] = pixel.b
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        // Force-unwraps: every argument is fixed by this function, so a failure
        // here would be a bug in this file rather than bad input.
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let unscaled = CGImage(
            width: buffer.width, height: buffer.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: buffer.width * 4, space: sRGB, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!

        if scaleX == 1 && scaleY == 1 { return unscaled }

        let width = buffer.width * scaleX
        let height = buffer.height * scaleY
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: bitmapInfo.rawValue)!
        context.interpolationQuality = .none
        context.draw(unscaled, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Writes `image` to `url` as a PNG via ImageIO.
    ///
    /// - Throws: `ImageLoadingError.unwritable` if the destination cannot be
    ///   created or the encode fails.
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw ImageLoadingError.unwritable(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageLoadingError.unwritable(url)
        }
    }
}
