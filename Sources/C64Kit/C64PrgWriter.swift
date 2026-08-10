import Foundation

/// Serializes a converted picture as a runnable C64 program.
///
/// `C64FileWriter`'s two formats are memory dumps: something on the machine —
/// Koala Painter, a viewer, a cruncher — has to load them and point the VIC-II
/// at them. This writes the other kind of file. A `.prg` produced here is a
/// complete program: `LOAD"PIC",8,1` then `RUN`, or drop it on an emulator, and
/// the picture appears with nothing else installed.
///
/// ## What the file contains
///
/// ```
/// $0801  12 B    BASIC: 10 SYS 2061
/// $080D  N B     the machine-code routine (N = 143 multicolour, 109 hires)
///        1000 B  screen RAM, copied to $0400
///        1000 B  colour RAM, copied to $D800   (multicolour only)
///        8000 B  bitmap, copied to $2000       (last, and highest)
/// ```
///
/// The two-byte header on the front is the load address `$0801`, low byte first,
/// as every PRG carries.
///
/// ## Why the bitmap goes last, and why its copy runs backwards
///
/// A multicolour file is 10157 bytes, so once loaded it occupies
/// `$0801…$2FAC` — and the bitmap has to end up at `$2000…$3F3F`, which is
/// inside that. The copy therefore overwrites its own source region as it runs,
/// and only one direction survives that.
///
/// With the blocks laid out in the order above, the embedded bitmap starts at
/// `$106C` (multicolour) or `$0C62` (hires) — *below* the `$2000` it is going
/// to. For a copy where the destination is above the source, the safe direction
/// is downward: writing `$2000 + i` while reading `bitmapSource + i` for a
/// decreasing `i` always writes to an address 3988 bytes above the byte just
/// read, and every byte still to be read lies below that. An upward copy would
/// clobber the first four thousand unread bytes before reaching them.
///
/// Screen and colour RAM go to `$0400` and `$D800`, both far below the file, so
/// their direction cannot matter — but they are copied first anyway, before the
/// bitmap copy scribbles over `$2000…$3F3F`.
///
/// ## The routine, as assembly
///
/// Hand-assembled below; `screen`, `color` and `bitmap` are the absolute
/// addresses of the embedded blocks, which the writer computes when it lays the
/// file out. The bracketed lines are multicolour-only.
///
/// ```asm
///           * = $080D
///           sei                     ; no KERNAL IRQ: nothing else runs again
///
///           lda #$3b                ; $d011: BMM on, display on, 25 rows
///           sta $d011
///           lda #$d8                ; $d016: MCM on, 40 columns  [hires: #$c8]
///           sta $d016
///           lda #$18                ; $d018: screen $0400, bitmap $2000
///           sta $d018
///           lda #background         ; [hires: lda #$00]
///           sta $d021               ; [multicolour only]
///           sta $d020
///
///           ldx #$00                ; screen -> $0400, four 250-byte columns
/// screencp  lda screen,x
///           sta $0400,x
///           lda screen+250,x
///           sta $04fa,x
///           lda screen+500,x
///           sta $05f4,x
///           lda screen+750,x
///           sta $06ee,x
///           inx
///           cpx #250
///           bne screencp
///
///           ldx #$00                ; [multicolour only] color -> $d800
/// colorcp   lda color,x
///           sta $d800,x
///           lda color+250,x
///           sta $d8fa,x
///           lda color+500,x
///           sta $d9f4,x
///           lda color+750,x
///           sta $daee,x
///           inx
///           cpx #250
///           bne colorcp
///
///           lda #<(bitmap+7750)     ; bitmap -> $2000, downward:
///           sta $fb                 ; 32 chunks of 250, last chunk first,
///           lda #>(bitmap+7750)     ; and each chunk from its last byte
///           sta $fc
///           lda #<($2000+7750)
///           sta $fd
///           lda #>($2000+7750)
///           sta $fe
///           ldx #32
/// chunk     ldy #249
/// byte      lda ($fb),y
///           sta ($fd),y
///           dey
///           cpy #$ff                ; $ff is y wrapping past 0, so 0 is copied
///           bne byte
///           sec                     ; both pointers down one chunk
///           lda $fb
///           sbc #250
///           sta $fb
///           bcs +
///           dec $fc
/// +         sec
///           lda $fd
///           sbc #250
///           sta $fd
///           bcs +
///           dec $fe
/// +         dex
///           bne chunk
///
/// forever   jmp forever
/// ```
///
/// `$dd00` is left alone: VIC bank 0 is the power-on default, which is what
/// `$d018 = $18` is read against. `$fb…$fe` is the conventional free zero-page
/// scratch, and with interrupts off nothing else is going to want it.
public enum C64PrgWriter {

