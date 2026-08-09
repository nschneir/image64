import CoreGraphics
import Foundation
import XCTest

@testable import C64Kit

/// End-to-end tests for the one entry point both front ends call.
///
/// These are the only tests in the suite that run a whole conversion, so they
/// are where the *composition* is pinned: that the buffer handed to the packer
/// really is 320×200 or 160×200, that the file on disk is the size the format
/// promises, that the PNG is 640×400 whichever mode produced it, and — the
/// point of the type existing at all — that the app's in-memory path and the
/// CLI's file path produce the same picture.
final class ConversionOperationTests: XCTestCase {

    // MARK: - Scratch directory

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("image64-conversion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Writes the standard input: a 640×400 horizontal ramp from blue to
    /// yellow. Wide enough to exercise the downscale, and coloured so that the
    /// quantizer has to choose between several palette entries per cell rather
    /// than landing on one flat colour.
    @discardableResult
    private func makeSource(
        name: String = "source.png", width: Int = 640, height: Int = 400
    ) -> URL {
        let source = url(name)
        TestImageFactory.makePNG(
            width: width, height: height,
            horizontalGradient: RGB(r: 0, g: 32, b: 200), to: RGB(r: 255, g: 220, b: 40),
            at: source)
        return source
    }

    private func request(
        _ source: URL, mode: BitmapMode, c64: URL? = nil, png: URL? = nil
    ) -> ConversionRequest {
        var settings = ConversionSettings()
        settings.mode = mode
        var request = ConversionRequest(inputURL: source, settings: settings)
        request.c64OutputURL = c64
        request.pngOutputURL = png
        return request
    }

    // MARK: - Re-deriving indices from a finished picture
    //
    // The cell-constraint invariant is asserted against `result.image` alone —
    // no peeking at the intermediate buffers — by rendering the packed bytes
    // and mapping each pixel back to the palette entry it exactly matches. An
    // inexact match would mean the renderer invented a colour, which is worth
    // failing on in its own right.

    /// Thrown — and so failing the test — if the renderer produces a colour no
    /// palette entry matches exactly.
    private struct UnknownRenderedColor: Error { let color: RGB }

    private func indices(of image: C64Image, palette: C64Palette) throws -> IndexBuffer {
        let rendered = image.render(palette: palette)
        var lookup: [RGBKey: UInt8] = [:]
        for (index, color) in palette.colors.enumerated() {
            lookup[RGBKey(color)] = UInt8(index)
        }
        var indices: [UInt8] = []
        indices.reserveCapacity(rendered.pixels.count)
        for pixel in rendered.pixels {
            guard let index = lookup[RGBKey(pixel)] else {
                throw UnknownRenderedColor(color: pixel)
            }
            indices.append(index)
        }
        return IndexBuffer(width: rendered.width, height: rendered.height, indices: indices)
    }

    /// `RGB` is `Equatable` but not `Hashable`; this is the two lines that
    /// makes the reverse lookup above a dictionary rather than a linear scan
    /// over sixteen colours for each of 64 000 pixels.
    private struct RGBKey: Hashable {
        let r: UInt8, g: UInt8, b: UInt8
        init(_ color: RGB) { (r, g, b) = (color.r, color.g, color.b) }
    }

    /// The distinct indices in the cell whose top-left corner is `(originX,
    /// originY)`.
    private func distinctIndices(
        in buffer: IndexBuffer, originX: Int, originY: Int, width: Int, height: Int
    ) -> Set<UInt8> {
        var found: Set<UInt8> = []
        for y in originY..<(originY + height) {
            for x in originX..<(originX + width) {
                found.insert(buffer[x, y])
            }
        }
        return found
    }

    // MARK: - (a) Multicolour, both outputs

    func testMulticolorRequestWritesKoalaAndPNG() throws {
        let source = makeSource()
        let koala = url("picture.koa")
        let png = url("picture.png")

        let result = try ConversionOperation.run(
            request(source, mode: .multicolor, c64: koala, png: png))

        XCTAssertEqual(result.writtenFiles, [koala, png], "both outputs, C64 file first")

        let data = try Data(contentsOf: koala)
        XCTAssertEqual(data.count, 10003, "a Koala file is 10003 bytes")
        XCTAssertEqual(Array(data.prefix(2)), [0x00, 0x60], "load address $6000")

        let exported = try ImageLoading.loadCGImage(from: png)
        XCTAssertEqual(exported.width, 640)
        XCTAssertEqual(exported.height, 400)

        XCTAssertEqual(result.image.mode, .multicolor)
        XCTAssertNotNil(result.image.colorRAM)
        XCTAssertNotNil(result.image.background)
    }

    // MARK: - (b) Hires

    func testHiresRequestWritesArtStudio() throws {
        let source = makeSource()
        let art = url("picture.art")
        let png = url("picture.png")

        let result = try ConversionOperation.run(request(source, mode: .hires, c64: art, png: png))

        XCTAssertEqual(result.writtenFiles, [art, png])

        let data = try Data(contentsOf: art)
        XCTAssertEqual(data.count, 9009, "an Art Studio file is 9009 bytes")
        XCTAssertEqual(Array(data.prefix(2)), [0x00, 0x20], "load address $2000")

        // Hires renders 320×200, so the PNG scale is 2×2 rather than
        // multicolour's 4×2 — and lands on the same 640×400.
        let exported = try ImageLoading.loadCGImage(from: png)
        XCTAssertEqual(exported.width, 640)
        XCTAssertEqual(exported.height, 400)

        XCTAssertEqual(result.image.mode, .hires)
        XCTAssertNil(result.image.colorRAM)
        XCTAssertNil(result.image.background)
    }

    // MARK: - (c) Mode and format must agree

    func testKoalaOutputWithHiresSettingsThrowsModeFormatMismatch() throws {
        let source = makeSource()
        XCTAssertThrowsError(
            try ConversionOperation.run(
                request(source, mode: .hires, c64: url("picture.koa")))
        ) { error in
            guard case ConversionRequestError.modeFormatMismatch(let message) = error else {
                return XCTFail("expected modeFormatMismatch, got \(error)")
            }
            XCTAssertTrue(message.contains("koa"), "the message must name the format: \(message)")
            XCTAssertTrue(message.contains("hires"), "the message must name the mode: \(message)")
        }
    }

    func testArtStudioOutputWithMulticolorSettingsThrowsModeFormatMismatch() throws {
        let source = makeSource()
        XCTAssertThrowsError(
            try ConversionOperation.run(
                request(source, mode: .multicolor, c64: url("picture.art")))
        ) { error in
            guard case ConversionRequestError.modeFormatMismatch = error else {
                return XCTFail("expected modeFormatMismatch, got \(error)")
            }
        }
    }

    func testUnknownOutputExtensionThrows() throws {
        let source = makeSource()
        XCTAssertThrowsError(
            try ConversionOperation.run(
                request(source, mode: .multicolor, c64: url("picture.gif")))
        ) { error in
            guard case ConversionRequestError.outputExtensionUnknown(let message) = error else {
                return XCTFail("expected outputExtensionUnknown, got \(error)")
            }
            XCTAssertTrue(message.contains("gif"), "the message must quote the extension")
        }
    }

    func testRejectionHappensBeforeAnythingIsWritten() throws {
        // The mismatch check runs on the request, not after a minute of
        // conversion — and it certainly must not leave a half-written file.
        let source = makeSource()
        let koala = url("picture.koa")
        let png = url("picture.png")
        XCTAssertThrowsError(
            try ConversionOperation.run(request(source, mode: .hires, c64: koala, png: png)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: koala.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: png.path))
    }

    // MARK: - (d) Determinism

    func testTwoRunsProduceByteIdenticalFiles() throws {
        let source = makeSource()
        let first = url("first.koa")
        let second = url("second.koa")

        _ = try ConversionOperation.run(request(source, mode: .multicolor, c64: first))
        _ = try ConversionOperation.run(request(source, mode: .multicolor, c64: second))

        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
    }

    func testTwoHiresRunsProduceByteIdenticalFiles() throws {
        let source = makeSource()
        let first = url("first.art")
        let second = url("second.art")

        _ = try ConversionOperation.run(request(source, mode: .hires, c64: first))
        _ = try ConversionOperation.run(request(source, mode: .hires, c64: second))

        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
    }

    // MARK: - (e) The cell-constraint invariant, measured on the output

    func testEveryHiresCellHoldsAtMostTwoColours() throws {
        let source = makeSource()
        let result = try ConversionOperation.run(request(source, mode: .hires))
        let buffer = try indices(of: result.image, palette: ConversionSettings().palette)

        XCTAssertEqual(buffer.width, 320)
        XCTAssertEqual(buffer.height, 200)
        for cellRow in 0..<25 {
            for cellColumn in 0..<40 {
                let distinct = distinctIndices(
                    in: buffer, originX: cellColumn * 8, originY: cellRow * 8,
                    width: 8, height: 8)
                XCTAssertLessThanOrEqual(
                    distinct.count, 2, "cell (\(cellColumn),\(cellRow)): \(distinct.sorted())")
            }
        }
    }

    func testEveryMulticolorCellHoldsTheBackgroundPlusAtMostThree() throws {
        let source = makeSource()
        let result = try ConversionOperation.run(request(source, mode: .multicolor))
        let background = try XCTUnwrap(result.image.background)
        let buffer = try indices(of: result.image, palette: ConversionSettings().palette)

        XCTAssertEqual(buffer.width, 160)
        XCTAssertEqual(buffer.height, 200)
        for cellRow in 0..<25 {
            for cellColumn in 0..<40 {
                let distinct = distinctIndices(
                    in: buffer, originX: cellColumn * 4, originY: cellRow * 8,
                    width: 4, height: 8)
                let foreground = distinct.subtracting([background])
                XCTAssertLessThanOrEqual(
                    foreground.count, 3, "cell (\(cellColumn),\(cellRow)): \(distinct.sorted())")
            }
        }
    }

    func testPackedMulticolorPictureReproducesTheConstrainedBufferExactly() throws {
        try assertPackedPictureReproducesTheConstrainedBuffer(mode: .multicolor)
    }

    func testPackedHiresPictureReproducesTheConstrainedBufferExactly() throws {
        // Needed in its own right rather than covered by the multicolour twin:
        // `pack(hires:)` degrades just as gracefully as `pack(multicolor:)`, so
        // a dropped `enforceHires` is invisible to every other test in this
        // file — the per-cell invariant still holds, it is just measuring the
        // packer's damage control instead of the constraint pass.
        try assertPackedPictureReproducesTheConstrainedBuffer(mode: .hires)
    }

    /// Runs the pipeline's stages by hand and asserts the finished picture
    /// decodes back to exactly the buffer the constraint pass produced.
    ///
    /// Packing degrades gracefully when a cell holds more colours than the
    /// hardware can show, which means a missing `enforce` call would not crash —
    /// it would quietly lose colours, and every invariant test would still pass
    /// because the packer cleaned up after it. This is the test that catches
    /// that: what comes back out of the packed bytes must equal what went in.
    private func assertPackedPictureReproducesTheConstrainedBuffer(
        mode: BitmapMode, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let source = makeSource()
        var settings = ConversionSettings()
        settings.mode = mode
        let width = mode == .hires ? 320 : 160

        let loaded = try ImageLoading.loadCGImage(from: source)
        let crop = CropGeometry.defaultCrop(
            sourceWidth: loaded.width, sourceHeight: loaded.height)
        let prepared = ImageLoading.prepare(
            loaded, cropRect: crop, targetWidth: width, targetHeight: 200,
            brightness: settings.brightness, contrast: settings.contrast,
            saturation: settings.saturation)
        var expected = Quantizer.quantize(
            prepared, palette: settings.palette, dither: settings.dither)
        switch mode {
        case .hires: CellConstraints.enforceHires(&expected, palette: settings.palette)
        case .multicolor: CellConstraints.enforceMulticolor(&expected, palette: settings.palette)
        }

        let result = try ConversionOperation.run(request(source, mode: mode))
        let actual = try indices(of: result.image, palette: settings.palette)

        // Compared pixel by pixel rather than with one `XCTAssertEqual` on the
        // buffers: a whole-buffer comparison prints 32 000 indices twice, which
        // buries the answer to the only question worth asking — where, and how
        // many.
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        var mismatches = 0
        var firstMismatch: String?
        for y in 0..<expected.height {
            for x in 0..<expected.width where actual[x, y] != expected[x, y] {
                mismatches += 1
                if firstMismatch == nil {
                    firstMismatch = "(\(x),\(y)): packed \(actual[x, y]), expected "
                        + "\(expected[x, y])"
                }
            }
        }
        XCTAssertEqual(
            mismatches, 0,
            "\(mode): packing changed \(mismatches) pixels; first at \(firstMismatch ?? "-")",
            file: file, line: line)
    }

    // MARK: - The shared path

    func testConvertMatchesRunForTheSameImageAndCrop() throws {
        // The cardinal rule of the project, as a test: the app's in-memory
        // entry point and the CLI's file-based one are the same pipeline. If
        // someone re-implements a stage in one of them, this fails.
        let source = makeSource()
        let loaded = try ImageLoading.loadCGImage(from: source)
        let crop = CropGeometry.defaultCrop(
            sourceWidth: loaded.width, sourceHeight: loaded.height)

        for mode in [BitmapMode.hires, .multicolor] {
            var settings = ConversionSettings()
            settings.mode = mode
            let viaRun = try ConversionOperation.run(request(source, mode: mode))
            let viaConvert = ConversionOperation.convert(
                loaded, cropRect: crop, settings: settings)
            XCTAssertEqual(viaRun.image, viaConvert, "\(mode)")
        }
    }

    // MARK: - Crop selection and in-memory use

    func testNoOutputURLsWritesNothingButStillConverts() throws {
        let source = makeSource()
        let result = try ConversionOperation.run(request(source, mode: .multicolor))
        XCTAssertEqual(result.writtenFiles, [])
        XCTAssertEqual(result.image.bitmap.count, 8000)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.png"],
            "an in-memory conversion must not touch the file system")
    }

