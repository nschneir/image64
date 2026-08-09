import CoreGraphics
import Foundation
import XCTest

@testable import C64Kit

final class ImageLoadingTests: XCTestCase {

    // MARK: - Scratch directory

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("image64-loading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: - Colour helpers
    //
    // Everything that goes through Core Image is compared with a tolerance:
    // sRGB → working space → sRGB is a lossy round trip and Lanczos resampling
    // rings slightly even on flat fields. ±2 per channel is well below anything
    // quantization can see (the nearest colodore colours are dozens of units
    // apart) and well above the colour-management slop.

    private func assertClose(
        _ actual: RGB, _ expected: RGB, tolerance: Int = 2, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let distances = [
            abs(Int(actual.r) - Int(expected.r)),
            abs(Int(actual.g) - Int(expected.g)),
            abs(Int(actual.b) - Int(expected.b)),
        ]
        XCTAssertTrue(
            distances.allSatisfy { $0 <= tolerance },
            "\(message) expected \(expected) ±\(tolerance), got \(actual)", file: file, line: line)
    }

    private func meanGreen(_ buffer: RGBBuffer) -> Double {
        buffer.pixels.reduce(0.0) { $0 + Double($1.g) } / Double(buffer.pixels.count)
    }

    /// The pixels of a `CGImage`, row-major with row 0 the top row.
    ///
    /// Drawn into an sRGB bitmap context rather than read out of the image's
    /// own data provider so the result is independent of how the image under
    /// test happens to be laid out.
    private func pixels(of image: CGImage) -> RGBBuffer {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var pixels: [RGB] = []
        pixels.reserveCapacity(width * height)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            pixels.append(RGB(r: bytes[index], g: bytes[index + 1], b: bytes[index + 2]))
        }
        return RGBBuffer(width: width, height: height, pixels: pixels)
    }

    /// A `width`×`height` image whose top half is `top` and bottom half is
    /// `bottom`, in the top-down sense the engine uses.
    ///
    /// Not in `TestImageFactory` because only the axis-convention tests need
    /// it; the factory's contract is the horizontal ramp the CLI tests share.
    private func verticallySplitImage(
        width: Int, height: Int, top: RGB, bottom: RGB
    ) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        func fill(_ color: RGB, _ rect: CGRect) {
            context.setFillColor(
                CGColor(
                    srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                    blue: CGFloat(color.b) / 255, alpha: 1))
            context.fill(rect)
        }
        // CGContext's y grows upward, so the *upper* half of the drawn image is
        // the high-y rectangle.
        fill(top, CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        fill(bottom, CGRect(x: 0, y: 0, width: width, height: height / 2))
        let image = try XCTUnwrap(context.makeImage())
        // Self-check: this fixture is only useful if it really is top-down.
        assertClose(pixels(of: image)[0, 0], top, "fixture top row")
        assertClose(pixels(of: image)[0, height - 1], bottom, "fixture bottom row")
        return image
    }

    private let cyan = C64Palette.colodore.colors[3]
    private let darkGrey = RGB(r: 40, g: 40, b: 40)
    private let lightGrey = RGB(r: 200, g: 200, b: 200)

    // MARK: - (a) Load and prepare round trip

    func testSolidColorSurvivesLoadAndPrepare() throws {
        let file = url("cyan.png")
        TestImageFactory.makePNG(
            width: 320, height: 200, horizontalGradient: cyan, to: cyan, at: file)

        let image = try ImageLoading.loadCGImage(from: file)
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 200)

        let buffer = ImageLoading.prepare(
            image, cropRect: CGRect(x: 0, y: 0, width: 320, height: 200),
            targetWidth: 320, targetHeight: 200,
            brightness: 0, contrast: 0, saturation: 0)

