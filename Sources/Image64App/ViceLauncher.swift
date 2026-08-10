import AppKit
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
    /// Three routes, in the order a Mac user is most likely to have installed
    /// VICE: the official macOS app distribution first, then a shell-installed
    /// `x64sc` on `PATH`, then the two fixed Homebrew directories — which cover
    /// the app-bundle case, where the process inherits the launchd default
    /// `PATH` that omits them. Each route is guarded by an executable check and
    /// falls through to the next, so a distribution laid out differently than
    /// the one below degrades to the walk instead of failing outright.
    static func findX64sc() -> URL? {
        // The VICE macOS app distribution registers x64sc.app with
        // LaunchServices; prefer it over a shell install so the app works
        // without Homebrew (maintainer's machines carry only the app).
        // LaunchServices finds the bundle wherever the user dragged it,
        // whatever the enclosing folder is named — the official download
        // unpacks into a space-bearing folder, so no fixed path would do.
        //
        // What we want from the hit is the *enclosing directory*, not the
        // bundle: `x64sc.app/Contents/MacOS/x64sc` is not the emulator, it is a
        // Platypus wrapper whose script does `open VICE.app --args <prg>`, and
        // `open --args` silently drops its arguments when the target app is
        // already running. Going through it, a second Show in VICE spawns no
        // process and leaves VICE showing the *first* picture — observed on the
        // 3.9 app distribution. Every emulator app in that folder is such a
        // wrapper around one real binary in the sibling VICE.app, so we exec
        // that binary directly: arguments always arrive, and each invocation
        // gets its own emulator instance, exactly as the `PATH` route behaves.
        // It is self-contained — `@executable_path/../lib` for its dylibs,
        // `../share/vice` for its ROMs — so no wrapper environment is needed.
        if let stub = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "org.viceteam.x64sc") {
            let binary = stub
                .deletingLastPathComponent()
                .appendingPathComponent("VICE.app/Contents/Resources/bin/x64sc")
            if FileManager.default.isExecutableFile(atPath: binary.path) {
                return binary
            }
        }

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
                // Both install routes named, app first: the app is what most
                // Mac users have, and a Homebrew-only hint reads as "you need
                // Homebrew" to someone who does not have it.
                NSLocalizedDescriptionKey:
                    "VICE is not installed — download the VICE app from "
                    + "vice-emu.sourceforge.io or `brew install vice`."
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
