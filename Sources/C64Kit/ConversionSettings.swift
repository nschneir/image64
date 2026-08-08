/// Which VIC-II bitmap mode the output targets.
///
/// Hires is 320×200 with two colours per 8×8 cell. Multicolour halves the
/// horizontal resolution to 160×200 — pixels are twice as wide — in exchange
/// for four colours per cell, one of which is shared across the whole image.
public enum BitmapMode: String, Sendable, Codable {
    case hires
    case multicolor
}

/// How quantization error is spread before the palette snap.
///
/// - `none`: snap each pixel to its nearest palette colour and accept the
///   banding.
/// - `bayer`: an ordered threshold matrix — deterministic, tiles cleanly, and
///   gives the regular cross-hatch look of period artwork.
/// - `fs`: Floyd–Steinberg error diffusion — smoother gradients, but the error
///   trail makes it sensitive to processing order.
public enum DitherMode: String, Sendable, Codable {
    case none
    case bayer
    case fs
}

/// Everything the user can change about a conversion.
///
/// This is the whole knob set, in one value type: the app binds its controls to
/// it, the CLI parses flags into it, and a conversion is a pure function of an
/// image plus one of these. Being `Codable` lets it round-trip through saved
/// presets; being `Equatable` lets the app tell whether a re-render is needed.
///
/// The defaults are the ones that make a photograph look best on first drop:
/// multicolour has four colours per cell instead of two, and Floyd–Steinberg
/// hides the small palette better than ordered dithering does.
public struct ConversionSettings: Equatable, Sendable, Codable {
    /// Target bitmap mode. Defaults to multicolour.
    public var mode: BitmapMode = .multicolor

    /// Dither algorithm. Defaults to Floyd–Steinberg.
    public var dither: DitherMode = .fs

    /// Brightness adjustment, −1…+1, applied before quantization. 0 is no change.
    public var brightness: Double = 0

    /// Contrast adjustment, −1…+1, applied before quantization. 0 is no change.
    public var contrast: Double = 0

    /// Saturation adjustment, −1…+1, applied before quantization. 0 is no change.
    public var saturation: Double = 0

    /// Which sixteen-colour table to snap to. Defaults to Colodore.
    public var palette: C64Palette = .colodore

    /// Creates settings with every value at its default.
    public init() {}
}
