import C64Kit
import Foundation
import XCTest

/// Pins the one version string to everything that claims to report it.
///
/// The version used to live as two independent literals — `make-app.sh`'s
/// default and the App's About-panel fallback — kept in step by a comment
/// asking the next person to remember. `C64KitInfo.version` is now the only
/// copy, and these tests are what make that true rather than aspirational:
/// each consumer is checked against the constant, so a bump that misses one
/// fails here instead of shipping a binary that misreports itself.
///
/// The App's fallback is the one consumer *not* covered. The app target has no
/// test host, so nothing here can observe its About panel; it reads the same
/// constant by inspection only.
final class VersionTests: XCTestCase {

    // MARK: - Locating things on disk

    /// Same pattern as `SkillDocTests`: walk up from this file to the directory
    /// holding `Package.swift`. The scripts under test are read from the source
    /// tree because that is the copy a release actually runs.
    private func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw XCTSkip("could not find Package.swift walking up from \(#filePath)")
    }

    /// Same pattern as `CLIEndToEndTests`: the test bundle is written next to
    /// the built products.
    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        preconditionFailure("could not locate the build products directory")
    }

    // MARK: - Running things

    private struct Run {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    private func run(_ executable: URL, _ arguments: [String] = []) throws -> Run {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let out = Pipe()
        let error = Pipe()
        process.standardOutput = out
        process.standardError = error

        try process.run()
        // Read before waiting: a pipe buffer that fills would deadlock a
        // process blocked on writing to it.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Run(
            status: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self))
    }

    // MARK: - Tests

    /// `--version` has to exist at all. ArgumentParser only adds the flag when
    /// `CommandConfiguration.version` is non-empty, so an unset version does not
    /// print a blank line — it fails with "Unknown option", which is how this
    /// went unnoticed while a doc comment claimed the flag was handled.
    func testVersionFlagReportsTheSharedConstant() throws {
        let result = try run(productsDirectory.appendingPathComponent("image64"), ["--version"])

        XCTAssertEqual(result.status, 0, "stderr: \(result.standardError)")
        XCTAssertEqual(
            result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            C64KitInfo.version)
    }

    /// The version is not empty and looks like a release, so a bump cannot
    /// quietly leave it as a placeholder.
    func testVersionIsSemanticLooking() {
        XCTAssertFalse(C64KitInfo.version.isEmpty)
        let parts = C64KitInfo.version.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "expected MAJOR.MINOR.PATCH, got \(C64KitInfo.version)")
        for part in parts {
            XCTAssertNotNil(Int(part), "non-numeric component in \(C64KitInfo.version)")
        }
    }

    /// `scripts/version.sh` is what the shell side reads, and `make-app.sh`
    /// stamps its output into `CFBundleShortVersionString`. If its extraction
    /// stops matching the Swift declaration — a reformat, a rename, a moved
    /// file — it returns empty, and a bundle would claim the wrong version. The
    /// script is run for real rather than reimplemented here, because a copy of
    /// the expression would pass while the original was broken.
    func testVersionScriptExtractsTheSameString() throws {
        let script = try repoRoot().appendingPathComponent("scripts/version.sh")
        let result = try run(script)

        XCTAssertEqual(result.status, 0, "stderr: \(result.standardError)")
        XCTAssertEqual(
            result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            C64KitInfo.version)
    }

    /// `make-app.sh` must actually call the extractor rather than carry its own
    /// literal default, which is the arrangement this whole file exists to
    /// prevent regressing to.
    func testMakeAppScriptDerivesItsDefaultFromTheExtractor() throws {
        let script = try repoRoot().appendingPathComponent("scripts/make-app.sh")
        let source = try String(contentsOf: script, encoding: .utf8)

        XCTAssertTrue(
            source.contains("version.sh"),
            "make-app.sh no longer reads scripts/version.sh — it has a version literal again")
    }
}
