import CoreGraphics
import Foundation
import TestSupport
import XCTest

@testable import C64Kit

/// Byte-exact golden tests: today's pipeline output must equal the `.koa` and
/// `.art` files committed under `Tests/C64KitTests/Fixtures/`. These are the
/// pipeline's final compatibility contract — the on-disk bytes a real C64 (or
/// VICE) will load — so a diff here is either an unintended regression or a
/// deliberate output change that also needs the goldens regenerated in the same
/// commit.
///
/// ## Regenerating
///
/// When a pipeline change is *intended* to alter output, delete the affected
/// golden file(s) and re-run:
///
///     IMAGE64_WRITE_GOLDEN=1 swift test --filter GoldenTests
///
/// The env var permits writing new candidates to the source tree; without it a
/// missing golden is a plain test failure with instructions. After
/// regeneration, inspect the new files (open the `.koa`/`.art` on real hardware
/// or in VICE; a PNG side-render helps when VICE is unavailable) before
/// committing them. Say so in the commit message per the AGENTS.md golden
/// policy.
///
/// ## Inspecting without VICE
///
/// Set `IMAGE64_WRITE_PNG=<dir>` (any run — with or without
/// `IMAGE64_WRITE_GOLDEN`) and the tests also write a 640×400 nearest-neighbour
/// PNG side-render of each golden to that directory. Same bytes the app's
/// preview would draw, so eyeballing the PNG is the same as eyeballing the
/// `.koa`/`.art`. Handy for a maintainer without a VICE checkout on hand.
final class GoldenTests: XCTestCase {

    // MARK: - Where the fixtures live on disk

    /// Path to the source-tree `Fixtures/` directory — the one whose files get
    /// committed. `Bundle.module.url(forResource:)` returns the copy inside the
    /// built test bundle instead, which is read-only and thrown away between
    /// runs. Walking up from `#filePath` is the only way to reach the source
    /// tree from inside a test.
    private static let fixturesSourceDirectory: URL = {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }()

    // MARK: - The two goldens

    func testMulticolorKoalaGolden() throws {
        try runGolden(name: "golden-multicolor", ext: "koa", mode: .multicolor)
    }

    func testHiresArtStudioGolden() throws {
        try runGolden(name: "golden-hires", ext: "art", mode: .hires)
    }

    // MARK: - Machinery

    /// Deterministic input for both modes: the same 640×400 gradient the CLI's
    /// end-to-end tests use, so a golden regression is comparable against every
    /// other test that touches the same pixels.
    private func makeSource(named base: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base)-\(UUID().uuidString).png")
        TestImageFactory.makePNG(
            width: 640, height: 400,
            horizontalGradient: RGB(r: 0, g: 32, b: 200), to: RGB(r: 255, g: 220, b: 40),
            at: url)
        return url
    }

    /// Convert with default settings + the requested mode; either compare
    /// bit-for-bit against the committed golden, or (with
    /// `IMAGE64_WRITE_GOLDEN=1`) write today's output to the source tree as a
    /// candidate and fail with a message explaining what to do next.
    private func runGolden(name: String, ext: String, mode: BitmapMode) throws {
        let source = makeSource(named: name)
        defer { try? FileManager.default.removeItem(at: source) }

        var settings = ConversionSettings()
        settings.mode = mode
        var request = ConversionRequest(inputURL: source, settings: settings)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).\(ext)")
        request.c64OutputURL = output

        // Side-render a PNG whenever the inspection env var points at a real
        // directory. Cheap when unset (empty string → the request just doesn't
        // ask for a PNG), and the resulting file is the exact 640×400 preview
        // the app would draw from these same bytes.
        let pngDirectory = ProcessInfo.processInfo.environment["IMAGE64_WRITE_PNG"] ?? ""
        var pngURL: URL?
        if !pngDirectory.isEmpty {
            let dir = URL(fileURLWithPath: pngDirectory)
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(name).png")
            pngURL = url
            request.pngOutputURL = url
        }

        _ = try ConversionOperation.run(request)
        defer { try? FileManager.default.removeItem(at: output) }
        if let pngURL {
            print("golden PNG side-render → \(pngURL.path)")
        }

        let produced = try Data(contentsOf: output)
        let goldenPath = Self.fixturesSourceDirectory.appendingPathComponent("\(name).\(ext)")

        if !FileManager.default.fileExists(atPath: goldenPath.path) {
            guard ProcessInfo.processInfo.environment["IMAGE64_WRITE_GOLDEN"] == "1" else {
                XCTFail(
                    "golden fixture missing: \(goldenPath.path)\n"
                        + "Re-run with IMAGE64_WRITE_GOLDEN=1 to write the current pipeline "
                        + "output as a candidate; inspect it (VICE, or the PNG side-render), "
                        + "then commit."
                )
                return
            }
            try FileManager.default.createDirectory(
                at: Self.fixturesSourceDirectory, withIntermediateDirectories: true)
            try produced.write(to: goldenPath)
            XCTFail(
                "wrote golden candidate: \(goldenPath.path)\n"
                    + "Inspect the file (VICE or PNG), then re-run *without* IMAGE64_WRITE_GOLDEN "
                    + "to lock the pipeline against these bytes."
            )
            return
        }

        let golden = try Data(contentsOf: goldenPath)
        XCTAssertEqual(
            produced, golden,
            "pipeline output differs from committed golden \(name).\(ext) — "
                + "either fix the regression, or, if the change was intended, delete the golden "
                + "and re-run with IMAGE64_WRITE_GOLDEN=1 to regenerate it."
        )
    }
}
