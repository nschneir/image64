import CoreGraphics

/// One of the nine parts of the crop overlay a pointer can grab.
///
/// The four corners and four edges are the resize handles; `body` is the
/// interior — grabbing it moves the whole rectangle without changing shape.
public enum CropHandle: CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    case top, bottom, left, right
    case body
}

/// The crop-drag arithmetic the app's overlay drives.
///
/// Kept out of `CropGeometry` because the CLI never sees a drag: the CLI
/// parses `--crop` once, `CropGeometry.snap` returns a legal rectangle, and
/// that is the end of it. The overlay, by contrast, gets one of these calls
/// per pointer event, and needs a strictly interactive contract that
/// `CropGeometry` deliberately does not have.
///
/// The three invariants pinned by `CropGeometry` still hold:
///
/// * The rectangle stays exactly 8:5 — `width · 5 == height · 8` in integers,
///   not "close enough" — because a C64 picture is 8:5 and a crop of any
///   other shape produces a stretched conversion.
/// * The rectangle stays inside the source. The user's pointer can happily
///   describe a rectangle that runs off the image; this function is what
///   turns "past the edge" into "flush with the edge" instead of refusing
///   the drag outright.
/// * Every edge lands on an integer pixel row or column, so the resulting
///   conversion is byte-reproducible between machines.
///
/// The one thing the interactive path adds is the *anchor*: whichever handle
/// the pointer grabbed, the opposite corner or edge does not move. That is
/// what makes the drag feel like resizing a picture — grabbing the bottom
/// right and pulling makes the picture grow toward the pointer, not slide
/// under the still-anchored top-left corner. Every entry in `anchor(for:of:)`
/// is that opposite point for the given handle.
public enum CropInteraction {

    /// The C64 frame's 8:5 ratio, written as the two constants the arithmetic
    /// uses. Same names (and reason) as `CropGeometry`'s pair.
    private static let aspectWidth: CGFloat = 8
    private static let aspectHeight: CGFloat = 5

    /// Apply one pointer drag to a crop rectangle and return the settled
    /// result.
    ///
    /// - `handle`: which grip the pointer grabbed.
    /// - `delta`: how far the pointer moved since the last event, in source
    ///   pixels; positive `width` is rightward and positive `height` is
    ///   downward, matching the app's overlay and `ImageLoading.prepare`.
    /// - `bounds`: the size of the source image the crop sits inside.
    /// - `minWidth`: the narrowest width the caller is willing to accept, in
    ///   source pixels. The result is clamped up to `minWidth` *rounded up
    ///   to the nearest multiple of eight* — see the width-snap paragraph
    ///   below for why the eight-grid is not negotiable. It is a floor, not a
    ///   guarantee: a source too small to hold `minWidth` gets the largest
    ///   legal crop instead, because staying inside the source outranks it
    ///   (see `resize`).
    ///
    /// Corner and edge handles resize about the opposite anchor; `body`
    /// translates the rectangle without changing its size and stops flush
    /// with each source edge instead of running past it.
    ///
    /// The returned width is always a multiple of eight so that the derived
    /// `height = width · 5 / 8` lands on an integer row — the same reasoning
    /// as `CropGeometry.snap`, and the same non-negotiable pin. Flooring
    /// width to /8 is not a rounding *choice*: a width of, say, 100 gives a
    /// height of 62.5, which is not a real pixel row and would resample
    /// differently on two machines. Pinning to /8 makes the arithmetic exact.
    public static func drag(
        _ rect: CGRect, handle: CropHandle,
        by delta: CGSize,
        in bounds: CGSize, minWidth: CGFloat
    ) -> CGRect {
        switch handle {
        case .body:
            return translate(rect, by: delta, in: bounds)
        case .top, .bottom, .left, .right,
             .topLeft, .topRight, .bottomLeft, .bottomRight:
            return resize(rect, handle: handle, by: delta, in: bounds, minWidth: minWidth)
        }
    }

