import Foundation
import TestSupport
import XCTest

@testable import C64Kit

/// Tests for the self-displaying PRG.
///
/// A `.koa` or `.art` is a memory dump: something else has to load it and set
/// the VIC up. A PRG is the opposite — it is the program that does the setting
/// up, so the only interesting questions are whether a C64 would *run* it and
/// whether what it copies into place is the picture. The first is pinned by the
/// BASIC stub and the register stores; the second by `simulate`, which loads the
/// file into a flat 64 KB array and performs the routine's copies in the
/// routine's own order and direction.
///
/// That simulation is the load-bearing test here. The file loads at `$0801` and
/// runs to roughly `$2FAC`, which straddles the `$2000` the bitmap has to end up
/// at, so the bitmap copy overwrites its own source as it goes. It is correct
/// only because it runs downward; `testAnAscendingBitmapCopyOfTheSameLayoutWouldCorruptThePicture`
/// exists to prove that the overlap is real rather than theoretical, so a later
/// change that "tidied" the loop into an ascending one could not pass.
final class PrgWriterTests: XCTestCase {

    // MARK: - Scratch directory

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("image64-prg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// A genuinely converted picture rather than a hand-built one: the whole
    /// point of the simulation below is that eight thousand *real* bitmap bytes
    /// survive a copy that overlaps them, and a fixture of mostly-identical
    /// bytes would hide an off-by-one that shifted the block.
    private func convertedImage(mode: BitmapMode) throws -> C64Image {
        let source = directory.appendingPathComponent("source-\(mode.rawValue).png")
        TestImageFactory.makePNG(
            width: 640, height: 400,
            horizontalGradient: RGB(r: 0, g: 32, b: 200), to: RGB(r: 255, g: 220, b: 40),
            at: source)

        var settings = ConversionSettings()
        settings.mode = mode
        return try ConversionOperation.run(
            ConversionRequest(inputURL: source, settings: settings)
        ).image
    }

    // MARK: - (a) Load address

    func testTheFileStartsWithTheLoadAddress0801() throws {
        for mode in [BitmapMode.multicolor, .hires] {
            let data = C64PrgWriter.data(for: try convertedImage(mode: mode))
            XCTAssertEqual(data[0], 0x01, "\(mode): low byte of $0801 first")
            XCTAssertEqual(data[1], 0x08, "\(mode): high byte of $0801 second")
        }
    }

    // MARK: - (b) The BASIC stub

    /// The twelve bytes of `10 SYS 2061`, derived rather than copied from a
    /// tutorial:
    ///
    /// | address | bytes         | meaning |
    /// |---------|---------------|---------|
    /// | `$0801` | `0B 08`       | link to the next line — `$080B`, where the terminator sits |
    /// | `$0803` | `0A 00`       | line number 10, low byte first |
    /// | `$0805` | `9E`          | the `SYS` token |
    /// | `$0806` | `32 30 36 31` | `"2061"` in PETSCII, which here is ASCII |
    /// | `$080A` | `00`          | end of line |
    /// | `$080B` | `00 00`       | end of program — a null link pointer |
    ///
    /// The line ends at `$080A`, so the next line would begin at `$080B`; that
    /// is the address the link points at, and the two zeroes there tell BASIC
    /// there is no next line. The stub therefore occupies `$0801…$080C`, and the
    /// machine code begins at `$080D` — 2061 decimal, which is what `SYS` is
    /// told to call. The argument and the layout are the same number written
    /// twice, which is why it is derived here instead of assumed.
    private static let basicStub: [UInt8] = [
        0x0B, 0x08, 0x0A, 0x00, 0x9E, 0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00,
    ]

    func testTheBASICStubIsThePinnedBytes() throws {
        for mode in [BitmapMode.multicolor, .hires] {
            let data = C64PrgWriter.data(for: try convertedImage(mode: mode))
            XCTAssertEqual(Array(data[2..<14]), Self.basicStub, "\(mode)")
        }
    }

    func testTheMachineCodeStartsAtTheAddressSYSIsGiven() throws {
        // 2061 is spelled out in the stub as ASCII; the layout has to agree.
        XCTAssertEqual(C64PrgWriter.layout(for: try convertedImage(mode: .hires)).routineAddress, 2061)
        XCTAssertEqual(0x080D, 2061)
    }

    // MARK: - (c) Simulated execution

    /// A flat 64 KB address space with the file loaded and the routine's copies
    /// performed.
    ///
    /// Not a 6502 emulator: it replicates the *copies* — the same source and
    /// target ranges, in the same order and the same direction the routine walks
    /// them — over one shared array, which is the only property that decides
    /// whether an overlapping copy survives. `descendingBitmap: false` performs
    /// the identical copy the wrong way round, which is how the overlap is shown
    /// to matter.
    private func simulate(
        _ prg: Data, layout: C64PrgWriter.Layout, descendingBitmap: Bool = true
    ) -> [UInt8] {
        var memory = [UInt8](repeating: 0, count: 65536)
        let loadAddress = Int(prg[0]) | Int(prg[1]) << 8
        for (offset, byte) in prg.dropFirst(2).enumerated() {
            memory[loadAddress + offset] = byte
        }

        // Screen and colour RAM: four 250-byte columns walked together, index by
        // index, which is what one `ldx`-driven loop over four `lda abs,x` /
        // `sta abs,x` pairs does.
        func copyThousand(from source: Int, to target: Int) {
            for index in 0..<250 {
                for column in 0..<4 {
                    memory[target + column * 250 + index] = memory[source + column * 250 + index]
                }
            }
        }
        copyThousand(from: layout.screenSource, to: 0x0400)
        if let colorSource = layout.colorSource {
            copyThousand(from: colorSource, to: 0xD800)
        }

        // The bitmap, last and downward: the routine walks 32 chunks of 250 from
        // the top chunk down, and each chunk from its last byte down, which over
        // the whole block is one strictly descending pass.
        let count = C64Image.bitmapByteCount
        let offsets = descendingBitmap
            ? Array(stride(from: count - 1, through: 0, by: -1))
            : Array(0..<count)
        for offset in offsets {
            memory[0x2000 + offset] = memory[layout.bitmapSource + offset]
        }
        return memory
    }

    func testRunningTheMulticolorProgramPutsThePictureWhereTheVICLooks() throws {
        let image = try convertedImage(mode: .multicolor)
        let layout = C64PrgWriter.layout(for: image)
        let memory = simulate(C64PrgWriter.data(for: image), layout: layout)

        XCTAssertEqual(Array(memory[0x2000..<0x3F40]), image.bitmap, "bitmap at $2000")
        XCTAssertEqual(Array(memory[0x0400..<0x07E8]), image.screenRAM, "screen RAM at $0400")
        XCTAssertEqual(
            Array(memory[0xD800..<0xDBE8]), try XCTUnwrap(image.colorRAM), "colour RAM at $D800")
    }

    func testRunningTheHiresProgramPutsThePictureWhereTheVICLooks() throws {
        let image = try convertedImage(mode: .hires)
        let layout = C64PrgWriter.layout(for: image)
        let memory = simulate(C64PrgWriter.data(for: image), layout: layout)

        XCTAssertEqual(Array(memory[0x2000..<0x3F40]), image.bitmap, "bitmap at $2000")
        XCTAssertEqual(Array(memory[0x0400..<0x07E8]), image.screenRAM, "screen RAM at $0400")
        XCTAssertNil(image.colorRAM, "hires has no colour RAM to copy")
    }

    /// The embedded bitmap really does sit under the address it is copied to, so
    /// the descending copy is load-bearing rather than a stylistic choice.
    func testTheEmbeddedBitmapOverlapsItsDestination() throws {
        for mode in [BitmapMode.multicolor, .hires] {
            let layout = C64PrgWriter.layout(for: try convertedImage(mode: mode))
            let source = layout.bitmapSource
            let target = 0x2000
            XCTAssertLessThan(
                source, target,
                "\(mode): the source must start below $2000 for a descending copy to be the "
                    + "safe direction")
            XCTAssertGreaterThan(
                source + C64Image.bitmapByteCount, target,
                "\(mode): the source and the destination must actually overlap")
        }
    }

    func testAnAscendingBitmapCopyOfTheSameLayoutWouldCorruptThePicture() throws {
        let image = try convertedImage(mode: .multicolor)
        let layout = C64PrgWriter.layout(for: image)
        let memory = simulate(
            C64PrgWriter.data(for: image), layout: layout, descendingBitmap: false)

        XCTAssertNotEqual(
            Array(memory[0x2000..<0x3F40]), image.bitmap,
            "an ascending copy over an overlapping source must eat its own tail — if this "
                + "passes, the simulation is no longer testing anything")
    }

    // MARK: - (d) The mode register

    /// `lda #imm` / `sta $D016`, which is the only way `$D016` is written.
    private func storeIntoD016(of value: UInt8) -> [UInt8] {
        [0xA9, value, 0x8D, 0x16, 0xD0]
    }

    func testMulticolorTurnsTheMulticolorBitOnAndHiresLeavesItOff() throws {
        let multicolor = Array(C64PrgWriter.data(for: try convertedImage(mode: .multicolor)))
        let hires = Array(C64PrgWriter.data(for: try convertedImage(mode: .hires)))

        // $D8 is %1101_1000: MCM set, 40 columns, no x-scroll. $C8 is the same
        // with MCM clear.
        XCTAssertTrue(
            contains(multicolor, storeIntoD016(of: 0xD8)),
            "multicolour must store $D8 into $D016")
        XCTAssertFalse(contains(multicolor, storeIntoD016(of: 0xC8)))

        XCTAssertTrue(
            contains(hires, storeIntoD016(of: 0xC8)), "hires must store $C8 into $D016")
        XCTAssertFalse(contains(hires, storeIntoD016(of: 0xD8)))
    }

    /// Whether `needle` appears anywhere in `haystack`. The routine sits at a
    /// known offset, but searching the whole file is what makes the assertion
    /// survive a stub or a header changing length.
    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    // MARK: - Size and determinism

    func testTheFileIsThePinnedSize() throws {
        // 2 load address + 12 stub + routine + 1000 screen + 1000 colour + 8000
        // bitmap, with a 143-byte multicolour routine and a 109-byte hires one
        // (hires copies no colour RAM and writes one register fewer).
        let multicolor = C64PrgWriter.data(for: try convertedImage(mode: .multicolor))
        XCTAssertEqual(multicolor.count, 2 + 12 + 143 + 1000 + 1000 + 8000)
        XCTAssertEqual(multicolor.count, 10157)

        let hires = C64PrgWriter.data(for: try convertedImage(mode: .hires))
        XCTAssertEqual(hires.count, 2 + 12 + 109 + 1000 + 8000)
        XCTAssertEqual(hires.count, 9123)
    }

    func testTheLayoutDescribesTheFileThatIsActuallyWritten() throws {
        for mode in [BitmapMode.multicolor, .hires] {
            let image = try convertedImage(mode: mode)
            let data = C64PrgWriter.data(for: image)
            let layout = C64PrgWriter.layout(for: image)

            XCTAssertEqual(data.count, layout.fileByteCount, "\(mode)")
            // Every source address is stated as a C64 address; the byte at that
            // address is at `address - $0801 + 2` in the file.
            func fileOffset(of address: Int) -> Int { address - 0x0801 + 2 }
            XCTAssertEqual(
                Array(data[fileOffset(of: layout.screenSource)...].prefix(1000)),
                image.screenRAM, "\(mode): screen block")
            XCTAssertEqual(
                Array(data[fileOffset(of: layout.bitmapSource)...].prefix(8000)),
                image.bitmap, "\(mode): bitmap block")
            if let colorSource = layout.colorSource {
                XCTAssertEqual(
                    Array(data[fileOffset(of: colorSource)...].prefix(1000)),
                    try XCTUnwrap(image.colorRAM), "\(mode): colour block")
            } else {
                XCTAssertNil(image.colorRAM, "\(mode): no colour block means no colour RAM")
            }
        }
    }

    func testWritingIsDeterministic() throws {
        for mode in [BitmapMode.multicolor, .hires] {
            let image = try convertedImage(mode: mode)
            XCTAssertEqual(C64PrgWriter.data(for: image), C64PrgWriter.data(for: image), "\(mode)")
        }
    }

    func testTheBorderAndBackgroundRegistersCarryTheImagesBackground() throws {
        let image = try convertedImage(mode: .multicolor)
        let background = try XCTUnwrap(image.background)
        let bytes = Array(C64PrgWriter.data(for: image))

        // lda #background / sta $D021 / sta $D020.
        XCTAssertTrue(
            contains(bytes, [0xA9, background, 0x8D, 0x21, 0xD0, 0x8D, 0x20, 0xD0]),
            "multicolour must set both $D021 and $D020 to the shared background")

        // Hires has no shared background: the border is simply blacked out.
        let hires = Array(C64PrgWriter.data(for: try convertedImage(mode: .hires)))
        XCTAssertTrue(
            contains(hires, [0xA9, 0x00, 0x8D, 0x20, 0xD0]), "hires must set $D020 to black")
    }

    func testTheProgramEndsInAnInfiniteLoopOnItself() throws {
        for mode in [BitmapMode.multicolor, .hires] {
            let image = try convertedImage(mode: mode)
            let layout = C64PrgWriter.layout(for: image)
            let data = C64PrgWriter.data(for: image)

            // `jmp *` is the last instruction of the routine, so it ends three
            // bytes before the screen block begins, and its operand is its own
            // address.
            let address = layout.screenSource - 3
            let offset = address - 0x0801 + 2
            XCTAssertEqual(
                Array(data[offset..<(offset + 3)]),
                [0x4C, UInt8(address & 0xFF), UInt8(address >> 8)], "\(mode)")
        }
    }
}
