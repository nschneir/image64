import ArgumentParser
import C64Kit

// Placeholder front end. Task 9 replaces the body with subcommands over
// `ConversionOperation`; for now it exists so the target builds and links
// against both the engine and ArgumentParser.
@main
struct Image64Command: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image64",
        abstract: "Convert modern images to Commodore 64 bitmap-mode pictures."
    )

    func run() throws {
        print("image64: not implemented yet (\(C64KitInfo.name) scaffold).")
    }
}