    func testCropUsedIsTheDefaultWhenNoneIsGiven() throws {
        // A 3:2 source, so the default crop is not the whole image and a stage
        // that silently ignored the crop would be visible.
        let source = makeSource(name: "wide.png", width: 900, height: 600)
        let result = try ConversionOperation.run(request(source, mode: .multicolor))
        XCTAssertEqual(
            result.cropUsed,
            CropGeometry.defaultCrop(sourceWidth: 900, sourceHeight: 600))
        // 900·5 = 4500 is not > 600·8 = 4800, so the width survives whole and
        // the height is ⌊4500/8⌋ = 562, centred at y = ⌊(600 − 562)/2⌋ = 19.
        XCTAssertEqual(result.cropUsed, CGRect(x: 0, y: 19, width: 900, height: 562))
    }

    func testAnExplicitCropIsHonouredAndReported() throws {
        // The right-hand half of the ramp only: the result must be
        // measurably different from the default crop's.
        let source = makeSource(name: "wide.png", width: 900, height: 600)
        let crop = CGRect(x: 450, y: 0, width: 450, height: 281)
        var request = self.request(source, mode: .multicolor)
        request.cropRect = crop

        let result = try ConversionOperation.run(request)
        XCTAssertEqual(result.cropUsed, crop)

        let whole = try ConversionOperation.run(self.request(source, mode: .multicolor))
        XCTAssertNotEqual(result.image, whole.image, "the crop must change the picture")
    }

