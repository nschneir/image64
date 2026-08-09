import Foundation

/// A native C64 picture file format.
///
/// The raw value is the conventional file extension, which is what makes
/// `inferFormat(fromExtension:)` a lookup rather than a switch and keeps the
/// extension and the format from drifting apart.
public enum C64FileFormat: String, CaseIterable, Sendable {
    /// Koala Painter — multicolour only. 10003 bytes.
    case koala = "koa"

    /// Advanced Art Studio — hires only. 9009 bytes.
    case artStudio = "art"

    /// The bitmap mode a picture must be in to be written as this format.
    ///
    /// Neither format carries a mode flag: a `.koa` is *defined* as multicolour
    /// data at `$6000` and an `.art` as hires data at `$2000`, so the mode is
    /// part of the format rather than something the file records.
    public var requiredMode: BitmapMode {
        switch self {
        case .koala: return .multicolor
        case .artStudio: return .hires
        }
    }
}

/// What can go wrong turning a `C64Image` into file bytes.
public enum C64FileError: Error, Equatable, Sendable {
    /// The picture's mode is not the one the requested format encodes — a hires
    /// image asked to be a `.koa`, or a multicolour image a `.art`.
    ///
    /// This is a caller bug rather than bad input: both formats are fixed-mode
    /// (see `C64FileFormat.requiredMode`), so there is nothing to convert on the
    /// way out and silently writing the wrong bytes would produce a file that
    /// loads as garbage on real hardware.
    case modeMismatch(expected: BitmapMode, actual: BitmapMode)
}

/// Serializes a converted picture into the byte layout of a native C64 file.
///
/// Both formats are *memory dumps with a load address on the front*: the first
/// two bytes are the little-endian address the data belongs at, exactly as a
/// PRG-style `LOAD"…",8,1` expects, and everything after is the VIC-II's own
/// arrays copied out unchanged. Nothing here reinterprets the picture — the
/// bytes written are `C64Image`'s bytes, which is what makes the app's preview
/// a true proof of the file.
///
/// ## The layouts, pinned
///
/// **Koala Painter (`.koa`), 10003 bytes, load address `$6000`**
///
/// | offset  | length | contents |
/// |---------|--------|----------|
/// | 0       | 2      | `$00 $60` — load address, low byte first |
/// | 2       | 8000   | bitmap |
/// | 8002    | 1000   | screen RAM |
/// | 9002    | 1000   | colour RAM |
/// | 10002   | 1      | background (`$d021`) |
///
/// **Advanced Art Studio (`.art`), 9009 bytes, load address `$2000`**
///
/// | offset  | length | contents |
/// |---------|--------|----------|
/// | 0       | 2      | `$00 $20` — load address, low byte first |
/// | 2       | 8000   | bitmap |
/// | 8002    | 1000   | screen RAM |
/// | 9002    | 7      | zero |
///
/// Art Studio's seven trailing bytes are leftovers of the original tool's save
/// routine; what they meant is reported inconsistently between tools — a border
/// colour is the usual claim — and every reader ignores them. They are written
/// as zero, which keeps output byte-reproducible instead of leaking whatever
/// happened to sit in the buffer, and keeps the file the pinned 9009 bytes.
public enum C64FileWriter {

    // MARK: - Layout constants
    //
    // Named rather than open-coded so the sizes appear exactly once and the
    // assembly below reads as the table in the doc comment.

    /// Bytes in the load-address header both formats carry.
    private static let loadAddressByteCount = 2

    /// Koala's load address, `$6000`.
    private static let koalaLoadAddress: UInt16 = 0x6000

    /// Art Studio's load address, `$2000`.
    private static let artStudioLoadAddress: UInt16 = 0x2000

    /// Art Studio's trailing bytes, written as zero. See the type's doc comment.
    private static let artStudioTrailerByteCount = 7

    /// Total size of a Koala file.
    public static let koalaByteCount =
        loadAddressByteCount + C64Image.bitmapByteCount + 2 * C64Image.screenByteCount + 1

    /// Total size of an Art Studio file.
    public static let artStudioByteCount =
        loadAddressByteCount + C64Image.bitmapByteCount + C64Image.screenByteCount
        + artStudioTrailerByteCount

    // MARK: - Writing

    /// The file bytes for `image` in `format`.
    ///
    /// - Throws: `C64FileError.modeMismatch` if the picture's mode is not the
    ///   one the format encodes.
    public static func data(for image: C64Image, format: C64FileFormat) throws -> Data {
        guard image.mode == format.requiredMode else {
            throw C64FileError.modeMismatch(expected: format.requiredMode, actual: image.mode)
        }
        switch format {
        case .koala: return koalaData(for: image)
        case .artStudio: return artStudioData(for: image)
        }
    }

    /// Which format a file extension names, or `nil` if it names neither.
    ///
    /// Takes a bare extension — what `URL.pathExtension` gives, with no leading
    /// dot — and matches case-insensitively so a user-typed `PICTURE.KOA` saves
    /// as Koala. Anything else is `nil` rather than a default: guessing a format
    /// for an unknown suffix would write a `.png` full of C64 memory.
    public static func inferFormat(fromExtension ext: String) -> C64FileFormat? {
        C64FileFormat(rawValue: ext.lowercased())
    }

    // MARK: - Per-format assembly

    private static func koalaData(for image: C64Image) -> Data {
        // The mode check in `data(for:format:)` guarantees multicolour, and
        // `C64Image`'s initializer guarantees multicolour carries both of these.
        // The fallbacks only keep this function total; they are unreachable.
        let colorRAM = image.colorRAM ?? [UInt8](repeating: 0, count: C64Image.screenByteCount)
        let background = image.background ?? 0

        var data = Data(capacity: koalaByteCount)
        appendLoadAddress(koalaLoadAddress, to: &data)
        data.append(contentsOf: image.bitmap)
        data.append(contentsOf: image.screenRAM)
        data.append(contentsOf: colorRAM)
        data.append(background)
        return data
    }

    private static func artStudioData(for image: C64Image) -> Data {
        var data = Data(capacity: artStudioByteCount)
        appendLoadAddress(artStudioLoadAddress, to: &data)
        data.append(contentsOf: image.bitmap)
        data.append(contentsOf: image.screenRAM)
        data.append(contentsOf: [UInt8](repeating: 0, count: artStudioTrailerByteCount))
        return data
    }

    /// Appends a 6502 load address: low byte first, as the KERNAL's loader reads
    /// it.
    private static func appendLoadAddress(_ address: UInt16, to data: inout Data) {
        data.append(UInt8(address & 0x00FF))
        data.append(UInt8(address >> 8))
    }
}
