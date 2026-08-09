import CoreGraphics
import Foundation

/// Everything one conversion needs to know.
///
/// The two output URLs are independent and both optional: the CLI sets one or
/// both, and the app's live preview sets neither and reads the picture out of
/// the result. That is the same call in all three cases, which is the point.
public struct ConversionRequest: Sendable {
    /// The image to convert.
    public var inputURL: URL

    /// The region of the source to use, in source pixels with y = 0 at the top.
    /// `nil` means `CropGeometry.defaultCrop` — the largest centred 8:5
    /// rectangle — which is what both front ends start from.
    ///
    /// Not validated here: a rectangle that hangs off the image is clipped by
    /// `ImageLoading.prepare`, and one that misses entirely falls back to the
    /// whole image, because a conversion must not fail mid-drag. A front end
    /// that wants a rectangle *rejected* rather than tidied — the CLI's
    /// `--crop`, say — runs it through `CropGeometry.snap` first.
    public var cropRect: CGRect?

    /// Mode, dither, palette and the colour adjustments.
    public var settings: ConversionSettings

    /// Where to write the native C64 file. The path extension picks the format
    /// (`.koa` or `.art`), and that format must agree with `settings.mode`.
    /// `nil` writes no C64 file.
    public var c64OutputURL: URL?

    /// Where to write a 640×400 PNG of the result. `nil` writes no PNG.
    public var pngOutputURL: URL?

    /// Creates a request for `inputURL` with `settings`, no explicit crop and
    /// no outputs. The optional fields are `var`s, so a caller that wants them
    /// sets them after; a caller that wants an in-memory conversion — the app —
    /// stops here.
    public init(inputURL: URL, settings: ConversionSettings) {
        self.inputURL = inputURL
        self.settings = settings
    }
}

/// The outcome of a conversion.
public struct ConversionResult: Sendable {
    /// The converted picture, in the exact bytes a C64 would hold.
    public let image: C64Image

    /// The crop that was actually used — the request's, or the default that
    /// was computed for it. Front ends echo this back to the user (the CLI
    /// prints it, the app draws it), so a defaulted crop is never a mystery.
    public let cropUsed: CGRect

    /// The files written, in the order they were written: the C64 file first,
    /// then the PNG. Empty for an in-memory conversion.
    public let writtenFiles: [URL]
}

/// What can go wrong with the *request* — as opposed to the image or the file
/// system.
///
/// Both payloads are sentences for a human, for the same reason as
/// `CropError.outOfBounds`: the CLI prints them and the app shows them in an
/// alert, and neither has anything to add.
public enum ConversionRequestError: Error, Equatable, Sendable {
    /// The C64 output URL's path extension names no format this tool writes.
    case outputExtensionUnknown(String)

    /// The format named by the output extension does not encode the mode the
    /// settings ask for — a `.koa` is multicolour by definition, a `.art`
    /// hires.
    case modeFormatMismatch(String)
}

/// The one entry point both front ends call.
///
/// This type is the project's cardinal rule made structural. The app and the
/// CLI must never be able to convert an image *differently*, so neither of them
/// gets to assemble the stages itself: they both come through here, and
/// everything from `ImageLoading.prepare` onward happens in exactly one place —
/// `convert`, via the private `pipeline`. A stage added, reordered or given
/// different parameters changes both front ends at once, or neither.
///
/// ## The pipeline
///
/// 1. **Load** the source (`run` only; `convert` is handed a `CGImage` the app
///    already holds from a drag-and-drop).
/// 2. **Crop, resize and adjust** in one Core Image pass, straight to the
///    target geometry — 320×200 for hires, 160×200 for multicolour.
/// 3. **Quantize** to the sixteen-colour palette with the requested dither.
/// 4. **Enforce** the per-cell colour limits, which for multicolour also picks
///    the shared background.
/// 5. **Pack** into bitmap, screen RAM, and (multicolour) colour RAM.
/// 6. **Write** whichever outputs the request asked for.
///
/// Step 2 is why `CellConstraints` and `C64Image.pack` can trust their input
/// dimensions: the resize target is chosen from the mode here, so a buffer of
/// the wrong size cannot reach the packer through this path. `CellConstraints`
/// accepts any dimensions silently, so this is the *only* place the guarantee
/// lives.
public enum ConversionOperation {

