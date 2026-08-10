import C64Kit
import Foundation

/// Launches the VICE emulator (`x64sc`) showing a converted picture.
///
/// The picture travels as the same self-displaying `.prg` the export menu
/// writes — `C64PrgWriter` output handed to `x64sc`, whose autostart loads and
/// runs it exactly as a real C64 would. No VICE-specific format is involved,
/// so what the emulator shows is precisely what the exported program does.
enum ViceLauncher {

    /// Where `x64sc` lives, or `nil` if VICE is not installed.
    ///
    /// The `PATH` walk covers a shell-installed VICE; the two fixed entries
    /// cover the app-bundle case, where the process inherits the launchd
    /// default `PATH` that omits Homebrew's directories.
    static func findX64sc() -> URL? {
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) }
        candidates.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])

        for directory in candidates {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("x64sc")
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Writes `image` as a temporary `.prg` and opens it in VICE.
    ///
    /// The launch is fire-and-forget: VICE owns its own window and lifetime,
    /// and holding the `Process` would only tie the emulator's fate to the
    /// app's. The temp file must outlive this call — VICE reads it during
    /// autostart — so it is left for the system temp cleaner rather than
    /// deleted here.
    static func show(_ image: C64Image, title: String) throws {
        guard let x64sc = findX64sc() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey:
                    "VICE is not installed — `brew install vice` provides x64sc."
            ])
        }

        let prg = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(title)-\(UUID().uuidString).prg")
        try C64PrgWriter.data(for: image).write(to: prg)

        let process = Process()
        process.executableURL = x64sc
        process.arguments = [prg.path]
        try process.run()
    }
}
