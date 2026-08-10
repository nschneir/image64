import ArgumentParser
import C64Kit
import CoreGraphics
import Foundation

// MARK: - Enum options
//
// The engine's knobs are already `String`-raw-valued enums, so the flags parse
// straight into them and there is no second spelling of "multicolor" to keep in
// step. `allValueStrings` is what puts the choices on the help screen;
// `C64Palette` is `CaseIterable` and gets it for free, while the other two spell
// their cases out because the engine does not conform them.

extension BitmapMode: ExpressibleByArgument {
    public static var allValueStrings: [String] { ["hires", "multicolor"] }
}

extension DitherMode: ExpressibleByArgument {
    public static var allValueStrings: [String] { ["none", "bayer", "fs"] }
}

extension C64Palette: ExpressibleByArgument {}

// MARK: - The report

/// A crop rectangle as the report prints it: whole source pixels, y = 0 at the
/// top, the same convention `--crop` accepts. Integers rather than the
/// `CGRect`'s doubles because every rectangle the engine returns is integral by
/// construction, and `"x": 8` is what a script wants to read.
struct CropBox: Codable, Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ rect: CGRect) {
        x = Int(rect.origin.x)
        y = Int(rect.origin.y)
        width = Int(rect.width)
        height = Int(rect.height)
    }
}

/// What `--json` prints: one object describing the conversion that just
/// happened.
///
/// Deliberately the *outcome* rather than an echo of the arguments — `crop` is
/// the rectangle that was sampled, not the one that was typed, and `mode` is the
/// mode that was used, not the flag. A caller reading this back gets parameters
/// that reproduce the file it is holding.
struct ConversionReport: Codable {
    let input: String
    let outputs: [String]
    let mode: String
    let palette: String
    let dither: String

    /// The shared background colour index, `$d021`. Multicolour only: hires has
    /// no image-wide colour, so the key is absent from a hires report rather
    /// than present and meaningless.
    let background: Int?

    let crop: CropBox
}

// MARK: - The command

