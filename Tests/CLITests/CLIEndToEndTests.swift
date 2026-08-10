import C64Kit
import Foundation
import TestSupport
import XCTest

/// End-to-end tests for the `image64` executable.
///
/// These spawn the real binary rather than calling into its types, because the
/// things worth pinning about a CLI are precisely the things a direct call
/// cannot see: the exit code, which stream a message went to, and whether
/// `--json` put exactly one object on standard output and nothing else.
///
/// The lockstep test is the reason this suite links `C64Kit` as well: the CLI's
/// job is to assemble a `ConversionRequest` and get out of the way, and the only
/// convincing proof of that is byte-for-byte agreement with the same request
/// made in-process.
final class CLIEndToEndTests: XCTestCase {

    // MARK: - Scratch directory

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("image64-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// The standard input: the same 640×400 blue-to-yellow ramp the engine's own
    /// end-to-end tests convert, so the lockstep comparison below is between two
    /// runs over identical pixels.
    @discardableResult
    private func makeSource(name: String = "source.png") -> URL {
        let source = url(name)
        TestImageFactory.makePNG(
            width: 640, height: 400,
            horizontalGradient: RGB(r: 0, g: 32, b: 200), to: RGB(r: 255, g: 220, b: 40),
            at: source)
        return source
    }

    // MARK: - Running the binary

    /// The directory `swift build` put the products in — the standard way to
    /// find an executable from inside its own package's test bundle, since the
    /// test bundle is written alongside it.
    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        preconditionFailure("could not locate the build products directory")
    }

    private struct Run {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    private func runCLI(_ arguments: [String]) throws -> Run {
        let process = Process()
        process.executableURL = productsDirectory.appendingPathComponent("image64")
        process.arguments = arguments

        let out = Pipe()
        let error = Pipe()
        process.standardOutput = out
        process.standardError = error