    // MARK: - Addresses, pinned
    //
    // Every one of these is a hardware or BASIC fact rather than a choice, which
    // is why they are named here instead of appearing as numbers in the
    // assembly below.

    /// Where a BASIC program lives, and so where a PRG of this shape loads.
    private static let loadAddress = 0x0801

    /// The VIC's video matrix in bank 0 — screen RAM, 1000 bytes.
    private static let screenTarget = 0x0400

    /// The bitmap base `$d018 = $18` selects, 8000 bytes.
    private static let bitmapTarget = 0x2000

    /// Colour RAM. Fixed in the address space, not part of the VIC bank.
    private static let colorTarget = 0xD800

    /// VIC registers.
    private static let controlRegister1 = 0xD011  // $d011
    private static let controlRegister2 = 0xD016  // $d016
    private static let memoryPointers = 0xD018  // $d018
    private static let borderColor = 0xD020  // $d020
    private static let backgroundColor = 0xD021  // $d021

    /// Zero-page scratch for the bitmap copy's two pointers.
    private static let sourcePointer: UInt8 = 0xFB
    private static let targetPointer: UInt8 = 0xFD

    /// How many bytes one pass of a copy loop moves.
    ///
    /// 250 rather than 256 so that 1000 is four passes exactly and 8000 is
    /// thirty-two, which is what lets both loops use a single 8-bit counter with
    /// no remainder to clean up afterwards.
    private static let chunkSize = 250

    /// The BASIC stub, `10 SYS 2061`, at `$0801`.
    ///
    /// | address | bytes         | meaning |
    /// |---------|---------------|---------|
    /// | `$0801` | `0B 08`       | link to the next line: `$080B` |
    /// | `$0803` | `0A 00`       | line number 10 |
    /// | `$0805` | `9E`          | the `SYS` token |
    /// | `$0806` | `32 30 36 31` | `"2061"` |
    /// | `$080A` | `00`          | end of line |
    /// | `$080B` | `00 00`       | end of program |
    ///
    /// The line's text ends at `$080A`, so the next line would start at `$080B`
    /// — the link's value — and the null link there is what tells BASIC to stop.
    /// The stub is twelve bytes, `$0801…$080C`, which puts the machine code at
    /// `$080D`; `$080D` is 2061, which is the number `SYS` is handed. The two
    /// have to be derived together or the program runs into whatever `$080D`
    /// happens to hold.
    private static let basicStub: [UInt8] = [
        0x0B, 0x08,  // link -> $080B
        0x0A, 0x00,  // line 10
        0x9E,  // SYS
        0x32, 0x30, 0x36, 0x31,  // "2061"
        0x00,  // end of line
        0x00, 0x00,  // end of program
    ]

    // MARK: - Layout

    /// Where each block sits once the file is loaded, as C64 addresses.
    ///
    /// The routine addresses its embedded data absolutely, so these are not a
    /// description of the file so much as the numbers assembled into it. Exposed
    /// inside the module so the tests can walk the copies the routine would
    /// perform without re-deriving the layout — and so that a layout that put
    /// the bitmap somewhere a descending copy could not survive would be visible
    /// rather than inferred from a corrupted picture.
    struct Layout {
        /// `$080D`, the address `SYS` calls.
        let routineAddress: Int

        /// The embedded 1000 bytes bound for `$0400`.
        let screenSource: Int

        /// The embedded 1000 bytes bound for `$d800`, or `nil` in hires, which
        /// has no colour RAM and so no third block.
        let colorSource: Int?

        /// The embedded 8000 bytes bound for `$2000`. Always the highest block.
        let bitmapSource: Int

        /// The whole file, load address included.
        let fileByteCount: Int
    }

