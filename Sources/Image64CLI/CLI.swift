import ArgumentParser
import Foundation

/// The `image64` root command.
///
/// It does nothing itself: every operation is a subcommand, so that the
/// executable's surface grows by adding a `ParsableCommand` rather than by
/// growing a flag set. `convert` is the only one in v1.
struct Image64Command: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image64",
        abstract: "Convert modern images to Commodore 64 bitmap-mode pictures.",
        subcommands: [ConvertCommand.self]
    )
}

/// The executable's entry point.
///
/// Hand-written rather than `@main` on `Image64Command` for one reason:
/// ArgumentParser's own `main` exits with `EX_USAGE` (64) for anything it
/// classifies as a usage error, and this tool documents a single failure code.
/// Scripts branch on "did it work", not on which of several ways it didn't, and
/// a `convert` that exits 64 for a bad `--crop` but 1 for an unwritable
/// directory makes that branch wrong in a way nobody notices until a batch run
/// half-succeeds.
///
/// Everything else is ArgumentParser's: the message text, the usage block, and
/// the clean-exit path that `--help` and `--version` take.
@main
enum Image64Main {

    static func main() {
        do {
            var command = try Image64Command.parseAsRoot()
            try command.run()
        } catch {
            exit(reporting: error)
        }
    }

    private static func exit(reporting error: Error) -> Never {
        // `--help` and the other clean exits are not failures: ArgumentParser
        // prints them on standard output and exits 0, and there is nothing here
        // to improve on.
        guard Image64Command.exitCode(for: error) != .success else {
            Image64Command.exit(withError: error)
        }

        let message = Image64Command.fullMessage(for: error)
        if !message.isEmpty {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
        // `ExitCode` carries no message of its own, so this exits 1 having
        // printed exactly what was written above.
        Image64Command.exit(withError: ExitCode.failure)
    }
}