    func testCropUsedReportsTheClippedRectangleNotTheRequestedOne() throws {
        // `prepare` clips a crop to the image, so a rectangle hanging off the
        // right edge samples fewer columns than it names. `cropUsed` is what
        // the front ends echo back — the CLI prints it, the app draws it — so
        // it has to be the rectangle that was *sampled*, not the one that was
        // asked for, or both front ends lie about the same conversion.
        let source = makeSource(name: "wide.png", width: 900, height: 600)
        var request = self.request(source, mode: .multicolor)
        request.cropRect = CGRect(x: 800, y: 0, width: 400, height: 250)

        let result = try ConversionOperation.run(request)
        XCTAssertEqual(result.cropUsed, CGRect(x: 800, y: 0, width: 100, height: 250))
    }

    func testCropUsedReportsTheWholeImageWhenTheCropMissesEntirely() throws {
        // `prepare`'s documented fallback: a rectangle that intersects nothing
        // converts the whole image rather than failing, because a degenerate
        // rectangle mid-drag must not take the app down. `cropUsed` must say so.
        let source = makeSource(name: "wide.png", width: 900, height: 600)
        var request = self.request(source, mode: .multicolor)
        request.cropRect = CGRect(x: 2000, y: 2000, width: 100, height: 100)

        let result = try ConversionOperation.run(request)
        XCTAssertEqual(result.cropUsed, CGRect(x: 0, y: 0, width: 900, height: 600))

        // And the picture really is the whole image, not merely reported as it.
        var wholeRequest = self.request(source, mode: .multicolor)
        wholeRequest.cropRect = CGRect(x: 0, y: 0, width: 900, height: 600)
        XCTAssertEqual(result.image, try ConversionOperation.run(wholeRequest).image)
    }

