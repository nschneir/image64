/// Turns true-colour pixels into C64 palette indices.
///
/// Three strategies, all deterministic — the same image and settings must give
/// byte-identical output on every run, because the acceptance tests compare
/// whole files. That rules out anything randomised, and it is why the
/// Floyd–Steinberg scan order and the tie-break in `nearestIndex` are pinned
/// rather than left to taste.
public enum Quantizer {

    /// Quantizes `image` to palette indices using `dither`.
    ///
    /// The output has the same dimensions as the input; every index is 0…15.
    public static func quantize(
        _ image: RGBBuffer,
        palette: C64Palette,
        dither: DitherMode
    ) -> IndexBuffer {
        switch dither {
        case .none: return quantizeNearest(image, palette: palette)
        case .bayer: return quantizeBayer(image, palette: palette)
        case .fs: return quantizeFloydSteinberg(image, palette: palette)
        }
    }

    // MARK: - No dither

    /// Snaps each pixel independently. Fast, and the reference the other two
    /// modes are compared against.
    private static func quantizeNearest(_ image: RGBBuffer, palette: C64Palette) -> IndexBuffer {
        IndexBuffer(
            width: image.width, height: image.height,
            indices: image.pixels.map { palette.nearestIndex(to: $0) })
    }

    // MARK: - Bayer 4×4

    /// The 4×4 ordered-dither threshold matrix, in the standard recursive order.
    ///
    /// Each cell holds a rank 0…15; the ranks are arranged so that neighbouring
    /// pixels get maximally different thresholds, which is what turns a flat
    /// area into a fine cross-hatch instead of a blotch.
    static let bayerMatrix: [[Double]] = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5],
    ]

    /// How far a threshold cell may push a channel, in 0…255 units.
    ///
    /// The matrix contributes −0.5…+0.4375 of this. 64 is roughly the spacing
    /// between neighbouring greys in the C64 palette, so the pattern is strong
    /// enough to break a band and weak enough not to invent new colours.
    private static let bayerAmplitude: Double = 64

    /// Adds a position-dependent offset to each channel, then snaps.
    ///
    /// Ordered dithering has no memory: the offset depends only on `(x % 4,
    /// y % 4)`, so the result is trivially deterministic and the algorithm
    /// parallelises per pixel if it ever needs to.
    private static func quantizeBayer(_ image: RGBBuffer, palette: C64Palette) -> IndexBuffer {
        var indices = [UInt8](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height {
            let row = bayerMatrix[y % 4]
            for x in 0..<image.width {
                let offset = (row[x % 4] / 16 - 0.5) * bayerAmplitude
                let pixel = image[x, y]
                let adjusted = RGB(
                    r: clampToByte(Double(pixel.r) + offset),
                    g: clampToByte(Double(pixel.g) + offset),
                    b: clampToByte(Double(pixel.b) + offset))
                indices[y * image.width + x] = palette.nearestIndex(to: adjusted)
            }
        }
        return IndexBuffer(width: image.width, height: image.height, indices: indices)
    }

    // MARK: - Floyd–Steinberg

    /// Error-diffusion dithering with a serpentine scan.
    ///
    /// Each pixel is snapped to the palette and the resulting error is pushed
    /// into its not-yet-visited neighbours, so the local average brightness
    /// tracks the original even though only sixteen colours exist. The scan
    /// alternates direction row by row — left→right on even rows, right→left on
    /// odd — which stops the error from streaking consistently to one side and
    /// producing the diagonal "worm" artefacts a plain raster scan gives.
    ///
    /// The accumulator is `Double`, three channels per pixel, held for the whole
    /// image rather than a two-row window: at 320×200 that is under a megabyte,
    /// and a flat array keeps the neighbour arithmetic obvious.
    ///
    /// Values are clamped to 0…255 *before* the nearest-colour lookup, not
    /// after. Accumulated error routinely overshoots both ends on high-contrast
    /// edges; matching an out-of-range colour would let the palette search see
    /// distances no real pixel can have, and the residual error would grow
    /// without bound down the image.
    private static func quantizeFloydSteinberg(
        _ image: RGBBuffer, palette: C64Palette
    ) -> IndexBuffer {
        let width = image.width
        let height = image.height
        var indices = [UInt8](repeating: 0, count: width * height)
        guard width > 0 && height > 0 else {
            return IndexBuffer(width: width, height: height, indices: indices)
        }

        // Three interleaved channels: accumulator[(y * width + x) * 3 + c].
        var accumulator = [Double](repeating: 0, count: width * height * 3)
        for (offset, pixel) in image.pixels.enumerated() {
            accumulator[offset * 3] = Double(pixel.r)
            accumulator[offset * 3 + 1] = Double(pixel.g)
            accumulator[offset * 3 + 2] = Double(pixel.b)
        }

        for y in 0..<height {
            // Even rows run left→right, odd rows right→left. `step` also flips
            // the sign of every horizontal weight offset below, which is the
            // whole of the serpentine mirroring.
            let leftToRight = y % 2 == 0
            let step = leftToRight ? 1 : -1
            let columns = leftToRight
                ? Array(0..<width)
                : Array((0..<width).reversed())

            for x in columns {
                let base = (y * width + x) * 3
                let old = (
                    r: accumulator[base],
                    g: accumulator[base + 1],
                    b: accumulator[base + 2])
                let clamped = RGB(
                    r: clampToByte(old.r), g: clampToByte(old.g), b: clampToByte(old.b))
                let index = palette.nearestIndex(to: clamped)
                indices[y * width + x] = index

                // Error is measured against the *clamped* value, so a pixel that
                // was pushed out of range does not keep re-injecting the part of
                // the error that clamping already discarded.
                let chosen = palette.colors[Int(index)]
                let error = (
                    r: Double(clamped.r) - Double(chosen.r),
                    g: Double(clamped.g) - Double(chosen.g),
                    b: Double(clamped.b) - Double(chosen.b))

                // Standard Floyd–Steinberg kernel, with the horizontal deltas
                // following the scan direction. Shares that fall off an edge are
                // dropped rather than folded back in: reweighting the survivors
                // would brighten or darken the border column.
                diffuse(&accumulator, width, height, x + step, y, error, 7.0 / 16.0)
                diffuse(&accumulator, width, height, x - step, y + 1, error, 3.0 / 16.0)
                diffuse(&accumulator, width, height, x, y + 1, error, 5.0 / 16.0)
                diffuse(&accumulator, width, height, x + step, y + 1, error, 1.0 / 16.0)
            }
        }

        return IndexBuffer(width: width, height: height, indices: indices)
    }

    /// Adds `weight` of `error` to the accumulator at `(x, y)`, ignoring
    /// positions outside the buffer.
    private static func diffuse(
        _ accumulator: inout [Double],
        _ width: Int,
        _ height: Int,
        _ x: Int,
        _ y: Int,
        _ error: (r: Double, g: Double, b: Double),
        _ weight: Double
    ) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let base = (y * width + x) * 3
        accumulator[base] += error.r * weight
        accumulator[base + 1] += error.g * weight
        accumulator[base + 2] += error.b * weight
    }

    // MARK: - Shared

    /// Rounds to the nearest integer and pins the result into 0…255.
    ///
    /// Both dithering modes produce fractional, out-of-range channel values;
    /// this is the single place that turns one back into something the palette
    /// search can accept.
    private static func clampToByte(_ value: Double) -> UInt8 {
        if value <= 0 { return 0 }
        if value >= 255 { return 255 }
        return UInt8(value.rounded())
    }
}
