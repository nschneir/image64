/// A converted picture in the exact bytes a C64 would hold in memory.
///
/// This is the pivot of the whole engine. Everything upstream works in palette
/// indices; everything downstream — the Koala and Art Studio writers, the PNG
/// export, and the app's live preview — works from *these arrays and nothing
/// else*. The preview in particular is rendered by `render(palette:)` straight
/// off `bitmap`/`screenRAM`/`colorRAM`, so what the user sees is byte-for-byte
/// what the exported file contains. Keeping an `IndexBuffer` around as a
/// shortcut for the preview would quietly break that guarantee.
///
/// ## The memory layout, and why it looks like that
///
/// A VIC-II bitmap is not scanline-major. The 8000 bytes are ordered by 8×8
/// *cell*: the eight bytes of a cell are consecutive, cells run left to right,
/// and cell rows run top to bottom. So the byte holding pixel row `rowInCell`
/// of the cell at `(cellRow, cellColumn)` sits at
/// `cellRow * 320 + cellColumn * 8 + rowInCell` — see `bitmapOffset`. The
/// hardware did it this way because the character-mode fetch logic was reused
/// for bitmap mode; every C64 graphics tool inherits the layout, which is why
/// it is pinned here rather than recomputed at each call site.
///
/// Alongside the bitmap sit 1000 bytes of screen RAM (one per cell, row-major
/// `cellRow * 40 + cellColumn`) and, in multicolour, 1000 bytes of colour RAM
/// in the same order. Colour RAM is only four bits wide on real hardware — the
/// high nibble is open bus — so this type writes it as 0 and every reader must
/// mask with `& 0x0F`.
///
/// ## Pixel encoding
///
/// **Hires** — 320×200, one bit per pixel, bit 7 leftmost. A set bit takes the
/// cell's foreground colour, from the *upper* nibble of its screen byte; a
/// clear bit takes the background, from the lower nibble.
///
/// **Multicolour** — 160×200, two bits per pixel, so four double-wide pixels
/// per byte with the leftmost in bits 7–6:
///
/// | code | colour source              |
/// |------|----------------------------|
/// | `%00`| the shared background (`$d021`) |
/// | `%01`| screen byte, upper nibble  |
/// | `%10`| screen byte, lower nibble  |
/// | `%11`| colour RAM, low nibble     |
public struct C64Image: Equatable, Sendable {

    /// Which encoding `bitmap` uses, and therefore whether `colorRAM` and
    /// `background` are present.
    public let mode: BitmapMode

    /// 8000 bytes of cell-interleaved bitmap. See `bitmapOffset`.
    public let bitmap: [UInt8]

    /// 1000 bytes of screen RAM, `cellRow * 40 + cellColumn`.
    public let screenRAM: [UInt8]

    /// 1000 bytes of colour RAM in multicolour mode, high nibble 0; `nil` in
    /// hires, which has no colour RAM.
    public let colorRAM: [UInt8]?

    /// The shared background index (`$d021`) in multicolour mode; `nil` in
    /// hires, where every cell carries both of its colours in screen RAM.
    public let background: UInt8?

    // MARK: - Geometry

    /// Cells across the screen.
    public static let cellColumns = 40

    /// Cell rows down the screen.
    public static let cellRows = 25

    /// Bytes in a bitmap: 25 cell rows × 40 cells × 8 pixel rows.
    public static let bitmapByteCount = cellRows * cellColumns * 8

    /// Bytes in screen (and colour) RAM: one per cell.
    public static let screenByteCount = cellRows * cellColumns

    /// Where the byte for one pixel row of one cell lives in `bitmap`.
    ///
    /// The one piece of C64 addressing worth naming: the layout is cell-major,
    /// not scanline-major, and open-coding `cellRow * 320 + …` at each call site
    /// is how off-by-a-cell-row bugs get in.
    public static func bitmapOffset(cellRow: Int, cellColumn: Int, rowInCell: Int) -> Int {
        cellRow * (cellColumns * 8) + cellColumn * 8 + rowInCell
    }

