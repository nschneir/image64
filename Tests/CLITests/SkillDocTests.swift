import Foundation
import XCTest

/// Bidirectional doc-accuracy tests for `skills/c64-image-conversion/SKILL.md`.
///
/// The skill file is the instructions an agent reads before invoking the CLI, so
/// silently drifting from the binary is worse than being wrong: the agent will
/// confidently reach for a flag that no longer exists, or miss one that does.
/// These tests read the same file the agent will read, extract every
/// `--long-option` from both the doc and `image64 convert --help`, and demand
/// the two sets match. A separate test decodes the JSON example in the doc into
/// the same shape the CLI actually emits, so the example cannot rot away from
/// the report format.
final class SkillDocTests: XCTestCase {

    // MARK: - Locating things on disk

    /// Walk up from this test source file until a directory with `Package.swift`
    /// turns up — that is the repo root, and the skill file lives underneath it.
    /// Reading the file straight from the source tree (rather than copying it in
    /// as a bundle resource) is the whole point: the test has to see exactly
    /// what an agent following the skill would see.
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

    private func skillURL() throws -> URL {
        try repoRoot().appendingPathComponent("skills/c64-image-conversion/SKILL.md")
    }

    /// Same pattern as `CLIEndToEndTests`: the test bundle is written next to
    /// the built products, so its own directory is the one to look in.
    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        preconditionFailure("could not locate the build products directory")
    }

    // MARK: - Running --help

    private func convertHelpOutput() throws -> String {
        let process = Process()
        process.executableURL = productsDirectory.appendingPathComponent("image64")
        process.arguments = ["convert", "--help"]

        let out = Pipe()
        let error = Pipe()
        process.standardOutput = out
        process.standardError = error

        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        _ = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: outData, as: UTF8.self)
    }

    // MARK: - Option extraction

    /// The regex finds any `--foo` or `--foo-bar` token. `--help` and
    /// `--version` are filtered out: both are ArgumentParser's own, neither is
    /// part of the conversion surface this skill documents, and `--version`
    /// only appears in `convert --help` at all because setting it on the root
    /// command propagates it to every subcommand. Filtering happens on both
    /// sides, so the skill may still mention them — it just is not required to,
    /// and cannot be accused of inventing them.
    private func longOptions(in text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: "--[a-z][a-z0-9-]*")
        let range = NSRange(text.startIndex..., in: text)
        var found: Set<String> = []
        pattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            let token = String(text[range])
            if token != "--help" && token != "--version" {
                found.insert(token)
            }
        }
        return found
    }

    /// Strip ```text fenced blocks from a Markdown string. The skill quotes a
    /// neighboring `c64` CLI in a ```text example, and those `--foo` tokens are
    /// not `image64` options — mixing them into the comparison would produce
    /// false failures on both sides. Other fences (```sh, ```swift, ```json,
    /// plain ```) are still scanned, because those *are* image64 examples.
    private func strippingTextFences(_ markdown: String) -> String {
        var result = ""
        var insideText = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if insideText {
                if trimmed.hasPrefix("```") {
                    insideText = false
                }
                continue
            }
            if trimmed.hasPrefix("```text") {
                insideText = true
                continue
            }
            result.append(contentsOf: line)
            result.append("\n")
        }
        return result
    }

    // MARK: - The two tests

    func testSkillDocumentsEveryConvertOption() throws {
        let help = try convertHelpOutput()
        let skill = try String(contentsOf: skillURL(), encoding: .utf8)

        let helpOptions = longOptions(in: help)
        let skillOptions = longOptions(in: strippingTextFences(skill))

        let undocumented = helpOptions.subtracting(skillOptions).sorted()
        XCTAssertTrue(
            undocumented.isEmpty,
            "these options are in `image64 convert --help` but missing from SKILL.md: \(undocumented)")

        let invented = skillOptions.subtracting(helpOptions).sorted()
        XCTAssertTrue(
            invented.isEmpty,
            "SKILL.md mentions these options that `image64 convert --help` does not know about: \(invented)")
    }

    // MARK: - JSON example

    /// Mirrors the CLI's report shape. Kept local so a rename in the CLI would
    /// still be caught here — the point of the test is that the skill's example
    /// decodes into the same fields an external consumer would rely on.
    private struct CropBox: Codable {
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

    /// Find the JSON block in the skill file — either a ```json fenced block or
    /// the first fenced block that names both `"input"` and `"outputs"`.
    private func extractJSONBlock(from markdown: String) -> String? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var current: [String] = []
        var inBlock = false
        var fenceInfo = ""
        var candidates: [(String, String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlock {
                if trimmed.hasPrefix("```") {
                    candidates.append((fenceInfo, current.joined(separator: "\n")))
                    current.removeAll()
                    inBlock = false
                } else {
                    current.append(line)
                }
            } else if trimmed.hasPrefix("```") {
                fenceInfo = String(trimmed.dropFirst(3))
                inBlock = true
            }
        }
        if let json = candidates.first(where: { $0.0.lowercased().hasPrefix("json") }) {
            return json.1
        }
        return candidates.first(where: { $0.1.contains("\"input\"") && $0.1.contains("\"outputs\"") })?.1
    }

    func testSkillJSONShapeMatchesReport() throws {
        let skill = try String(contentsOf: skillURL(), encoding: .utf8)
        guard let block = extractJSONBlock(from: skill) else {
            XCTFail("SKILL.md contains no JSON example describing a conversion report")
            return
        }
        _ = try JSONDecoder().decode(ConversionReport.self, from: Data(block.utf8))
    }
}