    // MARK: - Geometry
    //
    // Derived from `C64Image`'s cell counts rather than written as 320/200/640
    // so there is one definition of how big a C64 picture is.

    /// The width and height the source is resampled to before quantization.
    ///
    /// Multicolour pixels are twice as wide as hires ones, so its buffer is
    /// half the width for the same picture — the resize is anamorphic, and
    /// `ImageLoading.prepare` is built for exactly that.
    private static func targetSize(for mode: BitmapMode) -> (width: Int, height: Int) {
        let height = C64Image.cellRows * 8
        switch mode {
        case .hires: return (C64Image.cellColumns * 8, height)
        case .multicolor: return (C64Image.cellColumns * 4, height)
        }
    }

    /// The size of the exported PNG, in both modes.
    ///
    /// 640×400 is a whole-number magnification of both native geometries — 2×2
    /// from hires' 320×200, 4×2 from multicolour's 160×200 — which is what lets
    /// the export be pure pixel replication with no resampling, and which puts
    /// multicolour's double-wide pixels on screen at the right shape.
    public static let pngWidth = C64Image.cellColumns * 16
    public static let pngHeight = C64Image.cellRows * 16

    // MARK: - Running a request

    /// Converts the image at `request.inputURL` and writes whatever outputs the
    /// request names.
    ///
    /// With both output URLs `nil` this is a pure in-memory conversion that
    /// touches the file system only to read the input — which is how the app's
    /// preview uses it.
    ///
    /// - Throws: `ConversionRequestError` if the output extension is unknown or
    ///   disagrees with the mode (checked *before* any work, so a bad request
    ///   fails immediately and leaves nothing half-written);
    ///   `ImageLoadingError.unreadable` if the input cannot be decoded;
    ///   `ImageLoadingError.unwritable` if an output cannot be written.
    public static func run(_ request: ConversionRequest) throws -> ConversionResult {
        // First, because it is the one failure that needs no image at all and
        // the one a user is most likely to hit twice in a row.
        let c64Output = try c64Output(for: request)

        let source = try ImageLoading.loadCGImage(from: request.inputURL)
        let crop =
            request.cropRect
            ?? CropGeometry.defaultCrop(sourceWidth: source.width, sourceHeight: source.height)

        let image = convert(source, cropRect: crop, settings: request.settings)

        var writtenFiles: [URL] = []
        if let (url, format) = c64Output {
            let data = try C64FileWriter.data(for: image, format: format)
            do {
                try data.write(to: url)
            } catch {
                // Collapsed to `unwritable` deliberately: the front ends report
                // "could not write <path>" either way, and this keeps every
                // file-system failure in the pipeline one type.
                throw ImageLoadingError.unwritable(url)
            }
            writtenFiles.append(url)
        }
        if let url = request.pngOutputURL {
            try ImageLoading.writePNG(
                previewImage(for: image, palette: request.settings.palette), to: url)
            writtenFiles.append(url)
        }

        return ConversionResult(image: image, cropUsed: crop, writtenFiles: writtenFiles)
    }

    /// Converts an image the caller already holds — the app's drag-and-drop
    /// path — with no file system involved at either end.
    ///
    /// Identical to `run` from `ImageLoading.prepare` onward, because `run`
    /// calls this. That is not a convenience: it is the guarantee that the
    /// preview the user is looking at is the file they will get.
    public static func convert(
        _ source: CGImage, cropRect: CGRect, settings: ConversionSettings
    ) -> C64Image {
        let target = targetSize(for: settings.mode)
        let prepared = ImageLoading.prepare(
            source, cropRect: cropRect,
            targetWidth: target.width, targetHeight: target.height,
            brightness: settings.brightness, contrast: settings.contrast,
            saturation: settings.saturation)
        return pipeline(prepared, settings: settings)
    }

