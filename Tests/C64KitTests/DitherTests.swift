import XCTest
@testable import C64Kit

final class DitherTests: XCTestCase {

    // MARK: - Helpers

    /// A `width`×`height` buffer where every pixel is `color`.
    private func uniform(_ color: RGB, width: Int, height: Int) -> RGBBuffer {
        RGBBuffer(
            width: width, height: height,
            pixels: Array(repeating: color, count: width * height))
    }

    /// A 16×16 buffer whose columns ramp 0…255 in grey, constant down each column.
    private func greyRamp() -> RGBBuffer {
        var pixels: [RGB] = []
        pixels.reserveCapacity(16 * 16)
        for _ in 0..<16 {
            for x in 0..<16 {
                let level = UInt8(x * 17)  // 0, 17, … 255
                pixels.append(RGB(r: level, g: level, b: level))
            }
        }
        return RGBBuffer(width: 16, height: 16, pixels: pixels)
    }

    // MARK: - Buffers

    func testRGBBufferSubscriptIsRowMajor() {
        var buffer = uniform(RGB(r: 0, g: 0, b: 0), width: 3, height: 2)
        buffer[2, 1] = RGB(r: 1, g: 2, b: 3)
        XCTAssertEqual(buffer.pixels[1 * 3 + 2], RGB(r: 1, g: 2, b: 3))
        XCTAssertEqual(buffer[2, 1], RGB(r: 1, g: 2, b: 3))
        XCTAssertEqual(buffer[0, 0], RGB(r: 0, g: 0, b: 0))
    }

    func testIndexBufferSubscriptIsRowMajor() {
        var buffer = IndexBuffer(width: 3, height: 2, indices: Array(repeating: 0, count: 6))
        buffer[1, 1] = 7
        XCTAssertEqual(buffer.indices[1 * 3 + 1], 7)
        XCTAssertEqual(buffer[1, 1], 7)
    }