    /// Where `data(for:)` will put everything.
    ///
    /// The routine's length is measured rather than tabulated: `routine` is
    /// assembled once with placeholder addresses purely to count it, and then
    /// again for real. Every instruction it emits is immediate, absolute or
    /// zero-page — fixed width, no addressing mode that shrinks for a small
    /// operand — so the two passes cannot disagree, and `data(for:)` asserts
    /// they did not.
    static func layout(for image: C64Image) -> Layout {
        let routineAddress = loadAddress + basicStub.count
        let probe = Layout(
            routineAddress: routineAddress, screenSource: 0, colorSource: 0,
            bitmapSource: 0, fileByteCount: 0)
        let routineByteCount = routine(for: image, layout: probe).count

        let screenSource = routineAddress + routineByteCount
        let colorSource = screenSource + C64Image.screenByteCount
        let bitmapSource =
            image.colorRAM == nil ? colorSource : colorSource + C64Image.screenByteCount
        let end = bitmapSource + C64Image.bitmapByteCount

        return Layout(
            routineAddress: routineAddress,
            screenSource: screenSource,
            colorSource: image.colorRAM == nil ? nil : colorSource,
            bitmapSource: bitmapSource,
            fileByteCount: 2 + end - loadAddress)
    }

    // MARK: - Writing

    /// A runnable C64 program that displays `image`.
    ///
    /// 10157 bytes for a multicolour picture, 9123 for a hires one. See the
    /// type's doc comment for the layout and the routine.
    public static func data(for image: C64Image) -> Data {
        let layout = layout(for: image)

        // The invariant the descending bitmap copy rests on. Structurally true
        // for the layout above — the bitmap is the last block and the file is
        // nowhere near 8000 bytes of routine — but it is the one thing that
        // would go wrong silently, as a picture with four thousand bytes of
        // garbage in it, so it is checked rather than remembered.
        precondition(
            layout.bitmapSource < bitmapTarget,
            "the embedded bitmap must sit below $2000 for the descending copy to be safe")

        let code = routine(for: image, layout: layout)
        precondition(
            layout.routineAddress + code.count == layout.screenSource,
            "the routine's measured length disagrees with the layout it was assembled against")

        var data = Data(capacity: layout.fileByteCount)
        data.append(UInt8(loadAddress & 0x00FF))
        data.append(UInt8(loadAddress >> 8))
        data.append(contentsOf: basicStub)
        data.append(contentsOf: code)
        data.append(contentsOf: image.screenRAM)
        if let colorRAM = image.colorRAM {
            data.append(contentsOf: colorRAM)
        }
        data.append(contentsOf: image.bitmap)
        return data
    }

    // MARK: - The assembler