    /// The 640×400 nearest-neighbour rendering of `image` — what the PNG export
    /// writes and what the app draws.
    ///
    /// Shared for the same reason as everything else here: if the export and
    /// the preview scaled differently, the preview would stop being proof of
    /// the file.
    public static func previewImage(for image: C64Image, palette: C64Palette) -> CGImage {
        let rendered = image.render(palette: palette)
        return ImageLoading.cgImage(
            from: rendered,
            scaleX: pngWidth / rendered.width, scaleY: pngHeight / rendered.height)
    }

    // MARK: - The pipeline

    /// Quantize, constrain, pack. The half of the conversion that has nothing
    /// to do with where the pixels came from.
    ///
    /// `buffer` must already be the target geometry for `settings.mode`;
    /// `convert` is the only caller and chooses it from the mode, so the
    /// packers' dimension preconditions hold by construction.
    private static func pipeline(_ buffer: RGBBuffer, settings: ConversionSettings) -> C64Image {
        var indices = Quantizer.quantize(
            buffer, palette: settings.palette, dither: settings.dither)

        switch settings.mode {
        case .hires:
            CellConstraints.enforceHires(&indices, palette: settings.palette)
            return C64Image.pack(hires: indices)
        case .multicolor:
            // The background comes back from the constraint pass rather than
            // being chosen again here: it is the colour every cell was allowed
            // to keep, so packing against a different one would strand pixels.
            let background = CellConstraints.enforceMulticolor(
                &indices, palette: settings.palette)
            return C64Image.pack(multicolor: indices, background: background)
        }
    }

    // MARK: - Request validation

    /// The C64 file to write and the format to write it in, or `nil` if the
    /// request asks for no C64 file at all.
    ///
    /// Returned as a pair rather than as a bare format so the URL and the
    /// format it was derived from travel together: there is then no way for the
    /// caller to hold one without the other, and no unreachable branch to write
    /// for the combination that cannot happen.
    ///
    /// The mode check lives here rather than being left to
    /// `C64FileWriter.data(for:format:)` so it happens before the conversion
    /// runs, and so the message can talk about the user's *request* — a wrong
    /// filename or a wrong `--mode` — instead of about a picture they never
    /// asked for. The CLI's `--mode` override therefore changes the mode before
    /// this point; it never bends the format to match, because the format is
    /// what the file's readers will assume.
    private static func c64Output(
        for request: ConversionRequest
    ) throws -> (url: URL, format: C64FileFormat)? {
        guard let url = request.c64OutputURL else { return nil }

        let ext = url.pathExtension
        guard let format = C64FileWriter.inferFormat(fromExtension: ext) else {
            let known = C64FileFormat.allCases.map(\.rawValue).sorted().joined(separator: ", ")
            throw ConversionRequestError.outputExtensionUnknown(
                "‘\(url.lastPathComponent)’ has the extension ‘\(ext)’, which is not a C64 "
                    + "picture format — use one of: \(known)")
        }
        guard format.requiredMode == request.settings.mode else {
            throw ConversionRequestError.modeFormatMismatch(
                "‘.\(format.rawValue)’ files are always \(format.requiredMode.rawValue), but the "
                    + "settings ask for \(request.settings.mode.rawValue) — either change the "
                    + "mode or write a ‘.\(otherFormat(than: format).rawValue)’ file")
        }
        return (url, format)
    }

    /// The other format, for the "or write one of these instead" half of the
    /// mismatch message. Total by construction while there are two formats;
    /// falls back to `format` itself rather than trapping if a third is ever
    /// added without revisiting this.
    private static func otherFormat(than format: C64FileFormat) -> C64FileFormat {
        C64FileFormat.allCases.first { $0.requiredMode != format.requiredMode } ?? format
    }
}
