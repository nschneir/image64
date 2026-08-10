import CoreGraphics
import Foundation
import XCTest

@testable import C64Kit

/// The crop-drag arithmetic, pinned handle by handle.
///
/// Each expected value was worked out by hand from the rules in
/// `CropInteraction.drag`'s documentation: corner and edge handles resize
/// about the *opposite* anchor, width drives height (h = w·5/8), widths snap
/// to multiples of eight so the derived height stays integer, the `body`
/// handle translates without resizing, and the result never leaves the
/// source bounds. Copying values out of the implementation would only prove
/// the implementation matches itself.
final class CropInteractionTests: XCTestCase {

    // MARK: - Body drag

    /// One row of the body-drag table.
    private struct BodyCase {
        let delta: CGSize
        let expected: CGRect
        /// Why this row is in the table, quoted in the failure message.
        let reason: String
        let line: UInt

        init(_ delta: CGSize, _ expected: CGRect, _ reason: String, line: UInt = #line) {
            self.delta = delta
            self.expected = expected
            self.reason = reason
            self.line = line
        }
    }

    func testBodyDragTranslatesAndClampsAtBounds() {
        // A 200×125 rect sitting inside a 400×300 source. The body handle
        // must move it wholesale — no resizing, ever — and stop cleanly at
        // each edge instead of running past it.
        let start = CGRect(x: 100, y: 60, width: 200, height: 125)
        let bounds = CGSize(width: 400, height: 300)

        let cases: [BodyCase] = [
            // A tame, in-bounds nudge: origin shifts by the delta, size holds.
            .init(
                CGSize(width: 40, height: 30),
                CGRect(x: 140, y: 90, width: 200, height: 125),
                "in-bounds translation"),

            // Right edge would land at 100+200+9999 = 10299, but bounds.width
            // is 400 → the right edge stops at 400 and the origin lands at
            // 400 − 200 = 200. Height and width are untouched.
            .init(
                CGSize(width: 9999, height: 0),
                CGRect(x: 200, y: 60, width: 200, height: 125),
                "clamps at right edge"),

            // Top clamps at y = 0. x is unchanged because the horizontal
            // delta is zero.
            .init(
                CGSize(width: 0, height: -9999),
                CGRect(x: 100, y: 0, width: 200, height: 125),
                "clamps at top edge"),

            // Both clamps engage: the rect ends up flush with the top-left
            // corner and its size is preserved.
            .init(
                CGSize(width: -9999, height: -9999),
                CGRect(x: 0, y: 0, width: 200, height: 125),
                "clamps at top-left corner"),
        ]

        for row in cases {
            let result = CropInteraction.drag(
                start, handle: .body, by: row.delta, in: bounds, minWidth: 8)
            XCTAssertEqual(
                result, row.expected, row.reason,
                file: #filePath, line: row.line)
        }
    }

    // MARK: - Edge drag

    func testRightEdgeDragGrowsWidthAndDerivedHeightAboutTheLeftAnchor() {
        // A right-edge drag is a width change: the left edge is the anchor
        // and must not move, and the top edge is untouched (the horizontal
        // edge handles do not span vertically). The derived height comes
        // straight from the 8:5 rule.
        //
        // 200 + 80 = 280 is already a multiple of eight, so no snapping
        // rounds it away, and 280·5/8 = 175 is integer.
        let start = CGRect(x: 100, y: 60, width: 200, height: 125)
        let bounds = CGSize(width: 400, height: 300)

        let result = CropInteraction.drag(
            start, handle: .right, by: CGSize(width: 80, height: 0),
            in: bounds, minWidth: 8)

        XCTAssertEqual(result.origin.x, 100, "left edge is the anchor")
        XCTAssertEqual(result.origin.y, 60, "top edge is not touched by a horizontal-edge drag")
        XCTAssertEqual(result.width, 280, "width grew by the raw delta (already on the 8-grid)")
        XCTAssertEqual(result.height, 175, "height is width·5/8")
    }

    func testTopEdgeDragIsDrivenByTheVerticalDeltaAboutTheBottomAnchor() {
        // A vertical-edge drag is the ratio read backwards: the pointer moves
        // the *height* by `delta.height` and the width follows as h·8/5, with
        // the bottom edge as the anchor. `delta.width` is deliberately loud
        // here (999) and must be ignored, or a top-edge drag would pull the
        // crop off-shape on the diagonal.
        let start = CGRect(x: 100, y: 60, width: 200, height: 125)
        let bounds = CGSize(width: 400, height: 300)
        // The anchored edge: 60 + 125.
        let bottom: CGFloat = 185

        // Pulled up by 25: height 125 + 25 = 150, so width = 150·8/5 = 240
        // (already on the 8-grid), and the origin follows from the anchor —
        // y = 185 − 150 = 35.
        let grown = CropInteraction.drag(
            start, handle: .top, by: CGSize(width: 999, height: -25),
            in: bounds, minWidth: 8)
        XCTAssertEqual(
            grown, CGRect(x: 100, y: 35, width: 240, height: 150),
            "an upward top-edge drag grows about the bottom-left anchor")
        XCTAssertEqual(grown.maxY, bottom, "the bottom edge is the anchor and must not move")

        // Pushed down by 40: height 125 − 40 = 85, width = 85·8/5 = 136, and
        // y = 185 − 85 = 100.
        let shrunk = CropInteraction.drag(
            start, handle: .top, by: CGSize(width: -999, height: 40),
            in: bounds, minWidth: 8)
        XCTAssertEqual(
            shrunk, CGRect(x: 100, y: 100, width: 136, height: 85),
            "a downward top-edge drag shrinks about the same anchor")
        XCTAssertEqual(shrunk.maxY, bottom, "the bottom edge is the anchor and must not move")
    }

    // MARK: - Corner drag

    /// One row of the corner-anchor table.
    private struct CornerCase {
        let handle: CropHandle
        let delta: CGSize
        /// The corner that must not move, expressed as (x, y).
        let anchor: CGPoint
        /// How to pull the anchor point out of the resulting rect.
        let anchorOfResult: (CGRect) -> CGPoint
        let reason: String
        let line: UInt

        init(
            _ handle: CropHandle, _ delta: CGSize, anchor: CGPoint,
            anchorOfResult: @escaping (CGRect) -> CGPoint, _ reason: String,
            line: UInt = #line
        ) {
            self.handle = handle
            self.delta = delta
            self.anchor = anchor
            self.anchorOfResult = anchorOfResult
            self.reason = reason
            self.line = line
        }
    }

    func testCornerDragPreservesTheOppositeCorner() {
        // A 160×100 rect at (80, 40). Each corner drag pushes the corner
        // outward by (±40, ±25) so the width grows by 40 to 200 (a multiple
        // of eight — no snapping shaves it) and the derived height grows to
        // 200·5/8 = 125. The invariant that holds across all four rows is
        // that the *opposite* corner stays exactly where it started.
        let start = CGRect(x: 80, y: 40, width: 160, height: 100)
        let bounds = CGSize(width: 1024, height: 768)

        let cases: [CornerCase] = [
            .init(
                .bottomRight, CGSize(width: 40, height: 25),
                anchor: CGPoint(x: 80, y: 40),
                anchorOfResult: { $0.origin },
                "bottomRight drag anchors the top-left corner"),

            .init(
                .bottomLeft, CGSize(width: -40, height: 25),
                anchor: CGPoint(x: 240, y: 40),
                anchorOfResult: { CGPoint(x: $0.maxX, y: $0.origin.y) },
                "bottomLeft drag anchors the top-right corner"),

            .init(
                .topRight, CGSize(width: 40, height: -25),
                anchor: CGPoint(x: 80, y: 140),
                anchorOfResult: { CGPoint(x: $0.origin.x, y: $0.maxY) },
                "topRight drag anchors the bottom-left corner"),

            .init(
                .topLeft, CGSize(width: -40, height: -25),
                anchor: CGPoint(x: 240, y: 140),
                anchorOfResult: { CGPoint(x: $0.maxX, y: $0.maxY) },
                "topLeft drag anchors the bottom-right corner"),
        ]

        for row in cases {
            let result = CropInteraction.drag(
                start, handle: row.handle, by: row.delta, in: bounds, minWidth: 8)

            XCTAssertEqual(
                result.width, 200, "\(row.reason): width",
                file: #filePath, line: row.line)
            XCTAssertEqual(
                result.height, 125, "\(row.reason): height = width·5/8",
                file: #filePath, line: row.line)
            XCTAssertEqual(
                row.anchorOfResult(result), row.anchor,
                "\(row.reason): anchor must not move",
                file: #filePath, line: row.line)
        }
    }

    // MARK: - Sweep

    func testRandomDragsAreEightByFiveAndInBoundsAndIntegral() {
        // A property sweep: whatever the handle, whatever the delta, the
        // result must be exactly 8:5, must fit the source, must respect
        // minWidth, and must sit on integer pixel edges. The seeded PRNG
        // gives us the same 20 rows every run so a red row is reproducible.
        srand48(1)

        let bounds = CGSize(width: 1024, height: 768)
        let start = CGRect(x: 400, y: 200, width: 320, height: 200)
        let minWidth: CGFloat = 80
        let handles = CropHandle.allCases

        for iteration in 0..<20 {
            let handle = handles[Int(drand48() * Double(handles.count)) % handles.count]
            let dx = CGFloat(drand48() * 400.0 - 200.0)
            let dy = CGFloat(drand48() * 400.0 - 200.0)
            let delta = CGSize(width: dx, height: dy)

            let result = CropInteraction.drag(
                start, handle: handle, by: delta, in: bounds, minWidth: minWidth)

            let label =
                "iter \(iteration) handle=\(handle) delta=(\(dx), \(dy)) → \(result)"

            // Exact 8:5 via integer cross-multiplication — no floating slack.
            XCTAssertEqual(
                result.width * 5, result.height * 8,
                "not 8:5 — \(label)")

            // Inside the source rectangle on every side.
            XCTAssertGreaterThanOrEqual(result.origin.x, 0, "left off-canvas — \(label)")
            XCTAssertGreaterThanOrEqual(result.origin.y, 0, "top off-canvas — \(label)")
            XCTAssertLessThanOrEqual(result.maxX, bounds.width, "right off-canvas — \(label)")
            XCTAssertLessThanOrEqual(result.maxY, bounds.height, "bottom off-canvas — \(label)")

            // A too-narrow crop is worse than a clamped one; the drag must
            // never take the width below the floor.
            XCTAssertGreaterThanOrEqual(result.width, minWidth, "below minWidth — \(label)")

            // All four edges land on integer pixel columns/rows. `rounded`
            // returning the same value is the cleanest witness of that.
            XCTAssertEqual(result.origin.x, result.origin.x.rounded(), "x not integer — \(label)")
            XCTAssertEqual(result.origin.y, result.origin.y.rounded(), "y not integer — \(label)")
            XCTAssertEqual(result.width, result.width.rounded(), "width not integer — \(label)")
            XCTAssertEqual(result.height, result.height.rounded(), "height not integer — \(label)")
        }
    }

    // MARK: - Minimum width

    func testShrinkingRightEdgeStopsAtMinWidth() {
        // A giant negative delta on the right edge tries to collapse the
        // rect to nothing. It must stop cleanly at the minWidth floor with
        // the left anchor still in place and the height derived from the
        // floor width. 80·5/8 = 50, and the left edge remains at x = 100.
        let start = CGRect(x: 100, y: 60, width: 200, height: 125)
        let bounds = CGSize(width: 400, height: 300)

        let result = CropInteraction.drag(
            start, handle: .right, by: CGSize(width: -9999, height: 0),
            in: bounds, minWidth: 80)

        XCTAssertEqual(result.width, 80, "width clamps at minWidth")
        XCTAssertEqual(result.origin.x, 100, "left anchor must hold while shrinking")
        XCTAssertEqual(result.height, 50, "height = minWidth·5/8")
        XCTAssertEqual(result.origin.y, 60, "top edge is untouched by a horizontal-edge drag")
    }

    func testShrinkingBottomRightCornerStopsAtMinWidth() {
        // Same floor, but through a corner handle so both dimensions are
        // driven at once. The top-left corner is the anchor and must not
        // budge; the size collapses to the minWidth × derived-height pair.
        let start = CGRect(x: 100, y: 60, width: 200, height: 125)
        let bounds = CGSize(width: 400, height: 300)

        let result = CropInteraction.drag(
            start, handle: .bottomRight, by: CGSize(width: -9999, height: -9999),
            in: bounds, minWidth: 80)

        XCTAssertEqual(
            result, CGRect(x: 100, y: 60, width: 80, height: 50),
            "corner drag clamps at (anchor, minWidth × minWidth·5/8)")
    }

    func testMinWidthLosesToTheSourceWhenTheSourceIsSmaller() {
        // The source is smaller than the caller's minimum: a 64×40 image with
        // the app's 80-pixel `minCropWidth` (`CropView.minCropWidth`). Both
        // cannot hold, and "the rectangle stays inside the source" is the
        // documented invariant — the minimum is a comfort guardrail — so the
        // minimum is what gives way.
        //
        // Before the fix the clamp floor won: an outward bottom-right drag
        // returned 80×50 anchored at (0,0), i.e. a crop 16 columns and 10 rows
        // outside a 64×40 image. `effectiveCrop` then silently clipped it back
        // to 64×40 in the pipeline, which is no longer 8:5 — a stretched
        // conversion from a drag the user was told was legal.
        let bounds = CGSize(width: 64, height: 40)
        let start = CGRect(x: 0, y: 0, width: 64, height: 40)

        for (label, handle, delta) in [
            ("grow", CropHandle.bottomRight, CGSize(width: 500, height: 500)),
            ("shrink", CropHandle.bottomRight, CGSize(width: -500, height: -500)),
            ("right edge", CropHandle.right, CGSize(width: 500, height: 0)),
            ("bottom edge", CropHandle.bottom, CGSize(width: 0, height: 500)),
            ("top left", CropHandle.topLeft, CGSize(width: -500, height: -500)),
        ] {
            let result = CropInteraction.drag(
                start, handle: handle, by: delta, in: bounds, minWidth: 80)

            XCTAssertGreaterThanOrEqual(result.minX, 0, "left edge escaped — \(label)")
            XCTAssertGreaterThanOrEqual(result.minY, 0, "top edge escaped — \(label)")
            XCTAssertLessThanOrEqual(
                result.maxX, bounds.width, "right edge escaped — \(label)")
            XCTAssertLessThanOrEqual(
                result.maxY, bounds.height, "bottom edge escaped — \(label)")
            XCTAssertEqual(
                result.width * 5, result.height * 8, "not 8:5 — \(label)")
            XCTAssertGreaterThan(result.width, 0, "collapsed to nothing — \(label)")
        }
    }
}