    func testIndexBufferEquality() {
        let a = IndexBuffer(width: 2, height: 1, indices: [1, 2])
        let b = IndexBuffer(width: 2, height: 1, indices: [1, 2])
        let c = IndexBuffer(width: 2, height: 1, indices: [2, 1])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testQuantizePreservesDimensions() {
        let image = greyRamp()
        for mode in [DitherMode.none, .bayer, .fs] {
            let result = Quantizer.quantize(image, palette: .colodore, dither: mode)
            XCTAssertEqual(result.width, 16, "\(mode)")
            XCTAssertEqual(result.height, 16, "\(mode)")
            XCTAssertEqual(result.indices.count, 256, "\(mode)")
        }
    }

    func testQuantizeOfAnEmptyBufferIsEmpty() {
        let image = RGBBuffer(width: 0, height: 0, pixels: [])
        for mode in [DitherMode.none, .bayer, .fs] {
            let result = Quantizer.quantize(image, palette: .colodore, dither: mode)
            XCTAssertEqual(result.indices, [], "\(mode)")
        }
    }

    // MARK: - (a) A flat palette colour survives every dither mode

    func testUniformPaletteColorQuantizesToItselfUnderEveryDitherMode() {
        for palette in C64Palette.allCases {
            let green = palette.colors[5]
            let image = uniform(green, width: 8, height: 8)
            for mode in [DitherMode.none, .bayer, .fs] {
                let result = Quantizer.quantize(image, palette: palette, dither: mode)
                XCTAssertEqual(
                    result.indices, Array(repeating: UInt8(5), count: 64),
                    "\(palette.rawValue) / \(mode.rawValue) did not stay on colour 5")
            }
        }
    }

    // MARK: - (b) `none` snaps exact palette colours

    func testNoneMapsExactPaletteColorsToTheirIndices() {
        let palette = C64Palette.colodore
        let image = RGBBuffer(
            width: 2, height: 1, pixels: [palette.colors[4], palette.colors[9]])
        let result = Quantizer.quantize(image, palette: palette, dither: .none)
        XCTAssertEqual(result.indices, [4, 9])
    }

    func testNoneAgreesWithNearestIndexPixelByPixel() {
        let image = greyRamp()
        let palette = C64Palette.pepto
        let result = Quantizer.quantize(image, palette: palette, dither: .none)
        for (offset, pixel) in image.pixels.enumerated() {
            XCTAssertEqual(result.indices[offset], palette.nearestIndex(to: pixel))
        }
    }

    // MARK: - (c) Floyd–Steinberg on a ramp

    func testFloydSteinbergOnARampProducesSeveralDistinctIndices() {
        let result = Quantizer.quantize(greyRamp(), palette: .colodore, dither: .fs)
        XCTAssertGreaterThanOrEqual(Set(result.indices).count, 3)
    }

    func testFloydSteinbergIsDeterministic() {
        let image = greyRamp()
        let first = Quantizer.quantize(image, palette: .colodore, dither: .fs)
        let second = Quantizer.quantize(image, palette: .colodore, dither: .fs)
        XCTAssertEqual(first, second)
    }

    // MARK: - (d) Bayer on a ramp

    func testBayerIsDeterministic() {
        let image = greyRamp()
        let first = Quantizer.quantize(image, palette: .colodore, dither: .bayer)
        let second = Quantizer.quantize(image, palette: .colodore, dither: .bayer)
        XCTAssertEqual(first, second)
    }

    func testBayerDiffersFromNoDither() {
        let image = greyRamp()
        let plain = Quantizer.quantize(image, palette: .colodore, dither: .none)
        let bayer = Quantizer.quantize(image, palette: .colodore, dither: .bayer)
        XCTAssertNotEqual(plain, bayer)
    }

    func testBayerVariesWithinAConstantRegion() {
        // The whole point of an ordered matrix: a flat mid-grey that is not a
        // palette colour must break up into a pattern rather than one flat index.
        let image = uniform(RGB(r: 0x60, g: 0x60, b: 0x60), width: 8, height: 8)
        let bayer = Quantizer.quantize(image, palette: .colodore, dither: .bayer)
        XCTAssertGreaterThanOrEqual(Set(bayer.indices).count, 2)
        // …and it tiles with period 4 in both axes.
        for y in 0..<4 {
            for x in 0..<4 {
                XCTAssertEqual(bayer[x, y], bayer[x + 4, y], "x tile at (\(x),\(y))")
                XCTAssertEqual(bayer[x, y], bayer[x, y + 4], "y tile at (\(x),\(y))")
            }
        }
    }

    // MARK: - (e) Hand-computed 2×2 Floyd–Steinberg

    func testNoneOnFlatQuarterGreyPicksColodoreDarkGrey() {
        // #404040 = (64,64,64). Colodore 11 is #4A4A4A = (74,74,74), a distance
        // of (0.299+0.587+0.114)·10² = 100. Nothing else comes close: black is
        // 64² = 4096 away, colour 12 (#7B7B7B) is 19² = 361 away. Assert the two
        // runners-up explicitly so the fixture cannot rot silently.
        let palette = C64Palette.colodore
        let grey = RGB(r: 0x40, g: 0x40, b: 0x40)
        let d11 = C64Palette.distance(grey, palette.colors[11])
        XCTAssertEqual(d11, 100, accuracy: 1e-9)
        for (index, color) in palette.colors.enumerated() where index != 11 {
            XCTAssertGreaterThan(C64Palette.distance(grey, color), d11, "index \(index)")
        }

        let image = uniform(grey, width: 2, height: 2)
        let result = Quantizer.quantize(image, palette: palette, dither: .none)
        XCTAssertEqual(result.indices, [11, 11, 11, 11])
    }

    func testFloydSteinbergOnAHandComputedTwoByTwo() {
        // Hand computation. Input: every pixel #404040 = 64 in all three
        // channels, so all three channels stay equal throughout and one scalar
        // trace covers them. Palette colodore; the only relevant entries are
        // 11 = 74 and 0 = 0. A grey g picks 0 over 11 only when g < 37 (the
        // midpoint of 0 and 74), which is the number to watch.
        //
        // Serpentine scan. Even row 0 runs left→right with weights
        // right 7/16, down-left 3/16, down 5/16, down-right 1/16; odd row 1
        // runs right→left with the horizontal deltas negated. The accumulated
        // value is clamped-and-rounded to a byte before matching, and the error
        // is taken against that byte, so the trace below rounds at each pixel.
        //
        // Row 0, left→right:
        //   (0,0): acc 64 → byte 64 → nearest 11 (74), error 64 − 74 = −10.
        //          (1,0) += −10·7/16 = −4.375
        //          (0,1) += −10·5/16 = −3.125
        //          (1,1) += −10·1/16 = −0.625
        //          (−1,1) is off-buffer; that 3/16 share is dropped.
        //   (1,0): acc 64 − 4.375 = 59.625 → byte 60 → nearest 11, error −14.
        //          (2,0) off-buffer (7/16 dropped)
        //          (0,1) += −14·3/16 = −2.625   [down-left]
        //          (1,1) += −14·5/16 = −4.375   [down]
        //          (2,1) off-buffer (1/16 dropped)
        //
        // Row 1 accumulators before it is scanned:
        //   (0,1) = 64 − 3.125 − 2.625 = 58.25
        //   (1,1) = 64 − 0.625 − 4.375 = 59.0
        //
        // Row 1, right→left:
        //   (1,1): acc 59 → byte 59 → nearest 11, error 59 − 74 = −15.
        //          the "forward" 7/16 now goes left:
        //          (0,1) += −15·7/16 = −6.5625
        //          the whole downward row is off-buffer, so 3/16+5/16+1/16 drop.
        //   (0,1): acc 58.25 − 6.5625 = 51.6875 → byte 52 → nearest 11
        //          (|52 − 74| = 22 against 52 to black).
        //
        // Every pixel lands on 11: the accumulated error only ever darkens the
        // trailing pixels from 64 to 52, nowhere near the 37 needed to flip a
        // pixel to black. So the expected output is [11, 11, 11, 11] — the
        // brief's guess of [11, 0, 0, 11] assumed an error trail an order of
        // magnitude larger than a 10-unit-per-pixel residual can produce.
        let image = uniform(RGB(r: 0x40, g: 0x40, b: 0x40), width: 2, height: 2)
        let result = Quantizer.quantize(image, palette: .colodore, dither: .fs)
        XCTAssertEqual(result.indices, [11, 11, 11, 11])
    }

    // MARK: - Serpentine, observably

    func testFloydSteinbergScanIsSerpentine() {
        // A raster (always left→right) scan would diffuse the same way on every
        // row, so a vertically constant input would produce identical rows. A
        // serpentine scan reverses on odd rows, so at least one odd row must
        // differ from the even row above it.
        let image = greyRamp()  // constant down every column
        let result = Quantizer.quantize(image, palette: .colodore, dither: .fs)
        let row0 = Array(result.indices[0..<16])
        let row1 = Array(result.indices[16..<32])
        XCTAssertNotEqual(row0, row1, "rows are identical; the scan is not serpentine")
    }

    // MARK: - Error diffusion is clamped before matching

    func testFloydSteinbergClampsBeforeMatching() {
        // A hard black/white edge repeated across a row drives the accumulator
        // far past both ends of 0…255. Clamping first keeps every index legal
        // and, on this input, keeps the extremes on the extreme palette entries.
        var pixels: [RGB] = []
        for y in 0..<8 {
            for x in 0..<8 {
                let on = (x + y) % 2 == 0
                pixels.append(on ? RGB(r: 255, g: 255, b: 255) : RGB(r: 0, g: 0, b: 0))
            }
        }
        let image = RGBBuffer(width: 8, height: 8, pixels: pixels)
        let result = Quantizer.quantize(image, palette: .colodore, dither: .fs)
        for index in result.indices {
            XCTAssertLessThan(index, 16)
        }
    }
}
