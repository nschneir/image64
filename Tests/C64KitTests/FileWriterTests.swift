import XCTest
@testable import C64Kit

final class FileWriterTests: XCTestCase {

    // MARK: - Fixtures

    /// The hand-computed multicolour cell from `PackingTests`, on a nonzero
    /// background so the background byte at the end of a Koala file is
    /// distinguishable from padding.
    ///
    /// Cell (0,0) holds indices 6 (the background), 2, 5, 7 across its four
    /// columns on every row, so it packs to bitmap `%00011011`, screen `$25`,
    /// colour RAM `$07`. Cell (1,1) — the one that owns bitmap byte 330 — gets a
    /// single index-2 column so that byte is nonzero too, which is what makes the
    /// offset assertions bite.
    private func multicolorFixture() -> C64Image {
        var buffer = IndexBuffer(
            width: 160, height: 200, indices: Array(repeating: 6, count: 160 * 200))
        for y in 0..<8 {
            buffer[1, y] = 2
            buffer[2, y] = 5
            buffer[3, y] = 7
        }
        // Cell row 1, cell column 1 covers x 4…7, y 8…15. Its leftmost column
        // becomes the cell's only claimed slot, %01, so every one of its eight
        // bitmap bytes is 0b0100_0000 — including byte 330 (rowInCell 2).
        for y in 8..<16 { buffer[4, y] = 2 }
        return C64Image.pack(multicolor: buffer, background: 6)
    }

    /// The hand-computed hires cell from `PackingTests`: cell (0,0) is four
    /// columns of index 1 against four of index 6, a 32/32 tie that breaks toward
    /// the lower index, so every row packs to `$F0` with screen byte `$16`. The
    /// lone index-7 pixel at (12, 10) puts a nonzero byte at bitmap offset 330.
    private func hiresFixture() -> C64Image {
        var buffer = IndexBuffer(
            width: 320, height: 200, indices: Array(repeating: 6, count: 320 * 200))
        for y in 0..<8 {
            for x in 0..<4 { buffer[x, y] = 1 }
        }
        buffer[12, 10] = 7
        return C64Image.pack(hires: buffer)
    }

    // MARK: - Fixture self-checks
    //
    // The layout assertions below are only meaningful if the fixtures really do
    // carry the bytes the comments claim, so pin them here rather than trusting
    // the packer to keep producing them.

    func testFixturesCarryTheHandComputedBytes() throws {
        let multicolor = multicolorFixture()
        XCTAssertEqual(multicolor.bitmap[0], 0b0001_1011)
        XCTAssertEqual(multicolor.screenRAM[0], 0x25)
        XCTAssertEqual(try XCTUnwrap(multicolor.colorRAM)[0], 0x07)
        XCTAssertEqual(multicolor.bitmap[330], 0b0100_0000)
        XCTAssertEqual(multicolor.background, 6)

        let hires = hiresFixture()
        XCTAssertEqual(hires.bitmap[0], 0xF0)
        XCTAssertEqual(hires.screenRAM[0], 0x16)
        XCTAssertEqual(hires.bitmap[330], 0b1111_0111)
    }

    // MARK: - (a) Koala

    func testKoalaLayout() throws {
        let image = multicolorFixture()
        let data = try C64FileWriter.data(for: image, format: .koala)

        XCTAssertEqual(data.count, 10003)
        // Load address $6000, little-endian: low byte first.
        XCTAssertEqual(data[0], 0x00)
        XCTAssertEqual(data[1], 0x60)

        XCTAssertEqual(data[2], image.bitmap[0])
        XCTAssertEqual(data[2 + 330], image.bitmap[330])
        XCTAssertEqual(data[8001], image.bitmap[7999])
        XCTAssertEqual(data[8002], image.screenRAM[0])
        XCTAssertEqual(data[9001], image.screenRAM[999])
        XCTAssertEqual(data[9002], try XCTUnwrap(image.colorRAM)[0])
        XCTAssertEqual(data[10001], try XCTUnwrap(image.colorRAM)[999])
        XCTAssertEqual(data[10002], try XCTUnwrap(image.background))
        XCTAssertEqual(data[10002], 6, "the background byte is the image's, not padding")
    }

    func testKoalaSectionsAreTheImagesArraysVerbatim() throws {
        let image = multicolorFixture()
        let data = try C64FileWriter.data(for: image, format: .koala)

        XCTAssertEqual(Array(data[2..<8002]), image.bitmap)
        XCTAssertEqual(Array(data[8002..<9002]), image.screenRAM)
        XCTAssertEqual(Array(data[9002..<10002]), try XCTUnwrap(image.colorRAM))
    }

    // MARK: - (b) Art Studio