    /// The number of C64 colours. Every index in an `IndexBuffer` is 0…15.
    private static let paletteSize = 16

    // MARK: - Creation

    /// Creates an image from packed bytes.
    ///
    /// Deliberately not public: an externally-built `C64Image` could carry array
    /// sizes or a mode/field combination the renderer and the file writers both
    /// assume away. Inside the module the preconditions below are the contract.
    init(
        mode: BitmapMode,
        bitmap: [UInt8],
        screenRAM: [UInt8],
        colorRAM: [UInt8]?,
        background: UInt8?
    ) {
        precondition(
            bitmap.count == Self.bitmapByteCount,
            "bitmap must be \(Self.bitmapByteCount) bytes, got \(bitmap.count)")
        precondition(
            screenRAM.count == Self.screenByteCount,
            "screen RAM must be \(Self.screenByteCount) bytes, got \(screenRAM.count)")
        switch mode {
        case .hires:
            precondition(colorRAM == nil, "hires has no colour RAM")
            precondition(background == nil, "hires has no background register")
        case .multicolor:
            precondition(
                colorRAM?.count == Self.screenByteCount,
                "multicolour colour RAM must be \(Self.screenByteCount) bytes")
            precondition(background != nil, "multicolour needs a background index")
        }
        self.mode = mode
        self.bitmap = bitmap
        self.screenRAM = screenRAM
        self.colorRAM = colorRAM
        self.background = background
    }

    // MARK: - Packing

    /// Packs a 320×200 index buffer into hires bitmap and screen RAM.
    ///
    /// The caller is expected to have run `CellConstraints.enforceHires` first,
    /// so every 8×8 cell holds at most two indices. If a cell holds more — which
    /// only an unconstrained buffer can produce — the two most frequent survive
    /// and the rest pack as background rather than crashing; the result is still
    /// deterministic, just lossy.
    ///
    /// Per cell: the **more frequent** index becomes the foreground and sets its
    /// pixels' bits, the other becomes the background, and the screen byte is
    /// `foreground << 4 | background`. Frequency ties break toward the lower
    /// index — no aesthetic reason, it just has to be pinned so two runs cannot
    /// disagree. A single-colour cell is the one special case: its bits are all
    /// 0 and the colour is written to *both* nibbles, which keeps a flat cell
    /// looking like a flat cell in a hex dump instead of a solid run of `$FF`.
    public static func pack(hires buffer: IndexBuffer) -> C64Image {
        precondition(
            buffer.width == 320 && buffer.height == 200,
            "hires packing needs a 320×200 buffer, got \(buffer.width)×\(buffer.height)")

        var bitmap = [UInt8](repeating: 0, count: bitmapByteCount)
        var screenRAM = [UInt8](repeating: 0, count: screenByteCount)
        // Allocated once and reused: at a thousand cells the per-cell allocation
        // would outweigh the counting.
        var counts = [Int](repeating: 0, count: paletteSize)

        for cellRow in 0..<cellRows {
            for cellColumn in 0..<cellColumns {
                let originX = cellColumn * 8
                let originY = cellRow * 8

                for index in 0..<paletteSize { counts[index] = 0 }
                for y in originY..<(originY + 8) {
                    for x in originX..<(originX + 8) {
                        counts[Int(buffer[x, y])] += 1
                    }
                }

                let ranked = mostFrequent(in: &counts, limit: 2)
                // A cell always has 64 pixels, so `ranked` is never empty.
                let foreground = ranked[0]
                let background = ranked.count > 1 ? ranked[1] : foreground
                screenRAM[cellRow * cellColumns + cellColumn] = foreground << 4 | background

                // Single-colour cell: leave the bits at 0 so the colour reads
                // back out of the background nibble. Writing foreground bits
                // here would render identically but fill the file with $FF.
                guard ranked.count > 1 else { continue }

                for rowInCell in 0..<8 {
                    var byte: UInt8 = 0
                    let y = originY + rowInCell
                    for column in 0..<8 where buffer[originX + column, y] == foreground {
                        byte |= 1 << (7 - column)
                    }
                    bitmap[bitmapOffset(
                        cellRow: cellRow, cellColumn: cellColumn, rowInCell: rowInCell)] = byte
                }
            }
        }

        return C64Image(
            mode: .hires, bitmap: bitmap, screenRAM: screenRAM,
            colorRAM: nil, background: nil)
    }