    /// The machine code, assembled against `layout`.
    ///
    /// Written as an emitter rather than a byte table so the branch offsets are
    /// computed from the labels they point at: a hand-counted `bne` operand is
    /// exactly the kind of thing that survives review and then hangs a C64.
    private static func routine(for image: C64Image, layout: Layout) -> [UInt8] {
        var code: [UInt8] = []

        // 6502 opcodes, named where they are used more than once.
        let ldaImmediate: UInt8 = 0xA9
        let ldaAbsoluteX: UInt8 = 0xBD
        let staAbsolute: UInt8 = 0x8D
        let staAbsoluteX: UInt8 = 0x9D
        let ldaZeroPage: UInt8 = 0xA5
        let staZeroPage: UInt8 = 0x85
        let decZeroPage: UInt8 = 0xC6
        let ldxImmediate: UInt8 = 0xA2
        let cpxImmediate: UInt8 = 0xE0
        let ldyImmediate: UInt8 = 0xA0
        let cpyImmediate: UInt8 = 0xC0
        let sbcImmediate: UInt8 = 0xE9
        let branchIfNotEqual: UInt8 = 0xD0
        let branchIfCarrySet: UInt8 = 0xB0

        func implied(_ opcode: UInt8) { code.append(opcode) }
        func immediate(_ opcode: UInt8, _ value: UInt8) { code += [opcode, value] }
        func zeroPage(_ opcode: UInt8, _ address: UInt8) { code += [opcode, address] }
        func absolute(_ opcode: UInt8, _ address: Int) {
            code += [opcode, UInt8(address & 0x00FF), UInt8((address >> 8) & 0x00FF)]
        }
        /// A branch back to `target`, which must already have been emitted. The
        /// operand is relative to the instruction *after* the branch, hence the
        /// `+ 2`.
        func branch(_ opcode: UInt8, to target: Int) {
            code.append(opcode)
            code.append(UInt8(bitPattern: Int8(target - (code.count + 1))))
        }

        // MARK: Registers

        implied(0x78)  // sei

        immediate(ldaImmediate, 0x3B)
        absolute(staAbsolute, controlRegister1)

        // $d8 is %1101_1000 — multicolour on, 40 columns, no x-scroll; $c8 the
        // same with the multicolour bit clear. Bits 7…5 are unused and read back
        // as 1, so writing them set is the conventional value rather than a
        // meaningful one.
        immediate(ldaImmediate, image.mode == .multicolor ? 0xD8 : 0xC8)
        absolute(staAbsolute, controlRegister2)

        immediate(ldaImmediate, 0x18)
        absolute(staAbsolute, memoryPointers)

        // Multicolour's `%00` pixels come from $d021, so the border is set to
        // the same index and the picture ends up framed in its own background
        // rather than in light blue. Hires has no image-wide colour at all — its
        // two colours are per cell — so the border is simply blacked out.
        if let background = image.background {
            immediate(ldaImmediate, background)
            absolute(staAbsolute, backgroundColor)
            absolute(staAbsolute, borderColor)
        } else {
            immediate(ldaImmediate, 0x00)
            absolute(staAbsolute, borderColor)
        }

        // MARK: Screen and colour RAM

        /// 1000 bytes as four 250-byte columns walked by one index register, so
        /// the loop counter stays 8-bit and no chunk straddles a page in a way
        /// the code has to know about.
        func copyThousand(from source: Int, to target: Int) {
            immediate(ldxImmediate, 0x00)
            let loop = code.count
            for column in 0..<(C64Image.screenByteCount / chunkSize) {
                absolute(ldaAbsoluteX, source + column * chunkSize)
                absolute(staAbsoluteX, target + column * chunkSize)
            }
            implied(0xE8)  // inx
            immediate(cpxImmediate, UInt8(chunkSize))
            branch(branchIfNotEqual, to: loop)
        }

        copyThousand(from: layout.screenSource, to: screenTarget)
        if image.colorRAM != nil {
            // `?? 0` only for the measuring pass, whose addresses are
            // placeholders anyway; an absolute operand is three bytes whatever
            // it holds.
            copyThousand(from: layout.colorSource ?? 0, to: colorTarget)
        }

        // MARK: The bitmap, downward

        let chunkCount = C64Image.bitmapByteCount / chunkSize
        let lastChunk = (chunkCount - 1) * chunkSize

        func pointAt(_ pointer: UInt8, _ address: Int) {
            immediate(ldaImmediate, UInt8(address & 0x00FF))
            zeroPage(staZeroPage, pointer)
            immediate(ldaImmediate, UInt8((address >> 8) & 0x00FF))
            zeroPage(staZeroPage, pointer + 1)
        }
        pointAt(sourcePointer, layout.bitmapSource + lastChunk)
        pointAt(targetPointer, bitmapTarget + lastChunk)

        immediate(ldxImmediate, UInt8(chunkCount))
        let chunkLoop = code.count
        immediate(ldyImmediate, UInt8(chunkSize - 1))
        let byteLoop = code.count
        zeroPage(0xB1, sourcePointer)  // lda (src),y
        zeroPage(0x91, targetPointer)  // sta (dst),y
        implied(0x88)  // dey
        // Y has to reach 0 *and* be copied, so the exit test is the wrap to $ff
        // rather than a `bpl` — which would have stopped at 127 anyway, 249
        // being negative as a signed byte.
        immediate(cpyImmediate, 0xFF)
        branch(branchIfNotEqual, to: byteLoop)

        /// `pointer -= chunkSize`, borrowing into the high byte.
        func stepDown(_ pointer: UInt8) {
            implied(0x38)  // sec
            zeroPage(ldaZeroPage, pointer)
            immediate(sbcImmediate, UInt8(chunkSize))
            zeroPage(staZeroPage, pointer)
            // Carry clear means the subtraction borrowed; the two bytes skipped
            // are exactly the `dec` below.
            branch(branchIfCarrySet, to: code.count + 4)
            zeroPage(decZeroPage, pointer + 1)
        }
        stepDown(sourcePointer)
        stepDown(targetPointer)

        implied(0xCA)  // dex
        branch(branchIfNotEqual, to: chunkLoop)

        // MARK: Done

        // `jmp *`. The picture is on screen and the IRQ is off, so there is
        // nothing left to do and nowhere sensible to return to: BASIC's warm
        // start would redraw the text screen over the top of it.
        let forever = layout.routineAddress + code.count
        absolute(0x4C, forever)

        return code
    }
}
