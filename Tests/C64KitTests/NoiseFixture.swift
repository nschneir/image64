import C64Kit

/// A 64-bit linear congruential generator, used instead of `SystemRandom` so
/// the "random image" fixtures are byte-identical on every machine and every
/// run. Knuth's MMIX multiplier/increment; the low bits of an LCG are
/// notoriously non-random, so only the top byte of the state is ever used.
struct LCG {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func nextByte() -> UInt8 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 56)
    }
}

/// The pseudo-random image every noise-driven test in the suite starts from.
///
/// Shared rather than duplicated per test file so that the cell-constraint
/// invariants and the packing round-trip are provably measured against the
/// *same* pixels: a packing bug that only shows up on a particular buffer
/// cannot hide behind a differently-seeded fixture.
enum NoiseFixture {

    /// The one seed every pseudo-random fixture starts from. Constant on
    /// purpose: a failure must be reproducible from the source alone, with no
    /// console output to copy back in.
    static let seed: UInt64 = 0x1234_5678_9ABC_DEF0

    /// A `width`×`height` buffer of pseudo-random sRGB noise, filled
    /// red-green-blue per pixel in row-major order.
    ///
    /// Noise is the worst case for both stages it feeds. Quantized, an 8×8 cell
    /// of it holds a dozen or more distinct indices, so cell constraint is
    /// actually exercising its drop-and-remap path rather than mostly finding
    /// cells that were already legal; and the constrained result uses every
    /// colour slot in nearly every cell, so packing is exercising all four
    /// multicolour codes rather than mostly writing `%00`.
    static func rgb(width: Int, height: Int) -> RGBBuffer {
        var rng = LCG(seed: seed)
        var pixels: [RGB] = []
        pixels.reserveCapacity(width * height)
        for _ in 0..<(width * height) {
            pixels.append(RGB(r: rng.nextByte(), g: rng.nextByte(), b: rng.nextByte()))
        }
        return RGBBuffer(width: width, height: height, pixels: pixels)
    }
}