    func testArtStudioLayout() throws {
        let image = hiresFixture()
        let data = try C64FileWriter.data(for: image, format: .artStudio)

        XCTAssertEqual(data.count, 9009)
        // Load address $2000.
        XCTAssertEqual(data[0], 0x00)
        XCTAssertEqual(data[1], 0x20)

        XCTAssertEqual(data[2], image.bitmap[0])
        XCTAssertEqual(data[2 + 330], image.bitmap[330])
        XCTAssertEqual(data[8001], image.bitmap[7999])
        XCTAssertEqual(data[8002], image.screenRAM[0])
        XCTAssertEqual(data[8002], 0x16, "the screen byte is the image's, not padding")
        XCTAssertEqual(data[9001], image.screenRAM[999])

        for offset in 9002...9008 {
            XCTAssertEqual(data[offset], 0x00, "trailing byte \(offset) must be zero")
        }
    }

    func testArtStudioSectionsAreTheImagesArraysVerbatim() throws {
        let image = hiresFixture()
        let data = try C64FileWriter.data(for: image, format: .artStudio)

        XCTAssertEqual(Array(data[2..<8002]), image.bitmap)
        XCTAssertEqual(Array(data[8002..<9002]), image.screenRAM)
        XCTAssertEqual(Array(data[9002..<9009]), [UInt8](repeating: 0, count: 7))
    }

    // MARK: - (c) Format inference

    func testInferFormatMapsTheTwoKnownExtensions() {
        XCTAssertEqual(C64FileWriter.inferFormat(fromExtension: "koa"), .koala)
        XCTAssertEqual(C64FileWriter.inferFormat(fromExtension: "art"), .artStudio)
    }

    func testInferFormatIsCaseInsensitive() {
        XCTAssertEqual(C64FileWriter.inferFormat(fromExtension: "KOA"), .koala)
        XCTAssertEqual(C64FileWriter.inferFormat(fromExtension: "Koa"), .koala)
        XCTAssertEqual(C64FileWriter.inferFormat(fromExtension: "ART"), .artStudio)
        XCTAssertEqual(C64FileWriter.inferFormat(fromExtension: "Art"), .artStudio)
    }

    func testInferFormatRejectsAnythingElse() {
        // Including the near-misses: a leading dot is not part of an extension as
        // `URL.pathExtension` reports it, and "koala" is the format's name rather
        // than its suffix.
        for extensionText in ["png", "jpg", "", "koala", ".koa", "ko", "arts", "prg"] {
            XCTAssertNil(
                C64FileWriter.inferFormat(fromExtension: extensionText),
                "\"\(extensionText)\" is not a writable format")
        }
    }

    func testFormatRawValuesAreTheFileExtensions() {
        XCTAssertEqual(C64FileFormat.koala.rawValue, "koa")
        XCTAssertEqual(C64FileFormat.artStudio.rawValue, "art")
        XCTAssertEqual(C64FileFormat.allCases, [.koala, .artStudio])
        // Every case must be inferable from its own raw value, so adding a
        // format cannot leave the extension table behind.
        for format in C64FileFormat.allCases {
            XCTAssertEqual(C64FileWriter.inferFormat(fromExtension: format.rawValue), format)
        }
    }

    func testEachFormatDeclaresTheModeItEncodes() {
        XCTAssertEqual(C64FileFormat.koala.requiredMode, .multicolor)
        XCTAssertEqual(C64FileFormat.artStudio.requiredMode, .hires)
    }

    func testDeclaredByteCountsMatchWhatIsWritten() throws {
        XCTAssertEqual(C64FileWriter.koalaByteCount, 10003)
        XCTAssertEqual(C64FileWriter.artStudioByteCount, 9009)
        XCTAssertEqual(
            try C64FileWriter.data(for: multicolorFixture(), format: .koala).count,
            C64FileWriter.koalaByteCount)
        XCTAssertEqual(
            try C64FileWriter.data(for: hiresFixture(), format: .artStudio).count,
            C64FileWriter.artStudioByteCount)
    }

    // MARK: - (d) Mode mismatch

    func testKoalaRejectsAHiresImage() {
        XCTAssertThrowsError(try C64FileWriter.data(for: hiresFixture(), format: .koala)) { error in
            XCTAssertEqual(
                error as? C64FileError,
                .modeMismatch(expected: .multicolor, actual: .hires))
        }
    }

    func testArtStudioRejectsAMulticolorImage() {
        let image = multicolorFixture()
        XCTAssertThrowsError(try C64FileWriter.data(for: image, format: .artStudio)) { error in
            XCTAssertEqual(
                error as? C64FileError,
                .modeMismatch(expected: .hires, actual: .multicolor))
        }
    }

    // MARK: - Determinism

    func testWritingIsDeterministic() throws {
        let multicolor = multicolorFixture()
        XCTAssertEqual(
            try C64FileWriter.data(for: multicolor, format: .koala),
            try C64FileWriter.data(for: multicolor, format: .koala))

        let hires = hiresFixture()
        XCTAssertEqual(
            try C64FileWriter.data(for: hires, format: .artStudio),
            try C64FileWriter.data(for: hires, format: .artStudio))
    }
}