    /// Packs a 160×200 index buffer plus a shared background into multicolour
    /// bitmap, screen RAM and colour RAM.
    ///
    /// The caller is expected to have run `CellConstraints.enforceMulticolor`
    /// first and to pass back the background it returned, so every 4×8 cell
    /// holds at most the background plus three other indices. A cell with more
    /// keeps its three most frequent and packs the rest as background — lossy,
    /// but deterministic.
    ///
    /// Per cell the non-background indices are ordered by descending count, ties
    /// toward the lower index, and assigned in that order to `%01` (screen upper
    /// nibble), `%10` (screen lower nibble) and `%11` (colour RAM). Unclaimed
    /// slots are written as 0; because pixels are matched against the background
    /// first and then only against *claimed* slots, an image whose background is
    /// nonzero can still use index 0 as a foreground colour without colliding
    /// with those empty slots.
    public static func pack(multicolor buffer: IndexBuffer, background: UInt8) -> C64Image {
        precondition(
            buffer.width == 160 && buffer.height == 200,
            "multicolour packing needs a 160×200 buffer, got \(buffer.width)×\(buffer.height)")
        precondition(background < UInt8(paletteSize), "background index must be 0…15")

        var bitmap = [UInt8](repeating: 0, count: bitmapByteCount)
        var screenRAM = [UInt8](repeating: 0, count: screenByteCount)
        var colorRAM = [UInt8](repeating: 0, count: screenByteCount)
        var counts = [Int](repeating: 0, count: paletteSize)

        for cellRow in 0..<cellRows {
            for cellColumn in 0..<cellColumns {
                let originX = cellColumn * 4
                let originY = cellRow * 8

                for index in 0..<paletteSize { counts[index] = 0 }
                for y in originY..<(originY + 8) {
                    for x in originX..<(originX + 4) {
                        counts[Int(buffer[x, y])] += 1
                    }
                }
                // The background has its own register and its own code (`%00`),
                // so zeroing its count keeps it out of the contest for the three
                // per-cell slots without a special case in the ranking loop.
                counts[Int(background)] = 0

                let slots = mostFrequent(in: &counts, limit: 3)
                screenRAM[cellRow * cellColumns + cellColumn] =
                    (slots.count > 0 ? slots[0] : 0) << 4 | (slots.count > 1 ? slots[1] : 0)
                colorRAM[cellRow * cellColumns + cellColumn] = slots.count > 2 ? slots[2] : 0

                for rowInCell in 0..<8 {
                    var byte: UInt8 = 0
                    let y = originY + rowInCell
                    for column in 0..<4 {
                        let index = buffer[originX + column, y]
                        var code: UInt8 = 0
                        if index != background,
                            let slot = slots.firstIndex(of: index) {
                            code = UInt8(slot) + 1
                        }
                        byte |= code << (6 - 2 * column)
                    }
                    bitmap[bitmapOffset(
                        cellRow: cellRow, cellColumn: cellColumn, rowInCell: rowInCell)] = byte
                }
            }
        }

        return C64Image(
            mode: .multicolor, bitmap: bitmap, screenRAM: screenRAM,
            colorRAM: colorRAM, background: background)
    }

    /// The up-to-`limit` most frequent indices in `counts`, descending, ties
    /// toward the lower index. Consumes `counts` (each winner is zeroed), which
    /// is why it takes it `inout` — the caller re-fills the table per cell
    /// anyway, and this avoids a second scratch array.
    ///
    /// Indices with a zero count are never returned, so the result is short for
    /// a cell that simply has fewer colours than the budget.
    private static func mostFrequent(in counts: inout [Int], limit: Int) -> [UInt8] {
        var winners: [UInt8] = []
        winners.reserveCapacity(limit)
        for _ in 0..<limit {
            var bestIndex = -1
            var bestCount = 0
            for index in 0..<paletteSize where counts[index] > bestCount {
                // Strictly greater, so an equal count leaves the earlier —
                // lower — index in place.
                bestCount = counts[index]
                bestIndex = index
            }
            guard bestIndex >= 0 else { break }
            winners.append(UInt8(bestIndex))
            counts[bestIndex] = 0
        }
        return winners
    }