    func testCropUsedAlwaysNamesTheRectangleThatWasSampled() throws {
        // The general form of the two tests above: converting with `cropUsed`
        // must give the same picture as the conversion that produced it, for
        // any rectangle at all. If the clipping rule here and the one inside
        // `prepare` ever diverge, this fails whatever shape the divergence has.
        let source = makeSource(name: "wide.png", width: 900, height: 600)
        let rectangles = [
            CGRect(x: 0, y: 19, width: 900, height: 562),
            CGRect(x: 800, y: 0, width: 400, height: 250),
            CGRect(x: -100, y: -50, width: 400, height: 250),
            CGRect(x: 2000, y: 2000, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: 0, height: 0),
        ]

        for rectangle in rectangles {
            var request = self.request(source, mode: .multicolor)
            request.cropRect = rectangle
            let result = try ConversionOperation.run(request)

            var replay = self.request(source, mode: .multicolor)
            replay.cropRect = result.cropUsed
            XCTAssertEqual(
                try ConversionOperation.run(replay).image, result.image, "\(rectangle)")
        }
    }

    // MARK: - Failure at the edges

    func testAMissingInputThrowsUnreadable() {
        XCTAssertThrowsError(
            try ConversionOperation.run(request(url("nope.png"), mode: .multicolor))
        ) { XCTAssertEqual($0 as? ImageLoadingError, .unreadable(self.url("nope.png"))) }
    }

    func testAnUnwritableC64DestinationThrowsUnwritable() throws {
        let source = makeSource()
        let target = url("no-such-directory/picture.koa")
        XCTAssertThrowsError(
            try ConversionOperation.run(request(source, mode: .multicolor, c64: target))
        ) { XCTAssertEqual($0 as? ImageLoadingError, .unwritable(target)) }
    }

    func testAnUnwritablePNGDestinationThrowsUnwritable() throws {
        let source = makeSource()
        let target = url("no-such-directory/picture.png")
        XCTAssertThrowsError(
            try ConversionOperation.run(request(source, mode: .multicolor, png: target))
        ) { XCTAssertEqual($0 as? ImageLoadingError, .unwritable(target)) }
    }
}
