import XCTest
@testable import C64Kit

final class PackingTests: XCTestCase {

    // MARK: - Helpers

    /// A 320×200 hires buffer filled with `fill`, then overwritten by `edits`.
    private func hiresBuffer(fill: UInt8, _ edits: (inout IndexBuffer) -> Void = { _ in })
        -> IndexBuffer
    {
        var buffer = IndexBuffer(
            width: 320, height: 200, indices: Array(repeating: fill, count: 320 * 200))
        edits(&buffer)
        return buffer
    }

    /// A 160×200 multicolour buffer filled with `fill`, then overwritten by `edits`.
    private func multicolorBuffer(fill: UInt8, _ edits: (inout IndexBuffer) -> Void = { _ in })
        -> IndexBuffer
    {
        var buffer = IndexBuffer(
            width: 160, height: 200, indices: Array(repeating: fill, count: 160 * 200))
        edits(&buffer)
        return buffer
    }

    /// Re-derives the palette index of every rendered pixel by exact RGB
    /// equality, which is the only honest way to check that `render` decoded
    /// the packed bytes rather than smuggling the input through: a rendered
    /// pixel must be *literally* one of the sixteen table entries.
    private func indices(of rendered: RGBBuffer, palette: C64Palette) -> IndexBuffer {
        let colors = palette.colors
        var indices: [UInt8] = []
        indices.reserveCapacity(rendered.pixels.count)
        for pixel in rendered.pixels {
            guard let index = colors.firstIndex(of: pixel) else {
                XCTFail("rendered pixel \(pixel) is not a \(palette) palette colour")
                return IndexBuffer(width: 0, height: 0, indices: [])
            }
            indices.append(UInt8(index))
        }
        return IndexBuffer(width: rendered.width, height: rendered.height, indices: indices)
    }

    // MARK: - (a) Sizes and which fields each mode carries

    func testHiresPackHasTheRightSizesAndNoMulticolorFields() {
        let image = C64Image.pack(hires: hiresBuffer(fill: 0))
        XCTAssertEqual(image.mode, .hires)
        XCTAssertEqual(image.bitmap.count, 8000)
        XCTAssertEqual(image.screenRAM.count, 1000)
        XCTAssertNil(image.colorRAM, "hires has no colour RAM")
        XCTAssertNil(image.background, "hires has no shared background register")
    }

    func testMulticolorPackHasTheRightSizesAndCarriesTheBackground() {
        let image = C64Image.pack(multicolor: multicolorBuffer(fill: 9), background: 9)
        XCTAssertEqual(image.mode, .multicolor)
        XCTAssertEqual(image.bitmap.count, 8000)
        XCTAssertEqual(image.screenRAM.count, 1000)
        XCTAssertEqual(image.colorRAM?.count, 1000)
        XCTAssertEqual(image.background, 9)
    }

    func testMulticolorColorRAMLeavesTheHighNibbleZero() throws {
        // The VIC-II only reads the low nibble of colour RAM; the high nibble is
        // open bus on real hardware and must be written as 0 so exported files
        // compare byte-for-byte against other tools' output.
        var buffer = multicolorBuffer(fill: 0)
        for y in 0..<200 {
            for x in 0..<160 {
                // Three non-background colours per 4×8 cell, so every cell fills
                // its colour-RAM slot with a high index (13, 14 or 15) — the
                // values whose high nibble would show if it were not masked.
                buffer[x, y] = [0, 13, 14, 15][x % 4]
            }
        }
        let image = C64Image.pack(multicolor: buffer, background: 0)
        let colorRAM = try XCTUnwrap(image.colorRAM)
        XCTAssertEqual(Set(colorRAM), [15], "third slot is index 15 in every cell")
        for byte in colorRAM {
            XCTAssertEqual(byte & 0xF0, 0, "colour RAM high nibble must be 0")
        }
    }

    // MARK: - (b) A hand-computed hires cell