        XCTAssertEqual(buffer.width, 320)
        XCTAssertEqual(buffer.height, 200)
        assertClose(buffer[160, 100], cyan, "centre pixel")
        assertClose(buffer[0, 0], cyan, "top-left pixel")
        assertClose(buffer[319, 199], cyan, "bottom-right pixel")
    }

    // MARK: - (b) Anamorphic resize

    func testGradientResizesToTheMulticolorGeometry() throws {
        let file = url("gradient.png")
        TestImageFactory.makePNG(
            width: 640, height: 400, horizontalGradient: darkGrey, to: lightGrey, at: file)
        let image = try ImageLoading.loadCGImage(from: file)

        let buffer = ImageLoading.prepare(
            image, cropRect: CGRect(x: 0, y: 0, width: 640, height: 400),
            targetWidth: 160, targetHeight: 200,
            brightness: 0, contrast: 0, saturation: 0)

        XCTAssertEqual(buffer.width, 160)
        XCTAssertEqual(buffer.height, 200)
        XCTAssertEqual(buffer.pixels.count, 160 * 200)
    }

    func testAnamorphicResizeKeepsTheRampOnTheHorizontalAxis() throws {
        let file = url("gradient.png")
        TestImageFactory.makePNG(
            width: 640, height: 400, horizontalGradient: darkGrey, to: lightGrey, at: file)
        let image = try ImageLoading.loadCGImage(from: file)

        let buffer = ImageLoading.prepare(
            image, cropRect: CGRect(x: 0, y: 0, width: 640, height: 400),
            targetWidth: 160, targetHeight: 200,
            brightness: 0, contrast: 0, saturation: 0)

        // The ramp must still run left to right after a 4× horizontal and 2×
        // vertical squeeze — a transposed aspect correction would flatten it.
        for y in stride(from: 0, to: 200, by: 50) {
            XCTAssertLessThan(
                Int(buffer[8, y].g), Int(buffer[80, y].g), "row \(y): left is darker than centre")
            XCTAssertLessThan(
                Int(buffer[80, y].g), Int(buffer[151, y].g), "row \(y): centre is darker than right")
        }
        // A vertical ramp would show up here; the source has none.
        assertClose(buffer[80, 0], buffer[80, 199], tolerance: 4, "column 80 top vs bottom")
    }

    // MARK: - (c) Adjustments

    func testBrightnessIsMonotonic() throws {
        let file = url("gradient.png")
        TestImageFactory.makePNG(
            width: 320, height: 200, horizontalGradient: darkGrey, to: lightGrey, at: file)
        let image = try ImageLoading.loadCGImage(from: file)
        let full = CGRect(x: 0, y: 0, width: 320, height: 200)

        func meanGreen(brightness: Double) -> Double {
            self.meanGreen(
                ImageLoading.prepare(
                    image, cropRect: full, targetWidth: 320, targetHeight: 200,
                    brightness: brightness, contrast: 0, saturation: 0))
        }

        let dark = meanGreen(brightness: -1)
        let neutral = meanGreen(brightness: 0)
        let bright = meanGreen(brightness: +1)
        XCTAssertLessThan(dark, neutral)
        XCTAssertLessThan(neutral, bright)
    }

    func testContrastIsMonotonicAboutTheMidpoint() throws {
        let file = url("gradient.png")
        TestImageFactory.makePNG(
            width: 320, height: 200, horizontalGradient: darkGrey, to: lightGrey, at: file)
        let image = try ImageLoading.loadCGImage(from: file)
        let full = CGRect(x: 0, y: 0, width: 320, height: 200)

        func spread(contrast: Double) -> Int {
            let buffer = ImageLoading.prepare(
                image, cropRect: full, targetWidth: 320, targetHeight: 200,
                brightness: 0, contrast: contrast, saturation: 0)
            return Int(buffer[310, 100].g) - Int(buffer[10, 100].g)
        }
        XCTAssertLessThan(spread(contrast: -1), spread(contrast: 0))
        XCTAssertLessThan(spread(contrast: 0), spread(contrast: +1))
    }

    func testSaturationMinusOneIsGrey() throws {
        let file = url("cyan.png")
        TestImageFactory.makePNG(
            width: 320, height: 200, horizontalGradient: cyan, to: cyan, at: file)
        let image = try ImageLoading.loadCGImage(from: file)

        let buffer = ImageLoading.prepare(
            image, cropRect: CGRect(x: 0, y: 0, width: 320, height: 200),
            targetWidth: 320, targetHeight: 200,
            brightness: 0, contrast: 0, saturation: -1)

        let pixel = buffer[160, 100]
        XCTAssertEqual(Int(pixel.r), Int(pixel.g), accuracy: 2)
        XCTAssertEqual(Int(pixel.g), Int(pixel.b), accuracy: 2)
    }

    func testZeroAdjustmentsAreTheIdentityMapping() throws {
        let file = url("gradient.png")
        TestImageFactory.makePNG(
            width: 320, height: 200, horizontalGradient: darkGrey, to: lightGrey, at: file)
        let image = try ImageLoading.loadCGImage(from: file)

        let buffer = ImageLoading.prepare(
            image, cropRect: CGRect(x: 0, y: 0, width: 320, height: 200),
            targetWidth: 320, targetHeight: 200,
            brightness: 0, contrast: 0, saturation: 0)

        for x in [0, 1, 160, 318, 319] {
            assertClose(
                buffer[x, 100],
                TestImageFactory.gradientColor(from: darkGrey, to: lightGrey, width: 320, x: x),
                "column \(x)")
        }
    }

    // MARK: - Crop rectangle conventions
    //
    // The pinned convention is top-down (y = 0 is the top row of the source),
    // which is the opposite of Core Image's bottom-up space. These two tests
    // are what stops the conversion silently being flipped.

    func testPreparedBufferIsTopDown() throws {
        let image = try verticallySplitImage(width: 64, height: 64, top: cyan, bottom: darkGrey)

        let buffer = ImageLoading.prepare(
            image, cropRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            targetWidth: 64, targetHeight: 64, brightness: 0, contrast: 0, saturation: 0)

        assertClose(buffer[32, 2], cyan, "row 2 must be the source's top half")
        assertClose(buffer[32, 61], darkGrey, "row 61 must be the source's bottom half")
    }

    func testCropRectYIsMeasuredFromTheTop() throws {
        let image = try verticallySplitImage(width: 64, height: 64, top: cyan, bottom: darkGrey)

        let top = ImageLoading.prepare(
            image, cropRect: CGRect(x: 0, y: 0, width: 64, height: 32),
            targetWidth: 32, targetHeight: 32, brightness: 0, contrast: 0, saturation: 0)
        let bottom = ImageLoading.prepare(
            image, cropRect: CGRect(x: 0, y: 32, width: 64, height: 32),
            targetWidth: 32, targetHeight: 32, brightness: 0, contrast: 0, saturation: 0)

        assertClose(top[16, 16], cyan, "crop at y = 0 is the top half")
        assertClose(bottom[16, 16], darkGrey, "crop at y = 32 is the bottom half")
    }

    func testACropSpanningTheSeamKeepsItsOwnRowsInOrder() throws {
        // Uniform crops cannot tell a correct pair of flips from two wrong ones,
        // so crop across the colour change: the seam has to land in the middle
        // of the prepared buffer with cyan above it.
        let image = try verticallySplitImage(width: 64, height: 64, top: cyan, bottom: darkGrey)

        let buffer = ImageLoading.prepare(
            image, cropRect: CGRect(x: 0, y: 16, width: 64, height: 32),
            targetWidth: 32, targetHeight: 32, brightness: 0, contrast: 0, saturation: 0)

        assertClose(buffer[16, 2], cyan, "the crop's upper rows come from above the seam")
        assertClose(buffer[16, 29], darkGrey, "the crop's lower rows come from below the seam")
    }

    func testCropRectXSelectsThePartOfTheRampItNames() throws {
        let file = url("gradient.png")
        TestImageFactory.makePNG(
            width: 320, height: 200, horizontalGradient: darkGrey, to: lightGrey, at: file)
        let image = try ImageLoading.loadCGImage(from: file)

        let left = ImageLoading.prepare(
            image, cropRect: CGRect(x: 0, y: 0, width: 160, height: 200),
            targetWidth: 160, targetHeight: 200, brightness: 0, contrast: 0, saturation: 0)
        let right = ImageLoading.prepare(
            image, cropRect: CGRect(x: 160, y: 0, width: 160, height: 200),
            targetWidth: 160, targetHeight: 200, brightness: 0, contrast: 0, saturation: 0)

        assertClose(
            left[80, 100],
            TestImageFactory.gradientColor(from: darkGrey, to: lightGrey, width: 320, x: 80),
            "centre of the left crop is source column 80")
        assertClose(
            right[80, 100],
            TestImageFactory.gradientColor(from: darkGrey, to: lightGrey, width: 320, x: 240),
            "centre of the right crop is source column 240")
    }

    func testCropOutsideTheImageFallsBackToTheWholeImage() throws {
        let file = url("cyan.png")
        TestImageFactory.makePNG(
            width: 320, height: 200, horizontalGradient: cyan, to: cyan, at: file)
        let image = try ImageLoading.loadCGImage(from: file)

        let buffer = ImageLoading.prepare(
            image, cropRect: CGRect(x: 900, y: 900, width: 10, height: 10),
            targetWidth: 32, targetHeight: 20, brightness: 0, contrast: 0, saturation: 0)

        XCTAssertEqual(buffer.width, 32)
        XCTAssertEqual(buffer.height, 20)
        assertClose(buffer[16, 10], cyan, "a crop that misses the image prepares all of it")
    }

    // MARK: - (d) Failure paths

    func testLoadingAMissingFileThrowsUnreadable() {
        let missing = url("nope.png")
        XCTAssertThrowsError(try ImageLoading.loadCGImage(from: missing)) { error in
            XCTAssertEqual(error as? ImageLoadingError, .unreadable(missing))
        }
    }

    func testLoadingANonImageThrowsUnreadable() throws {
        let file = url("not-an-image.png")
        try Data("this is not a PNG".utf8).write(to: file)
        XCTAssertThrowsError(try ImageLoading.loadCGImage(from: file)) { error in
            XCTAssertEqual(error as? ImageLoadingError, .unreadable(file))
        }
    }

    func testWritingToAMissingDirectoryThrowsUnwritable() throws {
        let file = url("cyan.png")
        TestImageFactory.makePNG(
            width: 8, height: 8, horizontalGradient: cyan, to: cyan, at: file)
        let image = try ImageLoading.loadCGImage(from: file)

        let destination = url("no-such-directory/out.png")
        XCTAssertThrowsError(try ImageLoading.writePNG(image, to: destination)) { error in
            XCTAssertEqual(error as? ImageLoadingError, .unwritable(destination))
        }
    }

    // MARK: - (e) Nearest-neighbour output

    func testCGImageFromBufferScalesByPixelReplication() throws {
        let red = RGB(r: 255, g: 0, b: 0)
        let green = RGB(r: 0, g: 255, b: 0)
        let blue = RGB(r: 0, g: 0, b: 255)
        let white = RGB(r: 255, g: 255, b: 255)
        let buffer = RGBBuffer(width: 2, height: 2, pixels: [red, green, blue, white])

        let image = ImageLoading.cgImage(from: buffer, scaleX: 4, scaleY: 2)
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 4)

        let out = pixels(of: image)
        // Nearest-neighbour: every pixel of the top-left 4×2 block is exactly
        // the source pixel, with no blend toward its neighbours anywhere in it.
        for y in 0..<2 {
            for x in 0..<4 {
                XCTAssertEqual(out[x, y], red, "(\(x), \(y)) must be the unblended source pixel")
            }
        }
        XCTAssertEqual(out[4, 0], green)
        XCTAssertEqual(out[0, 2], blue)
        XCTAssertEqual(out[7, 3], white)
    }

    func testCGImageFromBufferAtScaleOneIsTheBufferItself() {
        var buffer = RGBBuffer(
            width: 4, height: 3, pixels: Array(repeating: RGB(r: 0, g: 0, b: 0), count: 12))
        for y in 0..<3 {
            for x in 0..<4 {
                buffer[x, y] = RGB(r: UInt8(x * 60), g: UInt8(y * 80), b: 7)
            }
        }
        let image = ImageLoading.cgImage(from: buffer, scaleX: 1, scaleY: 1)
        XCTAssertEqual(pixels(of: image).pixels, buffer.pixels)
    }

    // MARK: - PNG output

    func testWritePNGRoundTripsThroughTheLoader() throws {
        var buffer = RGBBuffer(
            width: 5, height: 4, pixels: Array(repeating: RGB(r: 0, g: 0, b: 0), count: 20))
        for y in 0..<4 {
            for x in 0..<5 {
                buffer[x, y] = RGB(r: UInt8(x * 50), g: UInt8(y * 60), b: 3)
            }
        }
        let file = url("out.png")
        let image = ImageLoading.cgImage(from: buffer, scaleX: 2, scaleY: 2)
        try ImageLoading.writePNG(image, to: file)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let reloaded = try ImageLoading.loadCGImage(from: file)
        XCTAssertEqual(reloaded.width, 10)
        XCTAssertEqual(reloaded.height, 8)
        // PNG is lossless and the pixels were written as sRGB bytes, so this
        // one is exact rather than tolerant.
        XCTAssertEqual(pixels(of: reloaded)[0, 0], buffer[0, 0])
        XCTAssertEqual(pixels(of: reloaded)[9, 7], buffer[4, 3])
    }

    // MARK: - Determinism

    func testPrepareIsDeterministic() throws {
        let file = url("gradient.png")
        TestImageFactory.makePNG(
            width: 640, height: 400, horizontalGradient: darkGrey, to: lightGrey, at: file)
        let image = try ImageLoading.loadCGImage(from: file)

        func run() -> [RGB] {
            ImageLoading.prepare(
                image, cropRect: CGRect(x: 20, y: 10, width: 600, height: 375),
                targetWidth: 160, targetHeight: 200,
                brightness: 0.3, contrast: -0.2, saturation: 0.5
            ).pixels
        }
        XCTAssertEqual(run(), run())
    }
}
