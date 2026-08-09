/// A rectangle of true-colour pixels, row-major.
///
/// This is the engine's input format: whatever loaded and scaled the source
/// image hands over one of these, and everything downstream works in bytes from
/// here on. Row-major with no stride or padding, so `y * width + x` is the whole
/// addressing story and a buffer can be compared or hashed as a flat array.
public struct RGBBuffer: Sendable {
    /// Pixels per row.
    public let width: Int

    /// Number of rows.
    public let height: Int

    /// `width * height` pixels, row 0 first.
    public var pixels: [RGB]

    /// Creates a buffer from a flat row-major pixel array.
    ///
    /// - Precondition: `pixels.count == width * height`.
    public init(width: Int, height: Int, pixels: [RGB]) {
        precondition(
            pixels.count == width * height,
            "RGBBuffer expects \(width * height) pixels, got \(pixels.count)")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The pixel at column `x`, row `y`.
    public subscript(x: Int, y: Int) -> RGB {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }
}

/// A rectangle of C64 palette indices, row-major.
///
/// The result of quantization and the currency of every later stage: cell
/// constraint, packing, and the file writers all read indices, never colours.
/// One byte per pixel even though only the low nibble is used — the wasted bits
/// buy direct indexing, and the arrays involved are at most 64 000 entries.
///
/// `Equatable` on purpose: the golden-file tests and the determinism checks
/// compare whole buffers.
public struct IndexBuffer: Equatable, Sendable {
    /// Pixels per row.
    public let width: Int

    /// Number of rows.
    public let height: Int

    /// `width * height` palette indices, 0…15, row 0 first.
    public var indices: [UInt8]

    /// Creates a buffer from a flat row-major index array.
    ///
    /// - Precondition: `indices.count == width * height`.
    public init(width: Int, height: Int, indices: [UInt8]) {
        precondition(
            indices.count == width * height,
            "IndexBuffer expects \(width * height) indices, got \(indices.count)")
        self.width = width
        self.height = height
        self.indices = indices
    }

    /// The index at column `x`, row `y`.
    public subscript(x: Int, y: Int) -> UInt8 {
        get { indices[y * width + x] }
        set { indices[y * width + x] = newValue }
    }
}
