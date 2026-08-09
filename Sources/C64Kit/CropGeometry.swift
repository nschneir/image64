import CoreGraphics

/// What can go wrong with a crop rectangle the user proposed.
public enum CropError: Error, Equatable, Sendable {
    /// The rectangle does not fit the source image, or is too small to convert.
    /// The payload is a sentence for a human — it names the offending dimension
    /// and quotes the limit, because "invalid crop" tells a user nothing about
    /// which edge to drag.
    case outOfBounds(String)
}

/// The crop rectangle arithmetic, shared by the app's overlay and the CLI's
/// `--crop` flag.
///
/// A C64 picture is 320×200 in hires and 160×200 in multicolour, and in both
/// cases the *displayed* image is 320 dots wide by 200 tall — an 8:5 frame.
/// Everything here exists to keep the user's crop at that ratio, so the
/// conversion is a pure downscale rather than a downscale plus an unrequested
/// stretch. (The engine will happily resample any rectangle to the target
/// geometry; it just looks squashed. Pinning the ratio here is what stops that
/// from happening by accident.)
///
/// ## Coordinates
///
/// Source pixels, **y = 0 at the top**, matching `ImageLoading.prepare` and the
/// app's overlay. Every rectangle returned has integral edges: a crop with a
/// fractional origin would resample differently on two machines' rounding, and
/// the whole engine is meant to be byte-reproducible.
///
/// ## The two rules, pinned
///
/// * `defaultCrop` **floors**. The derived edge is truncated, so the rectangle
///   provably fits inside the source — the first thing the app shows can never
///   be out of bounds.
/// * `snap` **rounds**. It runs on every drag of the app's crop handles, and
///   flooring there would shave a row off each time the user nudged an edge,
///   walking the crop steadily shorter. Rounding stays put.
///
/// The two therefore disagree by at most one row on a source whose width is not
/// a multiple of 8 — that is a deliberate consequence of the paragraph above,
/// pinned by `testSnappingTheDefaultCropKeepsItInBounds`, not an oversight.
public enum CropGeometry {

    /// The C64 frame's aspect, as the integer ratio the arithmetic below uses.
    /// Written as two constants so the cross-multiplications read as the ratio
    /// they encode instead of as bare 8s and 5s.
    private static let aspectWidth = 8
    private static let aspectHeight = 5

    /// The narrowest crop worth converting: one 8×8 cell's worth of source
    /// pixels. Below this the crop cannot even supply a pixel per C64 cell
    /// column, and `snap`'s derived height would round to something degenerate.
    private static let minimumWidth = 8

    /// The largest centred 8:5 rectangle that fits inside `sourceWidth` ×
    /// `sourceHeight`.
    ///
    /// This is what the app shows the moment an image is dropped and what the
    /// CLI uses when no `--crop` is given, so it is the crop most conversions
    /// actually run with.
    ///
    /// A source wider than 8:5 keeps its full height and loses columns from
    /// both sides; a taller one keeps its full width and loses rows from top
    /// and bottom. A source that is exactly 8:5 takes the second branch — the
    /// comparison is strict — and comes back as the whole image either way.
    ///
    /// Both the derived edge and the centring offset are floored, so an odd
    /// number of leftover pixels puts the extra one on the right or at the
    /// bottom.
    public static func defaultCrop(sourceWidth: Int, sourceHeight: Int) -> CGRect {
        precondition(
            sourceWidth > 0 && sourceHeight > 0,
            "a source image must have a positive size, got \(sourceWidth)×\(sourceHeight)")

        if sourceWidth * aspectHeight > sourceHeight * aspectWidth {
            // Wider than 8:5 — the height is the binding constraint.
            let width = sourceHeight * aspectWidth / aspectHeight
            return CGRect(
                x: (sourceWidth - width) / 2, y: 0, width: width, height: sourceHeight)
        } else {
            // Taller than (or exactly) 8:5 — the width is the binding one.
            let height = sourceWidth * aspectHeight / aspectWidth
            return CGRect(
                x: 0, y: (sourceHeight - height) / 2, width: sourceWidth, height: height)
        }
    }

    /// Forces a proposed rectangle back to 8:5 by replacing its height.
    ///
    /// `x`, `y` and `width` are taken as given and the height is recomputed as
    /// `round(width · 5 / 8)` — the caller's `height` is *ignored*, which is
    /// what makes this usable straight from a drag: the app hands over whatever
    /// rectangle the pointer described and gets back the legal one nearest to
    /// it, anchored at the same origin.
    ///
    /// - Throws: `CropError.outOfBounds` if the width is under one cell, or if
    ///   the rectangle (with its *snapped* height) leaves the source. The
    ///   height is checked after snapping rather than before, because the
    ///   snapped height is the one that will actually be sampled.
    public static func snap(
        x: Int, y: Int, width: Int, height: Int,
        sourceWidth: Int, sourceHeight: Int
    ) throws -> CGRect {
        guard width >= minimumWidth else {
            throw CropError.outOfBounds(
                "the crop width must be at least \(minimumWidth) pixels, got \(width)")
        }
        guard x >= 0, y >= 0 else {
            throw CropError.outOfBounds(
                "the crop origin must be inside the image, got (\(x), \(y))")
        }
        guard x + width <= sourceWidth else {
            throw CropError.outOfBounds(
                "the crop is too wide: \(x) + \(width) runs past the image width of "
                    + "\(sourceWidth)")
        }

        let snappedHeight = roundedHeight(forWidth: width)
        guard y + snappedHeight <= sourceHeight else {
            throw CropError.outOfBounds(
                "the crop is too tall at this width: \(y) + \(snappedHeight) (the 8:5 height "
                    + "for a width of \(width)) runs past the image height of \(sourceHeight)")
        }

        return CGRect(x: x, y: y, width: width, height: snappedHeight)
    }

    /// `width · 5 / 8`, rounded half up, in integers.
    ///
    /// Integer arithmetic rather than `Double.rounded()` so the result cannot
    /// depend on floating-point representation: for positive values the two
    /// agree exactly, and this way there is nothing to argue about.
    private static func roundedHeight(forWidth width: Int) -> Int {
        (width * aspectHeight + aspectWidth / 2) / aspectWidth
    }
}
