import XCTest
@testable import C64Kit

final class CellConstraintTests: XCTestCase {

    // MARK: - Deterministic noise

    /// A 64-bit linear congruential generator, used instead of `SystemRandom`
    /// so the "random image" fixtures are byte-identical on every machine and
    /// every run. Knuth's MMIX multiplier/increment; the low bits of an LCG are
    /// notoriously non-random, so only the top byte of the state is ever used.
    private struct LCG {
        private var state: UInt64

        init(seed: UInt64) { self.state = seed }

        mutating func nextByte() -> UInt8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 56)
        }
    }

    /// The one seed every pseudo-random fixture in this file starts from.
    /// Constant on purpose: a failure here must be reproducible from the file
    /// alone, with no console output to copy back in.
    private static let seed: UInt64 = 0x1234_5678_9ABC_DEF0

    /// A `width`×`height` buffer of pseudo-random sRGB noise.
    ///
    /// Noise is the worst case for cell constraint: quantized, an 8×8 cell of it
    /// holds a dozen or more distinct indices, so the invariant sweep is
    /// actually exercising the drop-and-remap path in all 1000 cells rather
    /// than mostly finding cells that were already legal.
    private func noise(width: Int, height: Int) -> RGBBuffer {
        var rng = LCG(seed: Self.seed)
        var pixels: [RGB] = []
        pixels.reserveCapacity(width * height)
        for _ in 0..<(width * height) {
            pixels.append(RGB(r: rng.nextByte(), g: rng.nextByte(), b: rng.nextByte()))
        }
        return RGBBuffer(width: width, height: height, pixels: pixels)
    }

    // MARK: - Helpers

    /// The distinct indices inside the cell whose top-left corner is
    /// `(originX, originY)`.
    private func distinctIndices(
        in buffer: IndexBuffer,
        originX: Int, originY: Int,
        width cellWidth: Int, height cellHeight: Int
    ) -> Set<UInt8> {
        var found: Set<UInt8> = []
        for y in originY..<min(originY + cellHeight, buffer.height) {
            for x in originX..<min(originX + cellWidth, buffer.width) {
                found.insert(buffer[x, y])
            }
        }
        return found
    }

    /// Walks every cell of `buffer` and hands the callback the cell origin and
    /// its distinct indices.
    private func forEachCell(
        _ buffer: IndexBuffer,
        width cellWidth: Int, height cellHeight: Int,
        _ body: (Int, Int, Set<UInt8>) -> Void
    ) {
        for originY in stride(from: 0, to: buffer.height, by: cellHeight) {
            for originX in stride(from: 0, to: buffer.width, by: cellWidth) {
                body(
                    originX, originY,
                    distinctIndices(
                        in: buffer, originX: originX, originY: originY,
                        width: cellWidth, height: cellHeight))
            }
        }
    }

    /// An `width`×`height` index buffer built from a run-length description:
    /// `[(index, count), …]` laid down in row-major order.
    private func runs(width: Int, height: Int, _ runs: [(UInt8, Int)]) -> IndexBuffer {
        var indices: [UInt8] = []
        for (value, count) in runs {
            indices.append(contentsOf: repeatElement(value, count: count))
        }
        precondition(
            indices.count == width * height,
            "fixture describes \(indices.count) pixels, needs \(width * height)")
        return IndexBuffer(width: width, height: height, indices: indices)
    }

    // MARK: - (a) Invariant sweep over pseudo-random noise

    func testHiresLeavesAtMostTwoIndicesInEveryCell() {
        let image = noise(width: 320, height: 200)
        var buffer = Quantizer.quantize(image, palette: .colodore, dither: .none)

        // Sanity: the fixture must actually violate the constraint, otherwise
        // the sweep below would pass against a no-op implementation.
        var violatingBefore = 0
        forEachCell(buffer, width: 8, height: 8) { _, _, distinct in
            if distinct.count > 2 { violatingBefore += 1 }
        }
        XCTAssertEqual(violatingBefore, 1000, "noise should break every one of the 1000 cells")

        CellConstraints.enforceHires(&buffer, palette: .colodore)

        XCTAssertEqual(buffer.width, 320)
        XCTAssertEqual(buffer.height, 200)
        var cells = 0
        forEachCell(buffer, width: 8, height: 8) { x, y, distinct in
            cells += 1
            XCTAssertLessThanOrEqual(distinct.count, 2, "cell at (\(x),\(y)): \(distinct.sorted())")
        }
        XCTAssertEqual(cells, 1000)
    }

    func testMulticolorLeavesAtMostBackgroundPlusThreeInEveryCell() {
        let image = noise(width: 160, height: 200)
        var buffer = Quantizer.quantize(image, palette: .colodore, dither: .none)

        var violatingBefore = 0
        forEachCell(buffer, width: 4, height: 8) { _, _, distinct in
            if distinct.count > 4 { violatingBefore += 1 }
        }
        XCTAssertGreaterThan(violatingBefore, 900, "noise should break nearly every cell")

        let background = CellConstraints.enforceMulticolor(&buffer, palette: .colodore)

        XCTAssertEqual(buffer.width, 160)
        XCTAssertEqual(buffer.height, 200)
        XCTAssertLessThan(background, 16)
        var cells = 0
        forEachCell(buffer, width: 4, height: 8) { x, y, distinct in
            cells += 1
            let foreground = distinct.subtracting([background])
            XCTAssertLessThanOrEqual(
                foreground.count, 3,
                "cell at (\(x),\(y)) has \(foreground.sorted()) besides background \(background)")
        }
        XCTAssertEqual(cells, 1000)
    }

    // MARK: - (b) A hand-built hires cell

    func testHiresKeepsTheTwoMostFrequentAndRemapsTheRestToTheNearestKept() {
        // 8×8 = 64 pixels: 30 of index 1 (white), 20 of index 6 (blue), 14 of
        // index 2 (red). The two most frequent are 1 and 6, so every index-2
        // pixel must move — to whichever of the two survivors is nearer under
        // the engine's own metric, computed here rather than hard-coded so the
        // fixture cannot disagree with the palette table.
        let palette = C64Palette.colodore
        var buffer = runs(width: 8, height: 8, [(1, 30), (6, 20), (2, 14)])
        let redPositions = (0..<64).filter { buffer.indices[$0] == 2 }
        XCTAssertEqual(redPositions.count, 14)

        let toWhite = C64Palette.distance(palette.colors[2], palette.colors[1])
        let toBlue = C64Palette.distance(palette.colors[2], palette.colors[6])
        // Ties break toward the lower index, exactly as `nearestIndex` does.
        let expected: UInt8 = toBlue < toWhite ? 6 : 1

        CellConstraints.enforceHires(&buffer, palette: palette)

        XCTAssertEqual(
            Set(buffer.indices), [1, 6],
            "only the two kept indices may survive")
        for position in redPositions {
            XCTAssertEqual(
                buffer.indices[position], expected,
                "index-2 pixel at \(position) should have become \(expected)")
        }
        // The kept pixels are untouched.
        XCTAssertEqual(Array(buffer.indices[0..<30]), Array(repeating: 1, count: 30))
        XCTAssertEqual(Array(buffer.indices[30..<50]), Array(repeating: 6, count: 20))
    }

    func testHiresBreaksFrequencyTiesTowardTheLowerIndex() {
        // Counts: index 0 → 24, index 4 → 20, index 12 → 20. The top slot is
        // unambiguous; the second is a tie between 4 and 12, and the rule says
        // the lower index wins, so the twelves are the ones that must move.
        var buffer = runs(width: 8, height: 8, [(0, 24), (4, 20), (12, 20)])
        CellConstraints.enforceHires(&buffer, palette: .colodore)
        XCTAssertEqual(Set(buffer.indices), [0, 4], "the 20/20 tie must resolve to index 4")
        XCTAssertEqual(Array(buffer.indices[0..<24]), Array(repeating: 0, count: 24))
        XCTAssertEqual(Array(buffer.indices[24..<44]), Array(repeating: 4, count: 20))
    }

    func testHiresLeavesALegalCellUntouched() {
        let original = runs(width: 8, height: 8, [(3, 40), (9, 24)])
        var buffer = original
        CellConstraints.enforceHires(&buffer, palette: .colodore)
        XCTAssertEqual(buffer, original)
    }

    func testHiresTreatsEachCellIndependently() {
        // Two 8×8 cells side by side in one 16×8 buffer, with disjoint colour
        // sets. If the implementation counted frequencies over the whole buffer
        // instead of per cell, the left cell (2 and 4, 32 pixels each) would win
        // outright and the right cell would be wiped.
        //
        // Every row is [2,2,2,2, 4,4,4,4, 7,7,7,7,7, 13,13, 15], so over the
        // eight rows the right cell holds 7 → 40, 13 → 16, 15 → 8: the fifteens
        // are the ones that must move.
        var indices: [UInt8] = []
        for _ in 0..<8 {
            indices.append(contentsOf: repeatElement(2, count: 4))
            indices.append(contentsOf: repeatElement(4, count: 4))
            indices.append(contentsOf: repeatElement(7, count: 5))
            indices.append(contentsOf: repeatElement(13, count: 2))
            indices.append(contentsOf: repeatElement(15, count: 1))
        }
        var buffer = IndexBuffer(width: 16, height: 8, indices: indices)

        CellConstraints.enforceHires(&buffer, palette: .colodore)

        XCTAssertEqual(
            distinctIndices(in: buffer, originX: 0, originY: 0, width: 8, height: 8), [2, 4])
        XCTAssertEqual(
            distinctIndices(in: buffer, originX: 8, originY: 0, width: 8, height: 8), [7, 13])
    }

    // MARK: - (c) Multicolor background selection

    func testMulticolorBackgroundBreaksAGlobalTieTowardTheLowerIndex() {
        // Exactly half the 160×200 buffer is index 3, the other half index 5:
        // 16000 pixels each. The lower index must win.
        let half = 160 * 100
        var buffer = runs(width: 160, height: 200, [(3, half), (5, half)])
        let background = CellConstraints.enforceMulticolor(&buffer, palette: .colodore)
        XCTAssertEqual(background, 3)
        // Neither colour is dropped: every cell holds a single index, which is
        // well inside background + 3.
        XCTAssertEqual(Set(buffer.indices), [3, 5])
    }

    func testMulticolorBackgroundIsTheGlobalNotPerCellWinner() {
        // 160×200. Rows 0…7 — the whole top row of cells — are index 1; every
        // row below alternates 8 and 2 in 4-pixel runs, so each of those cells
        // is uniformly one or the other. Counts over the buffer: 1 → 1280,
        // 8 → 15360, 2 → 15360, and the 8/2 tie resolves to the lower index.
        //
        // So the background is 2. An implementation that sampled the first cell
        // (or took a per-cell majority and voted) would answer 1.
        var indices: [UInt8] = Array(repeating: 1, count: 160 * 8)
        for row in 8..<200 {
            for cell in 0..<40 {
                let value: UInt8 = (row / 8 + cell) % 2 == 0 ? 8 : 2
                indices.append(contentsOf: repeatElement(value, count: 4))
            }
        }
        var buffer = IndexBuffer(width: 160, height: 200, indices: indices)
        let background = CellConstraints.enforceMulticolor(&buffer, palette: .colodore)
        XCTAssertEqual(background, 2)
    }

    func testMulticolorAlwaysKeepsTheBackgroundEvenWhenItIsRareInACell() {
        // An 8×8 buffer, i.e. two 4×8 cells. The left cell is solid index 0, so
        // 0 wins the buffer (33 pixels) and becomes the background. The right
        // cell contains exactly one background pixel and five other colours:
        //   3 → 9, 5 → 9, 7 → 6, 9 → 4, 11 → 3, 0 → 1.
        // The background must survive there as one of the four allowed entries
        // even though it is the *rarest* index in that cell, so the cell keeps
        // {0, 3, 5, 7} and the nines and elevens move.
        let right: [[UInt8]] = [
            [0, 3, 3, 3],
            [3, 3, 3, 3],
            [3, 3, 5, 5],
            [5, 5, 5, 5],
            [5, 5, 5, 7],
            [7, 7, 7, 7],
            [7, 9, 9, 9],
            [9, 11, 11, 11],
        ]
        var indices: [UInt8] = []
        for row in right {
            indices.append(contentsOf: repeatElement(0, count: 4))
            indices.append(contentsOf: row)
        }
        var buffer = IndexBuffer(width: 8, height: 8, indices: indices)

        let background = CellConstraints.enforceMulticolor(&buffer, palette: .colodore)

        XCTAssertEqual(background, 0)
        XCTAssertEqual(buffer[4, 0], 0, "the lone background pixel must not be remapped")
        XCTAssertEqual(
            distinctIndices(in: buffer, originX: 4, originY: 0, width: 4, height: 8),
            [0, 3, 5, 7])
        XCTAssertEqual(
            distinctIndices(in: buffer, originX: 0, originY: 0, width: 4, height: 8), [0])
    }

    func testMulticolorBreaksForegroundFrequencyTiesTowardTheLowerIndex() {
        // A single 4×8 cell. Background 1 (16 px, the global winner). The other
        // 16 pixels split 6/4/3/3 across indices 2, 4, 6, 8, so the third
        // foreground slot is a 3–3 tie between 6 and 8 and must go to 6.
        var buffer = runs(width: 4, height: 8, [(1, 16), (2, 6), (4, 4), (6, 3), (8, 3)])
        let background = CellConstraints.enforceMulticolor(&buffer, palette: .colodore)
        XCTAssertEqual(background, 1)
        XCTAssertEqual(Set(buffer.indices), [1, 2, 4, 6], "the 3/3 tie must resolve to index 6")
    }

    func testMulticolorLeavesALegalCellUntouched() {
        let original = runs(width: 4, height: 8, [(0, 14), (1, 8), (2, 6), (3, 4)])
        var buffer = original
        let background = CellConstraints.enforceMulticolor(&buffer, palette: .colodore)
        XCTAssertEqual(background, 0)
        XCTAssertEqual(buffer, original)
    }

    // MARK: - (d) Idempotence

    func testHiresIsIdempotentOnNoise() {
        let image = noise(width: 320, height: 200)
        var once = Quantizer.quantize(image, palette: .colodore, dither: .none)
        CellConstraints.enforceHires(&once, palette: .colodore)
        var twice = once
        CellConstraints.enforceHires(&twice, palette: .colodore)
        XCTAssertEqual(once, twice)
    }

    func testMulticolorIsIdempotentOnNoise() {
        let image = noise(width: 160, height: 200)
        var once = Quantizer.quantize(image, palette: .colodore, dither: .none)
        let firstBackground = CellConstraints.enforceMulticolor(&once, palette: .colodore)
        var twice = once
        let secondBackground = CellConstraints.enforceMulticolor(&twice, palette: .colodore)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(firstBackground, secondBackground)
    }

    func testEnforcementIsIdempotentOnTheHandBuiltFixtures() {
        var hires = runs(width: 8, height: 8, [(1, 30), (6, 20), (2, 14)])
        CellConstraints.enforceHires(&hires, palette: .colodore)
        var hiresAgain = hires
        CellConstraints.enforceHires(&hiresAgain, palette: .colodore)
        XCTAssertEqual(hires, hiresAgain)

        var multi = runs(
            width: 4, height: 8, [(0, 1), (3, 10), (5, 9), (7, 7), (9, 4), (11, 1)])
        _ = CellConstraints.enforceMulticolor(&multi, palette: .colodore)
        var multiAgain = multi
        _ = CellConstraints.enforceMulticolor(&multiAgain, palette: .colodore)
        XCTAssertEqual(multi, multiAgain)
    }

    // MARK: - Determinism and palette sensitivity

    func testEnforcementIsDeterministic() {
        let image = noise(width: 320, height: 200)
        let quantized = Quantizer.quantize(image, palette: .pepto, dither: .none)
        var first = quantized
        var second = quantized
        CellConstraints.enforceHires(&first, palette: .pepto)
        CellConstraints.enforceHires(&second, palette: .pepto)
        XCTAssertEqual(first, second)
    }

    func testEnforcementHandlesAnEmptyBuffer() {
        var hires = IndexBuffer(width: 0, height: 0, indices: [])
        CellConstraints.enforceHires(&hires, palette: .colodore)
        XCTAssertEqual(hires.indices, [])

        var multi = IndexBuffer(width: 0, height: 0, indices: [])
        let background = CellConstraints.enforceMulticolor(&multi, palette: .colodore)
        XCTAssertEqual(multi.indices, [])
        XCTAssertEqual(background, 0)
    }

    func testPartialCellsAtTheEdgesAreConstrainedToo() {
        // 10×9 is not a whole number of 8×8 cells: the right column of cells is
        // 2 px wide and the bottom row 1 px tall. Nothing downstream feeds such
        // a size today, but a partial cell must still be constrained rather than
        // skipped or read out of bounds.
        var indices: [UInt8] = []
        for y in 0..<9 {
            for x in 0..<10 {
                indices.append(UInt8((x &+ y) % 16))
            }
        }
        var buffer = IndexBuffer(width: 10, height: 9, indices: indices)
        CellConstraints.enforceHires(&buffer, palette: .colodore)
        forEachCell(buffer, width: 8, height: 8) { x, y, distinct in
            XCTAssertLessThanOrEqual(distinct.count, 2, "partial cell at (\(x),\(y))")
        }
    }
}