    /// The opposite corner the grabbed handle resizes about. Edge handles
    /// share a corner with their diagonal sibling (see `anchor(for:of:)`),
    /// so the four values are enough to name every anchor the code needs.
    private enum Anchor {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Move the rectangle wholesale, stopping cleanly at each source edge.
    ///
    /// A `body` drag has no resize component, so the size is copied through
    /// untouched and the origin is clamped so all four edges stay inside
    /// `bounds`. The clamp windows are `[0, bounds.width − rect.width]` and
    /// `[0, bounds.height − rect.height]`; running past either end stops the
    /// origin at the far end rather than off-canvas.
    private static func translate(_ rect: CGRect, by delta: CGSize, in bounds: CGSize) -> CGRect {
        let x = clamp(rect.origin.x + delta.width,  0, bounds.width  - rect.width)
        let y = clamp(rect.origin.y + delta.height, 0, bounds.height - rect.height)
        // Floor to integer pixels: a fractional pointer delta could otherwise
        // leave the origin on a half-pixel column and resample differently on
        // two machines. The clamp end-points are integer for an integer source
        // and an integer starting rect, so this floor only bites in the
        // middle of the range — exactly where it needs to.
        return CGRect(
            x: x.rounded(.down), y: y.rounded(.down),
            width: rect.width, height: rect.height)
    }

    /// Resize about the opposite anchor, keeping the 8:5 ratio exact and the
    /// rectangle inside the source.
    ///
    /// The width is snapped down to a multiple of eight so the derived height
    /// is integer, then clamped into `[lower, upper]` where `lower` is the
    /// caller's `minWidth` rounded *up* to the eight-grid (a floor there
    /// could quietly let the width drop below the requested minimum) and
    /// `upper` is the largest legal width the anchor allows, rounded *down*
    /// (a ceil there would push the far edge off-canvas). Both edges of the
    /// clamp therefore land on integers by construction, and the height that
    /// falls out of `width · 5 / 8` is a multiple of five.
    ///
    /// **When the two limits disagree, `upper` wins.** A source smaller than
    /// the caller's `minWidth` — a 64×40 image against the app's 80-pixel
    /// `minCropWidth` — leaves no width that is both ≥ `minWidth` and inside
    /// the image. "Stays inside the source" is one of the three invariants this
    /// file documents; `minWidth` is a comfort guardrail against a drag
    /// collapsing the rect to a sliver. So the floor is clamped down to the
    /// room actually available rather than the other way round. Letting the
    /// floor win instead returned a rect outside `bounds`, which `effectiveCrop`
    /// then clipped downstream — turning a legal-looking drag into a non-8:5
    /// sample and a stretched conversion.
    private static func resize(
        _ rect: CGRect, handle: CropHandle, by delta: CGSize,
        in bounds: CGSize, minWidth: CGFloat
    ) -> CGRect {
        let (anchor, point) = anchor(for: handle, of: rect)
        let raw = targetWidth(for: handle, rect: rect, delta: delta)

        // `max(0, …)` only bites if `rect` was already outside `bounds` on
        // entry, which no caller can produce through this function: for any
        // rect legally inside the source the anchor leaves at least one
        // eight-column step of room in both directions, so `upper >= 8`.
        // It is here so a bad rect degrades to a degenerate-but-inside result
        // rather than a negative-width one.
        let upper = Swift.max(0, floorToEight(maxWidth(from: anchor, at: point, in: bounds)))
        let lower = Swift.min(ceilToEight(Swift.max(minWidth, aspectWidth)), upper)
        let newWidth = clamp(floorToEight(raw), lower, upper)
        let newHeight = newWidth * aspectHeight / aspectWidth

        return place(anchor: anchor, at: point, width: newWidth, height: newHeight)
    }

