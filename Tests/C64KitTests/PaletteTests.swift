import XCTest
@testable import C64Kit

final class PaletteTests: XCTestCase {

    // MARK: - Table contents

    func testBothPalettesHaveSixteenColors() {
        XCTAssertEqual(C64Palette.colodore.colors.count, 16)
        XCTAssertEqual(C64Palette.pepto.colors.count, 16)
    }

    func testColodoreSpotValues() {
        XCTAssertEqual(C64Palette.colodore.colors[0], RGB(r: 0x00, g: 0x00, b: 0x00))
        XCTAssertEqual(C64Palette.colodore.colors[2], RGB(r: 0x81, g: 0x33, b: 0x38))
        XCTAssertEqual(C64Palette.colodore.colors[9], RGB(r: 0x55, g: 0x38, b: 0x00))
        XCTAssertEqual(C64Palette.colodore.colors[15], RGB(r: 0xB2, g: 0xB2, b: 0xB2))
    }

    func testPeptoSpotValues() {
        XCTAssertEqual(C64Palette.pepto.colors[1], RGB(r: 0xFF, g: 0xFF, b: 0xFF))
        XCTAssertEqual(C64Palette.pepto.colors[7], RGB(r: 0xB8, g: 0xC7, b: 0x6F))
        XCTAssertEqual(C64Palette.pepto.colors[14], RGB(r: 0x6C, g: 0x5E, b: 0xB5))
    }

    func testPalettesDifferAwayFromBlackAndWhite() {
        // A guard against one table being pasted twice.
        XCTAssertNotEqual(C64Palette.colodore.colors[2], C64Palette.pepto.colors[2])
        XCTAssertEqual(C64Palette.allCases, [.colodore, .pepto])
    }

    // MARK: - Distance

    func testDistanceIsZeroForIdenticalColors() {
        let c = RGB(r: 0x12, g: 0x34, b: 0x56)
        XCTAssertEqual(C64Palette.distance(c, c), 0)
    }

    func testDistanceIsWeightedSquaredDifference() {
        let a = RGB(r: 10, g: 20, b: 30)
        let b = RGB(r: 20, g: 40, b: 60)
        // 0.299*100 + 0.587*400 + 0.114*900
        XCTAssertEqual(C64Palette.distance(a, b), 0.299 * 100 + 0.587 * 400 + 0.114 * 900, accuracy: 1e-9)
    }

    func testDistanceIsSymmetric() {
        let a = RGB(r: 3, g: 200, b: 41)
        let b = RGB(r: 199, g: 7, b: 250)
        XCTAssertEqual(C64Palette.distance(a, b), C64Palette.distance(b, a))
    }

    // MARK: - Nearest index

    func testEveryPaletteColorIsItsOwnNearestIndex() {
        for palette in C64Palette.allCases {
            for (index, color) in palette.colors.enumerated() {
                XCTAssertEqual(
                    palette.nearestIndex(to: color), UInt8(index),
                    "\(palette.rawValue) index \(index) did not map to itself")
            }
        }
    }

    func testNearestIndexForANearMiss() {
        // One step off colodore 2 (#813338).
        XCTAssertEqual(C64Palette.colodore.nearestIndex(to: RGB(r: 0x80, g: 0x33, b: 0x38)), 2)
    }

    func testTieBreaksTowardTheLowerIndex() {
        // #4C7058 is exactly equidistant from colodore 11 (#4A4A4A) and
        // colodore 12 (#7B7B7B) under the weighted metric, and no other entry
        // is closer — so the tie-break rule alone decides the answer.
        let tied = RGB(r: 0x4C, g: 0x70, b: 0x58)
        let palette = C64Palette.colodore
        let d11 = C64Palette.distance(tied, palette.colors[11])
        let d12 = C64Palette.distance(tied, palette.colors[12])
        XCTAssertEqual(d11, d12, "test fixture is no longer an exact tie")
        for (index, color) in palette.colors.enumerated() where index != 11 && index != 12 {
            XCTAssertGreaterThan(
                C64Palette.distance(tied, color), d11,
                "index \(index) is closer than the tied pair; fixture is invalid")
        }
        XCTAssertEqual(palette.nearestIndex(to: tied), 11)
    }

    // MARK: - Settings

    func testConversionSettingsDefaults() {
        let settings = ConversionSettings()
        XCTAssertEqual(settings.mode, .multicolor)
        XCTAssertEqual(settings.dither, .fs)
        XCTAssertEqual(settings.brightness, 0)
        XCTAssertEqual(settings.contrast, 0)
        XCTAssertEqual(settings.saturation, 0)
        XCTAssertEqual(settings.palette, .colodore)
    }

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(C64Palette.colodore.rawValue, "colodore")
        XCTAssertEqual(C64Palette.pepto.rawValue, "pepto")
        XCTAssertEqual(BitmapMode.hires.rawValue, "hires")
        XCTAssertEqual(BitmapMode.multicolor.rawValue, "multicolor")
        XCTAssertEqual(DitherMode.none.rawValue, "none")
        XCTAssertEqual(DitherMode.bayer.rawValue, "bayer")
        XCTAssertEqual(DitherMode.fs.rawValue, "fs")
    }

    func testConversionSettingsRoundTripsThroughJSON() throws {
        var settings = ConversionSettings()
        settings.mode = .hires
        settings.dither = .bayer
        settings.brightness = 0.25
        settings.contrast = -0.5
        settings.saturation = 1
        settings.palette = .pepto

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ConversionSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }
}