    // MARK: - Rendering

    /// Decodes the packed bytes to native-resolution pixels: 320×200 in hires,
    /// 160×200 in multicolour.
    ///
    /// Multicolour comes back 160 wide, one pixel per *C64* pixel rather than
    /// per screen dot. Doubling it to 320 is a display concern and belongs to
    /// whoever draws it; doing it here would make the buffer lie about how much
    /// horizontal detail the image actually holds.
    ///
    /// This is the only path from a converted image to something a human can
    /// look at, and it reads nothing but `bitmap`, `screenRAM`, `colorRAM` and
    /// `background`. That is what makes the app's preview a true proof of the
    /// exported file rather than a parallel rendering of the same intent.
    public func render(palette: C64Palette) -> RGBBuffer {
        let colors = palette.colors
        switch mode {
        case .hires:
            return renderHires(colors: colors)
        case .multicolor:
            return renderMulticolor(colors: colors)
        }
    }

    private func renderHires(colors: [RGB]) -> RGBBuffer {
        let width = Self.cellColumns * 8
        let height = Self.cellRows * 8
        var pixels = [RGB](repeating: colors[0], count: width * height)

        for cellRow in 0..<Self.cellRows {
            for cellColumn in 0..<Self.cellColumns {
                let screen = screenRAM[cellRow * Self.cellColumns + cellColumn]
                let foreground = colors[Int(screen >> 4)]
                let background = colors[Int(screen & 0x0F)]
                for rowInCell in 0..<8 {
                    let byte = bitmap[Self.bitmapOffset(
                        cellRow: cellRow, cellColumn: cellColumn, rowInCell: rowInCell)]
                    let rowStart = (cellRow * 8 + rowInCell) * width + cellColumn * 8
                    for column in 0..<8 {
                        // Bit 7 is the leftmost pixel.
                        let bit = (byte >> (7 - column)) & 1
                        pixels[rowStart + column] = bit == 1 ? foreground : background
                    }
                }
            }
        }
        return RGBBuffer(width: width, height: height, pixels: pixels)
    }

    private func renderMulticolor(colors: [RGB]) -> RGBBuffer {
        let width = Self.cellColumns * 4
        let height = Self.cellRows * 8
        // The initializer guarantees both of these in multicolour mode; the
        // fallbacks only keep this function total.
        let colorRAM = self.colorRAM ?? [UInt8](repeating: 0, count: Self.screenByteCount)
        let backgroundColor = colors[Int(background ?? 0)]
        var pixels = [RGB](repeating: backgroundColor, count: width * height)

        for cellRow in 0..<Self.cellRows {
            for cellColumn in 0..<Self.cellColumns {
                let cell = cellRow * Self.cellColumns + cellColumn
                let screen = screenRAM[cell]
                // Index by the two-bit code, so the decode below is a lookup
                // instead of a switch — and the table *is* the hardware's
                // colour-source mapping, written out once.
                let sources = [
                    backgroundColor,
                    colors[Int(screen >> 4)],
                    colors[Int(screen & 0x0F)],
                    colors[Int(colorRAM[cell] & 0x0F)],
                ]
                for rowInCell in 0..<8 {
                    let byte = bitmap[Self.bitmapOffset(
                        cellRow: cellRow, cellColumn: cellColumn, rowInCell: rowInCell)]
                    let rowStart = (cellRow * 8 + rowInCell) * width + cellColumn * 4
                    for column in 0..<4 {
                        // Bits 7–6 are the leftmost of the four double-wide
                        // pixels.
                        let code = (byte >> (6 - 2 * column)) & 0b11
                        pixels[rowStart + column] = sources[Int(code)]
                    }
                }
            }
        }
        return RGBBuffer(width: width, height: height, pixels: pixels)
    }
}
