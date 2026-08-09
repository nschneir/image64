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
        // Row 0 is pure black, which is an exact palette colour, so it emits
        // zero error and contributes nothing downward. Everything below is
        // therefore decided by row 1's own scan direction alone — which is
        // exactly the serpentine property, isolated.
        //
        // For flat greys the colodore nearest-index map is:
        //   0…34 → 0,  35…46 → 9,  47…98 → 11,  99…150 → 12,
        //   151…216 → 15,  217…255 → 1.
        //
        // Serpentine — row 1 (odd) runs right→left:
        //   (2,1): 30 → index 0 (black), error 30 − 0 = +30.
        //          forward is now leftward: (1,1) += 30·7/16 = +13.125
        //   (1,1): 40 + 13.125 = 53.125 → byte 53 → index 11 (74),
        //          error 53 − 74 = −21 → (0,1) += −21·7/16 = −9.1875
        //   (0,1): 40 − 9.1875 = 30.8125 → byte 31 → index 0.
        //   Row 1 = [0, 11, 0].
        //
        // A raster scan would run row 1 left→right instead and get [9, 0, 11]:
        //   (0,1): 40 → index 9 (brown, #553800) — note 40 is in the 35…46 band,
        //          so the error (−45, −16, +40) is not even grey any more, and
        //          the two orders diverge immediately and completely.
        //
        // The two orders share no pixel in row 1, so this fixture cannot pass
        // under a raster implementation.
        let image = RGBBuffer(
            width: 3, height: 2,
            pixels: [
                RGB(r: 0, g: 0, b: 0), RGB(r: 0, g: 0, b: 0), RGB(r: 0, g: 0, b: 0),
                RGB(r: 40, g: 40, b: 40), RGB(r: 40, g: 40, b: 40), RGB(r: 30, g: 30, b: 30),
            ])
        let result = Quantizer.quantize(image, palette: .colodore, dither: .fs)
        XCTAssertEqual(result.indices, [0, 0, 0, 0, 11, 0], "raster order would give [0,0,0,9,0,11]")
    }

    // MARK: - Out-of-range accumulator conventions

    /// A 3×3 of saturated primaries. Quantizing it drives the Floyd–Steinberg
    /// accumulator to −50.44 at the low end and +305.44 at the high end, so it
    /// exercises both clamping directions, and it is small enough to pin
    /// exactly.
    private func outOfRangeFixture() -> RGBBuffer {
        RGBBuffer(
            width: 3, height: 3,
            pixels: [
                RGB(r: 255, g: 0, b: 0), RGB(r: 0, g: 0, b: 255), RGB(r: 0, g: 255, b: 255),
                RGB(r: 0, g: 0, b: 0), RGB(r: 255, g: 0, b: 255), RGB(r: 0, g: 0, b: 0),
                RGB(r: 255, g: 255, b: 255), RGB(r: 0, g: 255, b: 255), RGB(r: 255, g: 255, b: 255),
            ])
    }

    func testFloydSteinbergClampsBeforeMatching() {
        // Pins the clamp-before-match convention. On this fixture the pixel at
        // (0,1) accumulates to roughly (−50, 25, 66): clamping first turns that
        // into (0, 25, 66), whose nearest entry is 11 (#4A4A4A)… but matching
        // the *unclamped* triple instead lets the −50 red inflate the distance
        // to every mid-grey and black wins, giving index 0.
        //
        // So index 3 of the output is 11 under clamped matching and 0 under
        // unclamped matching — one array distinguishes the two implementations.
        // (The previous version of this test asserted `index < 16`, which is a
        // tautology: nearestIndex cannot return anything else.)
        let result = Quantizer.quantize(outOfRangeFixture(), palette: .colodore, dither: .fs)
        XCTAssertEqual(
            result.indices, [2, 6, 3, 9, 4, 0, 1, 3, 1],
            "matching an unclamped accumulator would give [2, 6, 3, 0, 4, 0, 1, 3, 1]")
    }

    func testFloydSteinbergMeasuresErrorAgainstTheClampedValue() {
        // Pins the other half of the clamping convention: once a value has been
        // clamped, the error is measured against the clamped byte, not the raw
        // accumulator. Measuring against the raw value would re-inject the
        // overshoot that clamping just discarded, and the residual would grow
        // without bound down a high-contrast image.
        //
        // This fixture drives the accumulator to −47.69 … +279.50. Under the
        // clamped basis the pixel at (1,2) resolves to 2 (#813338); under the
        // raw basis the extra re-injected error carries it to 8 (#8E5029).
        let image = RGBBuffer(
            width: 3, height: 3,
            pixels: [
                RGB(r: 255, g: 255, b: 0), RGB(r: 0, g: 255, b: 255), RGB(r: 0, g: 0, b: 0),
                RGB(r: 255, g: 0, b: 255), RGB(r: 0, g: 255, b: 0), RGB(r: 0, g: 0, b: 0),
                RGB(r: 0, g: 255, b: 255), RGB(r: 255, g: 0, b: 0), RGB(r: 0, g: 0, b: 255),
            ])
        let result = Quantizer.quantize(image, palette: .colodore, dither: .fs)
        XCTAssertEqual(
            result.indices, [7, 3, 0, 4, 5, 0, 3, 2, 6],
            "measuring error against the raw accumulator would give [7, 3, 0, 4, 5, 0, 3, 8, 6]")
    }

    func testFloydSteinbergKeepsEveryIndexInPaletteRange() {
        // Cheap sanity net over a fixture that genuinely leaves 0…255 in both
        // directions. Weak on its own — the two tests above are what pin the
        // behaviour — but it would catch an implementation that indexed the
        // palette with an unclamped value and trapped.
        let result = Quantizer.quantize(outOfRangeFixture(), palette: .colodore, dither: .fs)
        XCTAssertEqual(result.indices.count, 9)
        XCTAssertTrue(result.indices.allSatisfy { $0 < 16 })
    }
}