struct ConvertCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert an image to a C64 bitmap-mode picture.",
        discussion: """
            The output extension picks the format: '.koa' is Koala Painter, \
            which is multicolour by definition, and '.art' is Advanced Art \
            Studio, which is hires. --mode is only needed to override what that \
            implies; a mode the format cannot encode is an error rather than a \
            quietly different file.

            Existing output files are overwritten without prompting, so a batch \
            loop can re-run over the same paths.
            """
    )

    @Argument(help: ArgumentHelp("The image to convert.", valueName: "input"))
    var input: String

    @Option(
        name: .shortAndLong,
        help: ArgumentHelp(
            "Where to write the C64 picture.", valueName: "out.koa|out.art"))
    var output: String?

    @Option(help: ArgumentHelp("Also write a 640×400 PNG of the result.", valueName: "out.png"))
    var png: String?

    @Option(
        help: ArgumentHelp(
            "Also write a runnable C64 program (.prg) that displays the picture when loaded.",
            valueName: "out.prg"))
    var prg: String?

    @Option(help: "Bitmap mode. Defaults to the one the output extension implies.")
    var mode: BitmapMode?

    @Option(
        help: ArgumentHelp(
            """
            Crop rectangle in source pixels, y = 0 at the top. The height is \
            ignored and recomputed as round(w × 5 / 8), because a C64 picture is \
            always an 8:5 frame. Defaults to the largest centred 8:5 rectangle.
            """,
            valueName: "x,y,w,h"))
    var crop: String?

    @Option(help: "How quantization error is spread before the palette snap.")
    var dither: DitherMode = .fs

    @Option(help: "Which sixteen-colour table to snap to.")
    var palette: C64Palette = .colodore

    // `.unconditional` on all three: half of each range is negative, and the
    // default strategy refuses to read `-0.1` as a value because it begins with
    // a dash. The cost is that `--contrast --json` consumes the flag as a value
    // and then fails to parse it as a number, which is a clear enough error for
    // an argument that always takes one.
    @Option(
        parsing: .unconditional,
        help: ArgumentHelp("Brightness adjustment, −1…1.", valueName: "n"))
    var brightness: Double = 0

    @Option(
        parsing: .unconditional,
        help: ArgumentHelp("Contrast adjustment, −1…1.", valueName: "n"))
    var contrast: Double = 0

    @Option(
        parsing: .unconditional,
        help: ArgumentHelp("Saturation adjustment, −1…1.", valueName: "n"))
    var saturation: Double = 0

    @Flag(help: "Print one JSON object describing the conversion instead of a summary.")
    var json = false

    // MARK: - Validation

    /// The checks that need nothing but the arguments themselves, so they can
    /// fail before an image is read. Everything the *engine* validates — the
    /// crop against the source, the extension, the mode against the format — is
    /// left to the engine, which is the only place that knows.
    func validate() throws {
        // `--png` is deliberately not enough on its own: it is a *preview* of a
        // conversion, and a run that produced only one would have converted the
        // image for the C64 and then thrown the C64 away.
        guard output != nil || prg != nil else {
            throw ValidationError(
                "give --output, --prg, or both — there is nothing to write otherwise")
        }
        try validateAdjustment(brightness, named: "brightness")
        try validateAdjustment(contrast, named: "contrast")
        try validateAdjustment(saturation, named: "saturation")
        _ = try cropValues()
    }

    private func validateAdjustment(_ value: Double, named name: String) throws {
        guard (-1...1).contains(value) else {
            throw ValidationError(
                "--\(name) must be between −1 and 1, got \(value)")
        }
    }

    /// `--crop`'s four numbers, or `nil` if the flag was not given.
    ///
    /// Only the *shape* is checked here; whether the rectangle fits the image is
    /// `CropGeometry.snap`'s business and needs the image.
    private func cropValues() throws -> (x: Int, y: Int, width: Int, height: Int)? {
        guard let crop else { return nil }

        let numbers = crop.split(separator: ",", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 4, let x = numbers[0], let y = numbers[1],
            let width = numbers[2], let height = numbers[3]
        else {
            throw ValidationError(
                "--crop takes four whole numbers as ‘x,y,w,h’, got ‘\(crop)’")
        }
        return (x, y, width, height)
    }

    // MARK: - Running

    func run() throws {
        let report: ConversionReport
        do {
            report = try convert()
        } catch {
            throw described(error)
        }

        if json {
            let encoder = JSONEncoder()
            // Sorted so two runs of the same conversion produce the same bytes
            // on standard output as well as in the file; unescaped slashes
            // because every string in here is a path.
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print(summary(of: report))
        }
    }

    private func convert() throws -> ConversionReport {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = output.map { URL(fileURLWithPath: $0) }

        var settings = ConversionSettings()
        // The override happens here, before the request exists, so the engine
        // sees one mode and can treat a disagreement with the format as the
        // error it is. Bending the format to match the mode instead would write
        // a file whose readers assume the opposite.
        //
        // A `--prg`-only run has no format to infer from — a PRG carries both
        // modes — so it keeps the default unless `--mode` says otherwise.
        settings.mode = mode ?? outputURL.flatMap(inferredMode(for:)) ?? settings.mode
        settings.dither = dither
        settings.palette = palette
        settings.brightness = brightness
        settings.contrast = contrast
        settings.saturation = saturation

        var request = ConversionRequest(inputURL: inputURL, settings: settings)
        request.c64OutputURL = outputURL
        request.pngOutputURL = png.map { URL(fileURLWithPath: $0) }
        request.prgOutputURL = prg.map { URL(fileURLWithPath: $0) }
        request.cropRect = try snappedCrop(source: inputURL)

        let result = try ConversionOperation.run(request)

        return ConversionReport(
            input: inputURL.path,
            outputs: result.writtenFiles.map(\.path),
            mode: result.image.mode.rawValue,
            palette: settings.palette.rawValue,
            dither: settings.dither.rawValue,
            background: result.image.background.map(Int.init),
            crop: CropBox(result.cropUsed))
    }

    /// The mode the output extension implies, taken from the format table rather
    /// than from a second list of extensions here. `nil` for an extension that
    /// names no format — which is not this function's problem: the request will
    /// be rejected for that extension a moment later, and rejecting it *there*
    /// is what produces a message about the filename the user typed.
    private func inferredMode(for output: URL) -> BitmapMode? {
        C64FileWriter.inferFormat(fromExtension: output.pathExtension)?.requiredMode
    }

    /// The `--crop` rectangle, snapped and bounds-checked, or `nil` for the
    /// default crop.
    ///
    /// `ConversionOperation.run` deliberately *clips* a rectangle that hangs off
    /// the image rather than refusing it, because a conversion must not fail
    /// mid-drag in the app. A CLI has no drag: a crop that does not fit is a typo
    /// worth reporting, so it goes through `CropGeometry.snap` first — which
    /// needs the source's dimensions, which is why the image is opened here.
    /// That decode is repeated inside `run`; it costs one file read on the one
    /// path that asked for the check.
    private func snappedCrop(source: URL) throws -> CGRect? {
        guard let values = try cropValues() else { return nil }

        let image = try ImageLoading.loadCGImage(from: source)
        return try CropGeometry.snap(
            x: values.x, y: values.y, width: values.width, height: values.height,
            sourceWidth: image.width, sourceHeight: image.height)
    }

    // MARK: - Reporting

    private func summary(of report: ConversionReport) -> String {
        let crop = report.crop
        return "\(report.outputs.joined(separator: ", ")) — \(report.mode), "
            + "\(report.palette) palette, \(report.dither) dither, "
            + "crop \(crop.width)×\(crop.height) at (\(crop.x), \(crop.y))"
    }

    /// The sentence a failure is printed as.
    ///
    /// The engine's own errors already carry sentences written for a human — the
    /// crop message names the offending dimension, the mismatch message names
    /// both the format and the way out — so they are passed through rather than
    /// paraphrased. Only the two file-system errors need wording, because they
    /// carry a URL and nothing else. Anything unrecognised, `ValidationError`
    /// included, keeps its own presentation.
    private func described(_ error: Error) -> Error {
        switch error {
        case CropError.outOfBounds(let message):
            return CLIFailure("--crop: \(message)")
        case ConversionRequestError.outputExtensionUnknown(let message),
            ConversionRequestError.modeFormatMismatch(let message):
            return CLIFailure(message)
        case ImageLoadingError.unreadable(let url):
            return CLIFailure(
                "could not read ‘\(url.path)’ — it is missing, unreadable, or not an image "
                    + "format this tool can decode")
        case ImageLoadingError.unwritable(let url):
            return CLIFailure(
                "could not write ‘\(url.path)’ — check that the folder exists and is writable")
        default:
            return error
        }
    }
}

/// A failure carrying nothing but the sentence to print.
///
/// `LocalizedError` rather than a bare `Error` because that is the protocol
/// ArgumentParser's message machinery reads; a plain `Error` would be printed as
/// its Swift description, which is a type name and a payload rather than
/// something to act on.
struct CLIFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
