/// Forces an index buffer down to what the VIC-II can actually display.
///
/// The C64 does not store a colour per pixel. In hires bitmap mode each 8×8
/// cell carries one screen-RAM byte holding two colour nibbles, so a cell can
/// show at most two colours; in multicolour mode each 4×8 cell carries a screen
/// byte plus a colour-RAM nibble — three per-cell colours — alongside one
/// background register shared by the whole screen. Quantization ignores all of
/// that and picks the best colour per pixel, so something has to reduce each
/// cell to a legal palette afterwards. That is this file.
///
/// Two rules run the whole thing, and both are pinned so conversion is
/// reproducible:
///
/// * **Selection is by frequency, ties toward the lower index.** Keeping the
///   most-used colours loses the fewest pixels; the tie-break has no aesthetic
///   justification at all, it exists so two runs can never disagree.
/// * **Dropped pixels move to the nearest *kept* colour**, measured with
///   `C64Palette.distance` — the same weighted metric quantization used, so a
///   tie is a tie everywhere in the engine. Distance ties break toward the lower
///   index, matching `C64Palette.nearestIndex`.
///
/// Nothing here looks at the source image again. By this point the true colours
/// are gone and only indices remain, which is why the remap compares palette
/// entries rather than original pixels — a cheaper and, more importantly,
/// order-independent choice.
public enum CellConstraints {

    /// The number of C64 colours. `IndexBuffer` promises every index is 0…15.
    private static let paletteSize = 16

    /// Reduces every 8×8 cell to its two most frequent indices.
    ///
    /// Sized for a 320×200 hires bitmap, but written for any dimensions: a
    /// buffer that is not a whole number of cells gets a narrow or short cell at
    /// the edge, and that partial cell is constrained like any other rather than
    /// skipped or read past the end.
    public static func enforceHires(_ buffer: inout IndexBuffer, palette: C64Palette) {
        enforce(
            &buffer, palette: palette,
            cellWidth: 8, cellHeight: 8,
            background: nil, foregroundBudget: 2)
    }

    /// Picks a shared background, then reduces every 4×8 cell to that background
    /// plus its three most frequent other indices.
    ///
    /// - Returns: the background index, which the caller must write to `$d021`
    ///   (or the equivalent byte of the output file). It is the most frequent
    ///   index over the *whole* buffer — a per-cell choice would be meaningless,
    ///   since the hardware has exactly one background register for the screen.
    ///
    /// The background counts as available in every cell whether or not a pixel
    /// there uses it, so a dropped pixel may legally move to it. That is why the
    /// cell budget is three *non-background* indices rather than four in total.
    ///
    /// Enforcing an already-enforced buffer is a no-op on every image the
    /// pipeline produces, and the tests pin that. It is not a theorem, though:
    /// the background is re-derived from the buffer, and remapping can only add
    /// pixels to the colours it keeps, so a contrived image whose runner-up
    /// colour overtakes the background during the first pass would be measured
    /// against a different background on the second. The engine calls this once
    /// per conversion, so that case stays hypothetical.
    @discardableResult
    public static func enforceMulticolor(
        _ buffer: inout IndexBuffer, palette: C64Palette
    ) -> UInt8 {
        let background = mostFrequentIndex(in: buffer)
        enforce(
            &buffer, palette: palette,
            cellWidth: 4, cellHeight: 8,
            background: background, foregroundBudget: 3)
        return background
    }

    // MARK: - The shared pass

    /// Walks `buffer` cell by cell, keeping `background` (if any) plus the
    /// `foregroundBudget` most frequent other indices and remapping the rest.
    ///
    /// The two modes differ only in cell size and in whether a colour is
    /// reserved up front, so they share one implementation; splitting them would
    /// mean maintaining the frequency and tie-break rules twice.
    private static func enforce(
        _ buffer: inout IndexBuffer,
        palette: C64Palette,
        cellWidth: Int,
        cellHeight: Int,
        background: UInt8?,
        foregroundBudget: Int
    ) {
        guard buffer.width > 0, buffer.height > 0 else { return }
        let colors = palette.colors

        // Both scratch tables are allocated once and reused across cells: at a
        // thousand cells per image the allocation would otherwise outweigh the
        // work.
        var counts = [Int](repeating: 0, count: paletteSize)
        var remap = [UInt8](repeating: 0, count: paletteSize)

        for originY in stride(from: 0, to: buffer.height, by: cellHeight) {
            let endY = min(originY + cellHeight, buffer.height)
            for originX in stride(from: 0, to: buffer.width, by: cellWidth) {
                let endX = min(originX + cellWidth, buffer.width)

                for index in 0..<paletteSize { counts[index] = 0 }
                for y in originY..<endY {
                    for x in originX..<endX {
                        counts[Int(buffer[x, y])] += 1
                    }
                }

                // Reserving the background by zeroing its count keeps it out of
                // the frequency contest below without a special case inside the
                // loop — it has already won a slot.
                var kept: [UInt8] = []
                if let background {
                    kept.append(background)
                    counts[Int(background)] = 0
                }
                for _ in 0..<foregroundBudget {
                    var bestIndex = -1
                    var bestCount = 0
                    for index in 0..<paletteSize where counts[index] > bestCount {
                        // Strictly greater, so an equal count leaves the
                        // earlier — lower — index in place.
                        bestCount = counts[index]
                        bestIndex = index
                    }
                    // Fewer distinct colours present than the budget allows:
                    // everything survives and there is nothing left to pick.
                    guard bestIndex >= 0 else { break }
                    kept.append(UInt8(bestIndex))
                    counts[bestIndex] = 0
                }

                // Only reachable for a zero-area cell, which `stride` cannot
                // produce — but a `kept` of nothing would make the remap below
                // meaningless, so say so rather than crash obscurely.
                guard !kept.isEmpty else { continue }

                // Ascending so the nearest-kept search can use a strict `<` and
                // get the lower-index tie-break for free, exactly as
                // `C64Palette.nearestIndex` does over the full palette.
                kept.sort()

                for index in 0..<paletteSize {
                    if kept.contains(UInt8(index)) {
                        remap[index] = UInt8(index)
                        continue
                    }
                    var best = kept[0]
                    var bestDistance = C64Palette.distance(colors[index], colors[Int(kept[0])])
                    for candidate in kept.dropFirst() {
                        let distance = C64Palette.distance(
                            colors[index], colors[Int(candidate)])
                        if distance < bestDistance {
                            bestDistance = distance
                            best = candidate
                        }
                    }
                    remap[index] = best
                }

                for y in originY..<endY {
                    for x in originX..<endX {
                        buffer[x, y] = remap[Int(buffer[x, y])]
                    }
                }
            }
        }
    }

    // MARK: - Background selection

    /// The most frequent index over the whole buffer, ties toward the lower
    /// index. Zero for an empty buffer — there is no meaningful answer, and 0
    /// (black) is the least surprising background for a screen with no pixels.
    private static func mostFrequentIndex(in buffer: IndexBuffer) -> UInt8 {
        var counts = [Int](repeating: 0, count: paletteSize)
        for index in buffer.indices { counts[Int(index)] += 1 }

        var bestIndex = 0
        var bestCount = counts[0]
        for index in 1..<paletteSize where counts[index] > bestCount {
            // Strictly greater: an equal count keeps the lower index.
            bestCount = counts[index]
            bestIndex = index
        }
        return UInt8(bestIndex)
    }
}