        try process.run()
        // Read before waiting: both streams here are well under a pipe buffer,
        // but reading first is what keeps that from being a thing to remember.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Run(
            status: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self))
    }

    private func byteCount(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - The report, as the wire sees it
    //
    // Declared here rather than imported from the CLI so the test pins the JSON
    // *shape* an external consumer depends on. Renaming a field in the CLI's own
    // type would then fail this test, which is the point: the keys are the
    // contract.

    private struct CropBox: Codable, Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    private struct ConversionReport: Codable {
        let input: String
        let outputs: [String]
        let mode: String
        let palette: String
        let dither: String
        let background: Int?
        let crop: CropBox
    }

    // MARK: - (a) and (b): the two native formats

    func testConvertWritesAKoalaFileOfThePinnedSize() throws {
        let source = makeSource()
        let output = url("out.koa")

        let run = try runCLI(["convert", source.path, "-o", output.path])

        XCTAssertEqual(run.status, 0, run.standardError)
        XCTAssertEqual(try byteCount(of: output), 10003)
    }

    func testConvertWritesAnArtStudioFileOfThePinnedSize() throws {
        let source = makeSource()
        let output = url("out.art")

        let run = try runCLI(["convert", source.path, "-o", output.path])

        XCTAssertEqual(run.status, 0, run.standardError)
        XCTAssertEqual(try byteCount(of: output), 9009)
    }

    // MARK: - (c) lockstep

    /// The cardinal rule, as a byte comparison: a CLI run and a direct
    /// `ConversionOperation.run` with the same parameters must produce the same
    /// file. Defaults on both sides — no flags, no explicit crop — because that
    /// is the path every other test here takes.
    func testTheCLIFileIsIdenticalToADirectConversion() throws {
        let source = makeSource()
        let viaCLI = url("cli.koa")
        let direct = url("direct.koa")

        let run = try runCLI(["convert", source.path, "-o", viaCLI.path])
        XCTAssertEqual(run.status, 0, run.standardError)

        var request = ConversionRequest(inputURL: source, settings: ConversionSettings())
        request.c64OutputURL = direct
        _ = try ConversionOperation.run(request)

        XCTAssertTrue(
            FileManager.default.contentsEqual(atPath: viaCLI.path, andPath: direct.path),
            "the CLI and a direct conversion disagree byte-for-byte")
    }

    // MARK: - (d) --json

    func testJSONReportDescribesTheConversion() throws {
        let source = makeSource()
        let output = url("out.koa")

        let run = try runCLI(["convert", source.path, "-o", output.path, "--json"])
        XCTAssertEqual(run.status, 0, run.standardError)

        let data = Data(run.standardOutput.utf8)
        let report = try JSONDecoder().decode(ConversionReport.self, from: data)

        XCTAssertEqual(report.mode, "multicolor")
        XCTAssertEqual(report.palette, "colodore")
        XCTAssertEqual(report.dither, "fs")
        XCTAssertNotNil(report.background)
        XCTAssertEqual(report.outputs.count, 1)
        XCTAssertEqual(report.outputs.first, output.path)
        XCTAssertEqual(report.input, source.path)
        // The default crop of a 640×400 source is the whole of it: already 8:5.
        XCTAssertEqual(report.crop, CropBox(x: 0, y: 0, width: 640, height: 400))
    }

    /// `--json` promises *exactly one* object on standard output, so a caller can
    /// pipe the stream straight into a parser. Decoding above proves it parses;
    /// this proves nothing was printed alongside it.
    func testJSONModePrintsNothingButTheObject() throws {
        let source = makeSource()
        let output = url("out.koa")

        let run = try runCLI(["convert", source.path, "-o", output.path, "--json"])

        let trimmed = run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.hasPrefix("{"), "stdout did not begin with the object: \(trimmed)")
        XCTAssertTrue(trimmed.hasSuffix("}"), "stdout did not end with the object: \(trimmed)")
        XCTAssertEqual(
            trimmed.filter { $0 == "\n" }.count, 0, "the object was not printed on one line")
    }

    // MARK: - (e), (f), (g): the three ways to be wrong

    func testACropSmallerThanACellIsRejected() throws {
        let source = makeSource()

        let run = try runCLI(["convert", source.path, "-o", url("out.koa").path, "--crop", "0,0,4,4"])

        XCTAssertEqual(run.status, 1)
        XCTAssertTrue(
            run.standardError.contains("width"),
            "the message should name the offending dimension: \(run.standardError)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url("out.koa").path),
            "a rejected crop must not leave a file behind")
    }

    func testAnUnknownOutputExtensionIsRejected() throws {
        let source = makeSource()

        let run = try runCLI(["convert", source.path, "-o", url("out.txt").path])

        XCTAssertEqual(run.status, 1)
        XCTAssertTrue(
            run.standardError.contains("txt"),
            "the message should name the extension: \(run.standardError)")
    }

    func testAModeThatContradictsTheOutputFormatIsRejected() throws {
        let source = makeSource()

        let run = try runCLI([
            "convert", source.path, "-o", url("out.koa").path, "--mode", "hires",
        ])

        XCTAssertEqual(run.status, 1)
        XCTAssertFalse(run.standardError.isEmpty, "the failure should say something")
    }

    // MARK: - (h) overwriting

    /// Batch loops re-run the same command over the same output; prompting or
    /// refusing would break them, and appending would corrupt the file. Twice
    /// through, the file is still exactly one Koala picture.
    func testConvertingTwiceOverwritesWithoutComplaint() throws {
        let source = makeSource()
        let output = url("out.koa")

        let first = try runCLI(["convert", source.path, "-o", output.path])
        XCTAssertEqual(first.status, 0, first.standardError)

        let second = try runCLI(["convert", source.path, "-o", output.path])
        XCTAssertEqual(second.status, 0, second.standardError)

        XCTAssertEqual(try byteCount(of: output), 10003)
    }

    // MARK: - The rest of the surface

    func testPNGExportWritesASecondFile() throws {
        let source = makeSource()
        let c64 = url("out.koa")
        let png = url("out.png")

        let run = try runCLI([
            "convert", source.path, "-o", c64.path, "--png", png.path, "--json",
        ])
        XCTAssertEqual(run.status, 0, run.standardError)

        let report = try JSONDecoder().decode(
            ConversionReport.self, from: Data(run.standardOutput.utf8))
        XCTAssertEqual(report.outputs, [c64.path, png.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path))
    }

    /// `--crop` ignores the height it is given and derives the 8:5 one, so the
    /// report echoes 250 rather than the 999 asked for.
    func testCropSnapsTheHeightAndIsReportedBack() throws {
        let source = makeSource()

        let run = try runCLI([
            "convert", source.path, "-o", url("out.koa").path, "--crop", "8,16,400,999", "--json",
        ])
        XCTAssertEqual(run.status, 0, run.standardError)

        let report = try JSONDecoder().decode(
            ConversionReport.self, from: Data(run.standardOutput.utf8))
        XCTAssertEqual(report.crop, CropBox(x: 8, y: 16, width: 400, height: 250))
    }

    func testSettingsFlagsReachTheEngine() throws {
        let source = makeSource()
        let output = url("out.art")

        let run = try runCLI([
            "convert", source.path, "-o", output.path, "--dither", "bayer",
            "--palette", "pepto", "--brightness", "0.25", "--contrast", "-0.1",
            "--saturation", "0.5", "--json",
        ])
        XCTAssertEqual(run.status, 0, run.standardError)

        let report = try JSONDecoder().decode(
            ConversionReport.self, from: Data(run.standardOutput.utf8))
        XCTAssertEqual(report.mode, "hires")
        XCTAssertEqual(report.dither, "bayer")
        XCTAssertEqual(report.palette, "pepto")
        // Hires has no shared background to report.
        XCTAssertNil(report.background)

        var settings = ConversionSettings()
        settings.mode = .hires
        settings.dither = .bayer
        settings.palette = .pepto
        settings.brightness = 0.25
        settings.contrast = -0.1
        settings.saturation = 0.5
        var request = ConversionRequest(inputURL: source, settings: settings)
        request.c64OutputURL = url("direct.art")
        _ = try ConversionOperation.run(request)

        XCTAssertTrue(
            FileManager.default.contentsEqual(
                atPath: output.path, andPath: url("direct.art").path),
            "an adjusted conversion must also be identical through both front ends")
    }

    func testAnAdjustmentOutsideTheAllowedRangeIsRejected() throws {
        let source = makeSource()

        let run = try runCLI([
            "convert", source.path, "-o", url("out.koa").path, "--brightness", "2",
        ])

        XCTAssertEqual(run.status, 1)
        XCTAssertTrue(
            run.standardError.contains("brightness"),
            "the message should name the offending option: \(run.standardError)")
    }

    func testAnUnreadableInputIsRejected() throws {
        let run = try runCLI([
            "convert", url("missing.png").path, "-o", url("out.koa").path,
        ])

        XCTAssertEqual(run.status, 1)
        XCTAssertTrue(
            run.standardError.contains("missing.png"),
            "the message should name the file: \(run.standardError)")
    }

    // MARK: - The runnable program

    /// The first two bytes of `url`, which for a PRG are its load address.
    private func loadAddress(of url: URL) throws -> [UInt8] {
        Array(try Data(contentsOf: url).prefix(2))
    }

    func testPRGIsWrittenAlongsideTheC64FileAndListedInTheReport() throws {
        let source = makeSource()
        let c64 = url("out.koa")
        let prg = url("out.prg")

        let run = try runCLI([
            "convert", source.path, "-o", c64.path, "--prg", prg.path, "--json",
        ])
        XCTAssertEqual(run.status, 0, run.standardError)

        // $0801, low byte first: where a BASIC program loads, which is what
        // makes the file runnable rather than a memory dump.
        XCTAssertEqual(try loadAddress(of: prg), [0x01, 0x08])

        let report = try JSONDecoder().decode(
            ConversionReport.self, from: Data(run.standardOutput.utf8))
        XCTAssertEqual(report.outputs, [c64.path, prg.path])
    }

    /// A PRG is a program rather than a format, so it needs no `.koa` or `.art`
    /// beside it — and asking for one anyway would mean converting the picture
    /// twice into two files to get one.
    func testPRGCanBeTheOnlyOutput() throws {
        let source = makeSource()
        let prg = url("only.prg")

        let run = try runCLI(["convert", source.path, "--prg", prg.path, "--json"])
        XCTAssertEqual(run.status, 0, run.standardError)

        XCTAssertTrue(FileManager.default.fileExists(atPath: prg.path))
        XCTAssertEqual(try loadAddress(of: prg), [0x01, 0x08])

        let report = try JSONDecoder().decode(
            ConversionReport.self, from: Data(run.standardOutput.utf8))
        XCTAssertEqual(report.outputs, [prg.path])
        // No output extension to infer a mode from, so the default stands.
        XCTAssertEqual(report.mode, "multicolor")
        XCTAssertEqual(try byteCount(of: prg), 10157)
    }

    func testPRGOnlyStillHonoursAnExplicitMode() throws {
        let source = makeSource()
        let prg = url("hires.prg")

        let run = try runCLI([
            "convert", source.path, "--prg", prg.path, "--mode", "hires", "--json",
        ])
        XCTAssertEqual(run.status, 0, run.standardError)

        let report = try JSONDecoder().decode(
            ConversionReport.self, from: Data(run.standardOutput.utf8))
        XCTAssertEqual(report.mode, "hires")
        XCTAssertEqual(try byteCount(of: prg), 9123)
    }

    /// Neither output flag means the command would read an image, convert it,
    /// and drop the result — worth refusing rather than exiting 0 having done
    /// nothing.
    func testRefusingToRunWithNothingToWrite() throws {
        let source = makeSource()

        let run = try runCLI(["convert", source.path])

        XCTAssertEqual(run.status, 1)
        XCTAssertTrue(
            run.standardError.contains("--output"),
            "the message should name --output: \(run.standardError)")
        XCTAssertTrue(
            run.standardError.contains("--prg"),
            "the message should name --prg: \(run.standardError)")
    }

    /// The overwrite promise is part of the documented interface, not just the
    /// implementation, so the help text has to say it.
    func testHelpDocumentsTheOverwriteBehaviour() throws {
        let run = try runCLI(["convert", "--help"])

        XCTAssertEqual(run.status, 0, run.standardError)
        XCTAssertTrue(
            run.standardOutput.lowercased().contains("overwrit"),
            "convert --help should state that outputs are overwritten")
    }
}
