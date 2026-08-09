import CoreGraphics
import Foundation
import XCTest

@testable import C64Kit

/// The crop arithmetic, pinned case by case.
///
/// Every expected value below was worked out by hand from the two formulas in
/// `CropGeometry`'s documentation rather than by running the code and writing
/// down what came back — a table copied from the implementation cannot witness
/// the implementation being wrong.
final class CropGeometryTests: XCTestCase {

    // MARK: - Default crop

    /// One row of the default-crop table.
    private struct DefaultCase {
        let sourceWidth: Int
        let sourceHeight: Int
        let expected: CGRect
        /// Why this row is in the table, quoted in the failure message.
        let reason: String
        let line: UInt

        init(
            _ sourceWidth: Int, _ sourceHeight: Int, _ expected: CGRect, _ reason: String,
            line: UInt = #line
        ) {
            self.sourceWidth = sourceWidth
            self.sourceHeight = sourceHeight
            self.expected = expected
            self.reason = reason
            self.line = line
        }
    }

    func testDefaultCropIsTheLargestCentredEightByFiveRectangle() {
        let cases: [DefaultCase] = [
            // 4000·5 = 20000 > 2000·8 = 16000 → wider than 8:5, so height is
            // kept: width = 2000·8/5 = 3200, x = (4000 − 3200)/2 = 400.
            .init(4000, 2000, CGRect(x: 400, y: 0, width: 3200, height: 2000), "wider than 8:5"),

            // 1001·5 = 5005 > 500·8 = 4000 → wider. width = 500·8/5 = 800 and
            // the 201 leftover columns split unevenly: x = ⌊201/2⌋ = 100, so
            // the extra column falls on the right.
            .init(1001, 500, CGRect(x: 100, y: 0, width: 800, height: 500), "wider, odd remainder"),

            // 3000·5 = 15000 is *not* > 2000·8 = 16000 → taller than 8:5, so
            // width is kept: height = ⌊3000·5/8⌋ = 1875, y = ⌊125/2⌋ = 62.
            .init(3000, 2000, CGRect(x: 0, y: 62, width: 3000, height: 1875), "taller than 8:5"),

            // 1000·5 = 5000 < 1000·8 = 8000 → taller. height = ⌊625⌋ = 625,
            // y = ⌊375/2⌋ = 187.
            .init(1000, 1000, CGRect(x: 0, y: 187, width: 1000, height: 625), "square source"),

            // 1600·5 = 8000 equals 1000·8 = 8000 — *not* strictly greater, so
            // the second branch runs and returns the whole image.
            .init(1600, 1000, CGRect(x: 0, y: 0, width: 1600, height: 1000), "exactly 8:5"),

            // The C64's own geometry: the crop must be the identity, not a
            // rectangle one pixel short of the image.
            .init(320, 200, CGRect(x: 0, y: 0, width: 320, height: 200), "320×200 identity"),
        ]

        for row in cases {
            let crop = CropGeometry.defaultCrop(
                sourceWidth: row.sourceWidth, sourceHeight: row.sourceHeight)
            XCTAssertEqual(
                crop, row.expected,
                "\(row.sourceWidth)×\(row.sourceHeight) (\(row.reason))",
                file: #filePath, line: row.line)
        }
    }

    func testDefaultCropStaysInsideTheSourceAndIsEightByFive() {
        // A sweep rather than a table: whatever the shape, the rectangle must
        // fit and must be 8:5 to within the rounding the integer floors allow.
        for width in stride(from: 17, through: 4000, by: 331) {
            for height in stride(from: 13, through: 3000, by: 271) {
                let crop = CropGeometry.defaultCrop(sourceWidth: width, sourceHeight: height)
                XCTAssertGreaterThanOrEqual(crop.minX, 0, "\(width)×\(height)")
                XCTAssertGreaterThanOrEqual(crop.minY, 0, "\(width)×\(height)")
                XCTAssertLessThanOrEqual(crop.maxX, CGFloat(width), "\(width)×\(height)")
                XCTAssertLessThanOrEqual(crop.maxY, CGFloat(height), "\(width)×\(height)")
                XCTAssertGreaterThan(crop.width, 0, "\(width)×\(height)")

                // One pixel of slack: the height is floored, so the ratio can
                // sit just under 8:5 but never over it.
                let ratio = crop.width / crop.height
                XCTAssertGreaterThanOrEqual(ratio, 1.6 - 8.0 / crop.height, "\(width)×\(height)")
                XCTAssertLessThanOrEqual(ratio, 1.6 + 8.0 / crop.height, "\(width)×\(height)")
            }
        }
    }

    // MARK: - Snapping

    func testSnapReplacesTheHeightWithTheEightByFiveOne() throws {
        // The caller's 999 is discarded outright: only x, y and width survive.
        let snapped = try CropGeometry.snap(
            x: 0, y: 0, width: 800, height: 999, sourceWidth: 800, sourceHeight: 600)
        XCTAssertEqual(snapped, CGRect(x: 0, y: 0, width: 800, height: 500))
    }

    func testSnapKeepsTheOriginItIsGiven() throws {
        let snapped = try CropGeometry.snap(
            x: 37, y: 11, width: 320, height: 1, sourceWidth: 800, sourceHeight: 600)
        XCTAssertEqual(snapped, CGRect(x: 37, y: 11, width: 320, height: 200))
    }

    func testSnapRoundsTheHeightHalfUp() throws {
        // 12·5/8 = 7.5 → 8, and 13·5/8 = 8.125 → 8. Rounding rather than
        // flooring keeps a drag-resized crop from creeping shorter each time.
        let twelve = try CropGeometry.snap(
            x: 0, y: 0, width: 12, height: 0, sourceWidth: 100, sourceHeight: 100)
        XCTAssertEqual(twelve.height, 8)

        let thirteen = try CropGeometry.snap(
            x: 0, y: 0, width: 13, height: 0, sourceWidth: 100, sourceHeight: 100)
        XCTAssertEqual(thirteen.height, 8)

        // 11·5/8 = 6.875 → 7, which is the nearest, not the floor.
        let eleven = try CropGeometry.snap(
            x: 0, y: 0, width: 11, height: 0, sourceWidth: 100, sourceHeight: 100)
        XCTAssertEqual(eleven.height, 7)
    }

    func testSnapFitsExactlyAtTheBottomEdge() throws {
        // y + h' == sourceHeight is legal: the crop ends on the last row.
        let snapped = try CropGeometry.snap(
            x: 0, y: 100, width: 800, height: 0, sourceWidth: 800, sourceHeight: 600)
        XCTAssertEqual(snapped, CGRect(x: 0, y: 100, width: 800, height: 500))
    }

    func testSnapRejectsACropThatFallsOffTheBottom() {
        // y = 101 puts the snapped 500-row crop one row past a 600-row image.
        XCTAssertThrowsError(
            try CropGeometry.snap(
                x: 0, y: 101, width: 800, height: 500, sourceWidth: 800, sourceHeight: 600)
        ) { error in
            guard case CropError.outOfBounds(let message) = error else {
                return XCTFail("expected outOfBounds, got \(error)")
            }
            XCTAssertTrue(
                message.lowercased().contains("height") || message.lowercased().contains("tall"),
                "the message must name the offending dimension: \(message)")
            XCTAssertTrue(message.contains("600"), "the message must quote the limit: \(message)")
        }
    }

    func testSnapRejectsACropThatFallsOffTheRight() {
        XCTAssertThrowsError(
            try CropGeometry.snap(
                x: 100, y: 0, width: 800, height: 500, sourceWidth: 800, sourceHeight: 600)
        ) { error in
            guard case CropError.outOfBounds(let message) = error else {
                return XCTFail("expected outOfBounds, got \(error)")
            }
            XCTAssertTrue(
                message.lowercased().contains("width") || message.lowercased().contains("wide"),
                "the message must name the offending dimension: \(message)")
            XCTAssertTrue(message.contains("800"), "the message must quote the limit: \(message)")
        }
    }

    func testSnapRejectsAWidthNarrowerThanOneCell() {
        // Under 8 source pixels there is not even one C64 cell to resample into.
        XCTAssertThrowsError(
            try CropGeometry.snap(
                x: 0, y: 0, width: 7, height: 4, sourceWidth: 800, sourceHeight: 600)
        ) { error in
            guard case CropError.outOfBounds(let message) = error else {
                return XCTFail("expected outOfBounds, got \(error)")
            }
            XCTAssertTrue(
                message.lowercased().contains("width") || message.lowercased().contains("wide"),
                "the message must name the offending dimension: \(message)")
        }
    }

    func testSnapAcceptsTheNarrowestLegalWidth() throws {
        let snapped = try CropGeometry.snap(
            x: 0, y: 0, width: 8, height: 0, sourceWidth: 800, sourceHeight: 600)
        XCTAssertEqual(snapped, CGRect(x: 0, y: 0, width: 8, height: 5))
    }

    func testSnapRejectsANegativeOrigin() {
        XCTAssertThrowsError(
            try CropGeometry.snap(
                x: -1, y: 0, width: 800, height: 500, sourceWidth: 800, sourceHeight: 600)
        ) { XCTAssertEqual($0 as? CropError != nil, true, "expected a CropError, got \($0)") }

        XCTAssertThrowsError(
            try CropGeometry.snap(
                x: 0, y: -1, width: 800, height: 500, sourceWidth: 800, sourceHeight: 600)
        ) { XCTAssertEqual($0 as? CropError != nil, true, "expected a CropError, got \($0)") }
    }

    func testSnappingTheDefaultCropKeepsItInBounds() throws {
        // The two halves of this file have to agree. They do not agree
        // *exactly*: `defaultCrop` floors the derived height so the rectangle
        // provably fits, while `snap` rounds so that a user dragging an edge
        // does not watch the crop creep shorter. The contract that matters is
        // therefore weaker than equality — the origin and width survive, the
        // height moves by at most one row, and the result still fits the
        // source, so re-snapping the default (which the app does on the first
        // drag) can never throw.
        for width in stride(from: 64, through: 4000, by: 337) {
            for height in stride(from: 40, through: 3000, by: 293) {
                let crop = CropGeometry.defaultCrop(sourceWidth: width, sourceHeight: height)
                let snapped = try CropGeometry.snap(
                    x: Int(crop.origin.x), y: Int(crop.origin.y), width: Int(crop.width),
                    height: Int(crop.height), sourceWidth: width, sourceHeight: height)
                XCTAssertEqual(snapped.origin, crop.origin, "\(width)×\(height)")
                XCTAssertEqual(snapped.width, crop.width, "\(width)×\(height)")
                XCTAssertLessThanOrEqual(
                    abs(snapped.height - crop.height), 1, "\(width)×\(height)")
                XCTAssertLessThanOrEqual(snapped.maxX, CGFloat(width), "\(width)×\(height)")
                XCTAssertLessThanOrEqual(snapped.maxY, CGFloat(height), "\(width)×\(height)")
            }
        }
    }
}