    func testHiresPacksAHandComputedCell() {
        // 320×200, all index 6 (blue), except cell (row 0, col 0) whose left
        // four columns are index 1 (white). That cell is a 32/32 split, so the
        // frequency tie breaks toward the lower index: foreground = 1.
        // Foreground pixels set their bit, and bit 7 is the leftmost pixel, so
        // every row of the cell packs as %11110000.
        let buffer = hiresBuffer(fill: 6) { buffer in
            for y in 0..<8 {
                for x in 0..<4 { buffer[x, y] = 1 }
            }
        }
        let image = C64Image.pack(hires: buffer)

        for offset in 0..<8 {
            XCTAssertEqual(image.bitmap[offset], 0xF0, "bitmap byte \(offset)")
        }
        XCTAssertEqual(image.screenRAM[0], 0x16, "foreground 1 in the upper nibble, background 6")

        // Cell (row 0, col 1) is a single colour: the bits are all 0 and the
        // colour is written to both nibbles, so it reads back the same whichever
        // nibble the hardware picks.
        for offset in 8..<16 {
            XCTAssertEqual(image.bitmap[offset], 0x00, "bitmap byte \(offset)")
        }
        XCTAssertEqual(image.screenRAM[1], 0x66)
    }

    func testHiresPutsTheMoreFrequentIndexInTheForegroundNibble() {
        // A cell of 40 index-3 pixels and 24 index-9 pixels: no tie, so the
        // rule — not the tie-break — decides. 3 is the foreground.
        let buffer = hiresBuffer(fill: 3) { buffer in
            for y in 0..<3 {
                for x in 0..<8 { buffer[x, y] = 9 }
            }
        }
        let image = C64Image.pack(hires: buffer)
        XCTAssertEqual(image.screenRAM[0], 0x39)
        // Rows 0…2 are entirely background, rows 3…7 entirely foreground.
        XCTAssertEqual(Array(image.bitmap[0..<8]), [0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    // MARK: - (c) A hand-computed multicolour cell

    func testMulticolorPacksAHandComputedCell() {
        // 160×200, everything the background (index 0), except cell (0,0) whose
        // four columns are indices 0, 2, 5, 7 on every row. The three
        // non-background indices tie at eight pixels each, so the ordering is
        // the lower-index tie-break: 2 → %01, 5 → %10, 7 → %11. Leftmost pixel
        // in bits 7–6 gives %00 %01 %10 %11 = 0b00011011.
        let buffer = multicolorBuffer(fill: 0) { buffer in
            for y in 0..<200 where y < 8 {
                buffer[1, y] = 2
                buffer[2, y] = 5
                buffer[3, y] = 7
            }
        }
        let image = C64Image.pack(multicolor: buffer, background: 0)

        for offset in 0..<8 {
            XCTAssertEqual(image.bitmap[offset], 0b0001_1011, "bitmap byte \(offset)")
        }
        XCTAssertEqual(image.screenRAM[0], 0x25, "%01 → upper nibble 2, %10 → lower nibble 5")
        XCTAssertEqual(image.colorRAM?[0], 0x07, "%11 → colour RAM 7")
    }

    func testMulticolorOrdersSlotsByDescendingCount() {
        // One 4×8 cell (the rest of the screen is background). Column counts
        // over eight rows: index 4 → 8, index 3 → 16, index 11 → 8. So the
        // ordering is 3 (16), then the 8/8 tie between 4 and 11 broken toward 4,
        // then 11: %01 = 3, %10 = 4, %11 = 11.
        let buffer = multicolorBuffer(fill: 0) { buffer in
            for y in 0..<8 {
                buffer[0, y] = 4
                buffer[1, y] = 3
                buffer[2, y] = 3
                buffer[3, y] = 11
            }
        }
        let image = C64Image.pack(multicolor: buffer, background: 0)
        XCTAssertEqual(image.screenRAM[0], 0x34)
        XCTAssertEqual(image.colorRAM?[0], 0x0B)
        XCTAssertEqual(image.bitmap[0], 0b1001_0111, "%10 %01 %01 %11")
    }

    func testMulticolorLeavesUnusedSlotsZero() {
        // A cell holding only the background: no slot is claimed, so screen and
        // colour RAM are 0 and every pixel packs as %00.
        let image = C64Image.pack(multicolor: multicolorBuffer(fill: 5), background: 5)
        XCTAssertEqual(Set(image.bitmap), [0])
        XCTAssertEqual(Set(image.screenRAM), [0])
        XCTAssertEqual(Set(image.colorRAM ?? []), [0])
    }

    func testMulticolorTreatsBackgroundPixelsAsZeroEvenWhereASlotWouldMatch() {
        // Background 3 with unclaimed slots defaulting to 0, and a cell that
        // also contains real index-0 pixels. The zeros must pack as %01 (the
        // first claimed slot), not collide with the empty slots, and the
        // background pixels must stay %00.
        let buffer = multicolorBuffer(fill: 3) { buffer in
            for y in 0..<8 { buffer[2, y] = 0 }
        }
        let image = C64Image.pack(multicolor: buffer, background: 3)
        XCTAssertEqual(image.screenRAM[0], 0x00, "%01 → index 0, %10 unused")
        XCTAssertEqual(image.colorRAM?[0], 0x00, "%11 unused")
        XCTAssertEqual(image.bitmap[0], 0b0000_0100, "third pixel is %01, the rest background")

        // And it round-trips: the packed bytes alone say index 0 there and
        // index 3 elsewhere.
        let rendered = indices(of: image.render(palette: .colodore), palette: .colodore)
        XCTAssertEqual(rendered, buffer)
    }

    // MARK: - (d) pack → render round-trip on constrained noise

    func testHiresRoundTripsConstrainedNoise() {
        for palette in C64Palette.allCases {
            var buffer = Quantizer.quantize(
                NoiseFixture.rgb(width: 320, height: 200), palette: palette, dither: .none)
            CellConstraints.enforceHires(&buffer, palette: palette)

            let rendered = C64Image.pack(hires: buffer).render(palette: palette)
            XCTAssertEqual(rendered.width, 320)
            XCTAssertEqual(rendered.height, 200)
            XCTAssertEqual(
                indices(of: rendered, palette: palette), buffer,
                "hires round-trip lost pixels on \(palette)")
        }
    }

    func testMulticolorRoundTripsConstrainedNoise() {
        for palette in C64Palette.allCases {
            var buffer = Quantizer.quantize(
                NoiseFixture.rgb(width: 160, height: 200), palette: palette, dither: .none)
            let background = CellConstraints.enforceMulticolor(&buffer, palette: palette)

            let image = C64Image.pack(multicolor: buffer, background: background)
            let rendered = image.render(palette: palette)
            XCTAssertEqual(rendered.width, 160)
            XCTAssertEqual(rendered.height, 200)
            XCTAssertEqual(
                indices(of: rendered, palette: palette), buffer,
                "multicolour round-trip lost pixels on \(palette)")
        }
    }

    func testPackingIsDeterministic() {
        var hires = Quantizer.quantize(
            NoiseFixture.rgb(width: 320, height: 200), palette: .colodore, dither: .none)
        CellConstraints.enforceHires(&hires, palette: .colodore)
        XCTAssertEqual(C64Image.pack(hires: hires), C64Image.pack(hires: hires))

        var multi = Quantizer.quantize(
            NoiseFixture.rgb(width: 160, height: 200), palette: .colodore, dither: .none)
        let background = CellConstraints.enforceMulticolor(&multi, palette: .colodore)
        XCTAssertEqual(
            C64Image.pack(multicolor: multi, background: background),
            C64Image.pack(multicolor: multi, background: background))
    }

    // MARK: - (e) Bitmap addressing

    func testBitmapAddressingPutsASinglePixelInTheRightByteAndBit() {
        // One index-7 pixel at (12, 10) on an otherwise index-0 screen. It lands
        // in cell row 1, cell column 1, row 2 of that cell — byte
        // 1*320 + 1*8 + 2 = 330 — and at x % 8 == 4, i.e. bit 3, since bit 7 is
        // the leftmost pixel of the byte.
        //
        // Which *value* that byte takes follows from the packing rule: the cell
        // holds 63 index-0 pixels against one index-7, so index 0 is the more
        // frequent and therefore the foreground, and it is the foreground that
        // sets bits. The cell is 0xFF with bit 3 of byte 330 cleared, rather
        // than 0x00 with that bit set. (The plan's sketch of this test predicted
        // the complement — it assumed the lone pixel would be the foreground.
        // The rendered image is identical either way; only the byte pattern
        // differs, and the assertions below pin the rule as written.)
        let buffer = hiresBuffer(fill: 0) { $0[12, 10] = 7 }
        let image = C64Image.pack(hires: buffer)

        let offset = C64Image.bitmapOffset(cellRow: 1, cellColumn: 1, rowInCell: 2)
        XCTAssertEqual(offset, 330)
        XCTAssertEqual(image.bitmap[offset], 0b1111_0111, "bit 3 clear → the index-7 pixel")
        for other in 328..<336 where other != offset {
            XCTAssertEqual(image.bitmap[other], 0xFF, "bitmap byte \(other)")
        }
        for other in 0..<8000 where !(328..<336).contains(other) {
            XCTAssertEqual(image.bitmap[other], 0x00, "bitmap byte \(other) is outside the cell")
        }
        XCTAssertEqual(image.screenRAM[1 * 40 + 1], 0x07, "foreground 0, background 7")
        XCTAssertEqual(Set(image.screenRAM.enumerated().filter { $0.offset != 41 }.map(\.element)),
                       [0x00], "every other cell is a single index-0 colour")

        // The pixel survives the round trip at exactly that coordinate.
        let rendered = image.render(palette: .colodore)
        XCTAssertEqual(rendered[12, 10], C64Palette.colodore.colors[7])
        XCTAssertEqual(rendered[11, 10], C64Palette.colodore.colors[0])
        XCTAssertEqual(rendered[13, 10], C64Palette.colodore.colors[0])
        XCTAssertEqual(rendered[12, 9], C64Palette.colodore.colors[0])
        XCTAssertEqual(rendered[12, 11], C64Palette.colodore.colors[0])
    }

    func testBitmapOffsetCoversTheWholeBitmapExactlyOnce() {
        // The cell-interleaved layout is the one piece of C64 addressing that is
        // easy to get subtly wrong, so pin that it is a bijection onto 0…7999.
        var seen = Set<Int>()
        for cellRow in 0..<25 {
            for cellColumn in 0..<40 {
                for rowInCell in 0..<8 {
                    let offset = C64Image.bitmapOffset(
                        cellRow: cellRow, cellColumn: cellColumn, rowInCell: rowInCell)
                    XCTAssertTrue((0..<8000).contains(offset), "offset \(offset) out of range")
                    seen.insert(offset)
                }
            }
        }
        XCTAssertEqual(seen.count, 8000)
    }

    // MARK: - Rendering reads only the packed bytes

    func testRenderIgnoresEverythingButThePackedArrays() throws {
        // The cardinal project rule is that the preview comes from the packed
        // bytes. Editing the packed bytes behind `pack`'s back must therefore
        // change the preview, and change only the pixels those bytes own — a
        // render that consulted a cached `IndexBuffer` instead would show the
        // original everywhere.
        let original = C64Image.pack(multicolor: multicolorBuffer(fill: 0), background: 0)
        var bitmap = original.bitmap
        bitmap[C64Image.bitmapOffset(cellRow: 3, cellColumn: 2, rowInCell: 5)] = 0b1100_0000
        var screenRAM = original.screenRAM
        screenRAM[3 * 40 + 2] = 0xA4
        var colorRAM = try XCTUnwrap(original.colorRAM)
        colorRAM[3 * 40 + 2] = 0x0C

        let edited = C64Image(
            mode: .multicolor, bitmap: bitmap, screenRAM: screenRAM,
            colorRAM: colorRAM, background: original.background)
        let rendered = edited.render(palette: .colodore)

        // Cell column 2 starts at x = 8, cell row 3 row 5 is y = 29. The
        // leftmost pixel of the byte is %11 → colour RAM's low nibble, 12.
        XCTAssertEqual(rendered[8, 29], C64Palette.colodore.colors[12])
        // The other three pixels of that byte are %00 → background, so the
        // screen nibbles that were also edited stay unreachable and invisible.
        let untouched = original.render(palette: .colodore)
        for y in 0..<200 {
            for x in 0..<160 where !(x == 8 && y == 29) {
                XCTAssertEqual(rendered[x, y], untouched[x, y], "pixel (\(x),\(y))")
            }
        }
    }

    func testRenderUsesTheRequestedPalette() {
        let buffer = hiresBuffer(fill: 2)
        let image = C64Image.pack(hires: buffer)
        XCTAssertEqual(image.render(palette: .colodore).pixels[0], C64Palette.colodore.colors[2])
        XCTAssertEqual(image.render(palette: .pepto).pixels[0], C64Palette.pepto.colors[2])
    }
}