    /// The opposite corner of the grabbed handle, and the current point that
    /// corner sits on.
    ///
    /// Edge handles share their diagonal sibling's anchor: `right` and
    /// `bottomRight` both anchor the top-left corner, `left` and `bottomLeft`
    /// both anchor the top-right, and so on. That way a right-edge drag
    /// leaves the *top* row where it started rather than centring the resize
    /// around the horizontal midline — matching the way the tests pin
    /// `origin.y` unchanged for a `right`-handle drag.
    ///
    /// The `body` case is unreachable — `drag` routes it through `translate`
    /// before this is called — and traps loudly instead of returning a
    /// meaningless anchor, so an accidental new caller is a crash rather
    /// than a silent wrong rectangle.
    private static func anchor(
        for handle: CropHandle, of rect: CGRect
    ) -> (Anchor, CGPoint) {
        switch handle {
        case .right, .bottom, .bottomRight:
            return (.topLeft,     CGPoint(x: rect.minX, y: rect.minY))
        case .left, .bottomLeft:
            return (.topRight,    CGPoint(x: rect.maxX, y: rect.minY))
        case .top, .topRight:
            return (.bottomLeft,  CGPoint(x: rect.minX, y: rect.maxY))
        case .topLeft:
            return (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        case .body:
            preconditionFailure("body drag has no anchor; translate is the correct branch")
        }
    }

    /// The width the pointer *described*, before snapping and clamping.
    ///
    /// Horizontal handles read `delta.width` straight through: pulling the
    /// right edge right by 40 pixels asks for a width 40 pixels larger.
    /// Vertical handles work through the ratio — the pointer moved the edge
    /// by `dy`, so the height wants to change by `dy` and the width by
    /// `dy · 8/5`. `delta.width` on a vertical-edge drag is ignored:
    /// letting a `bottom`-edge drag also pick up horizontal motion would
    /// pull the crop off-shape on the diagonal, which is exactly what the
    /// 8:5 pin exists to prevent.
    private static func targetWidth(
        for handle: CropHandle, rect: CGRect, delta: CGSize
    ) -> CGFloat {
        switch handle {
        case .right, .bottomRight, .topRight:
            return rect.width + delta.width
        case .left, .bottomLeft, .topLeft:
            return rect.width - delta.width
        case .bottom:
            return (rect.height + delta.height) * aspectWidth / aspectHeight
        case .top:
            return (rect.height - delta.height) * aspectWidth / aspectHeight
        case .body:
            return rect.width
        }
    }

    /// The widest legal width for the given anchor, before eight-grid
    /// snapping.
    ///
    /// Two constraints have to hold simultaneously: the *far* horizontal edge
    /// must stay inside `bounds.width`, and the derived height (`width · 5/8`)
    /// must fit under `bounds.height` in the direction the anchor lets the
    /// rectangle grow. Whichever binds first is the ceiling — the resize
    /// then commits at the largest legal step instead of quietly refusing a
    /// drag that ran off one axis.
    private static func maxWidth(from anchor: Anchor, at p: CGPoint, in bounds: CGSize) -> CGFloat {
        let widthRoom: CGFloat
        let heightRoom: CGFloat
        switch anchor {
        case .topLeft:
            widthRoom  = bounds.width  - p.x
            heightRoom = bounds.height - p.y
        case .topRight:
            widthRoom  = p.x
            heightRoom = bounds.height - p.y
        case .bottomLeft:
            widthRoom  = bounds.width  - p.x
            heightRoom = p.y
        case .bottomRight:
            widthRoom  = p.x
            heightRoom = p.y
        }
        return Swift.min(widthRoom, heightRoom * aspectWidth / aspectHeight)
    }

    /// Place a rectangle of the given size so its named anchor corner lands
    /// exactly on `p`.
    ///
    /// This is the step that makes "the opposite corner does not move"
    /// literal: the origin is derived from the anchor and the size, never
    /// from the previous rectangle, so any drift from the earlier arithmetic
    /// cannot leak in here.
    private static func place(
        anchor: Anchor, at p: CGPoint, width: CGFloat, height: CGFloat
    ) -> CGRect {
        let origin: CGPoint
        switch anchor {
        case .topLeft:     origin = CGPoint(x: p.x,          y: p.y)
        case .topRight:    origin = CGPoint(x: p.x - width,  y: p.y)
        case .bottomLeft:  origin = CGPoint(x: p.x,          y: p.y - height)
        case .bottomRight: origin = CGPoint(x: p.x - width,  y: p.y - height)
        }
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    /// Clamp `v` to `[lo, hi]`. A tiny local helper because the standard
    /// library does not ship one and the two-nested-calls version reads
    /// backwards.
    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.max(lo, Swift.min(hi, v))
    }

    /// Round down to the nearest multiple of eight. Used for the width
    /// target and the width ceiling: both rounding toward zero would let a
    /// value creep past the intended limit.
    private static func floorToEight(_ value: CGFloat) -> CGFloat {
        (value / aspectWidth).rounded(.down) * aspectWidth
    }

    /// Round up to the nearest multiple of eight. Used for the width floor
    /// so a `minWidth` the caller passed as, say, 81 does not collapse to 80
    /// and slip below the requested minimum.
    private static func ceilToEight(_ value: CGFloat) -> CGFloat {
        (value / aspectWidth).rounded(.up) * aspectWidth
    }
}
