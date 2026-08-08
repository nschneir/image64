/// A colour as three sRGB byte components.
///
/// The engine works in bytes end to end: source pixels arrive as bytes, the
/// palette tables are byte triples, and the nearest-colour search compares
/// bytes. Nothing here is colour-managed — a C64 palette is a fixed list of
/// sixteen sRGB values, not a colour space.
public struct RGB: Equatable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// A choice of C64 colour table.
///
/// Both tables describe the same sixteen hardware colours; they differ in how
/// the VIC-II's analogue output was measured and modelled. Colodore is the
/// modern default and what most current emulators show; Pepto is the older
/// measurement, kept because a lot of existing artwork was authored against it.
///
/// The raw values are the persistence format — they appear in saved settings
/// and on the CLI — so they must stay stable.
public enum C64Palette: String, CaseIterable, Sendable, Codable {
    case colodore
    case pepto

    /// The sixteen colours, indexed by C64 colour number (0 = black, 1 = white,
    /// … 15 = light grey).
    public var colors: [RGB] {
        switch self {
        case .colodore: return Self.colodoreColors
        case .pepto: return Self.peptoColors
        }
    }

    private static let colodoreColors: [RGB] = [
        RGB(r: 0x00, g: 0x00, b: 0x00),  //  0 black
        RGB(r: 0xFF, g: 0xFF, b: 0xFF),  //  1 white
        RGB(r: 0x81, g: 0x33, b: 0x38),  //  2 red
        RGB(r: 0x75, g: 0xCE, b: 0xC8),  //  3 cyan
        RGB(r: 0x8E, g: 0x3C, b: 0x97),  //  4 purple
        RGB(r: 0x56, g: 0xAC, b: 0x4D),  //  5 green
        RGB(r: 0x2E, g: 0x2C, b: 0x9B),  //  6 blue
        RGB(r: 0xED, g: 0xF1, b: 0x71),  //  7 yellow
        RGB(r: 0x8E, g: 0x50, b: 0x29),  //  8 orange
        RGB(r: 0x55, g: 0x38, b: 0x00),  //  9 brown
        RGB(r: 0xC4, g: 0x6C, b: 0x71),  // 10 light red
        RGB(r: 0x4A, g: 0x4A, b: 0x4A),  // 11 dark grey
        RGB(r: 0x7B, g: 0x7B, b: 0x7B),  // 12 medium grey
        RGB(r: 0xA9, g: 0xFF, b: 0x9F),  // 13 light green
        RGB(r: 0x70, g: 0x6D, b: 0xEB),  // 14 light blue
        RGB(r: 0xB2, g: 0xB2, b: 0xB2),  // 15 light grey
    ]

    private static let peptoColors: [RGB] = [
        RGB(r: 0x00, g: 0x00, b: 0x00),  //  0 black
        RGB(r: 0xFF, g: 0xFF, b: 0xFF),  //  1 white
        RGB(r: 0x68, g: 0x37, b: 0x2B),  //  2 red
        RGB(r: 0x70, g: 0xA4, b: 0xB2),  //  3 cyan
        RGB(r: 0x6F, g: 0x3D, b: 0x86),  //  4 purple
        RGB(r: 0x58, g: 0x8D, b: 0x43),  //  5 green
        RGB(r: 0x35, g: 0x28, b: 0x79),  //  6 blue
        RGB(r: 0xB8, g: 0xC7, b: 0x6F),  //  7 yellow
        RGB(r: 0x6F, g: 0x4F, b: 0x25),  //  8 orange
        RGB(r: 0x43, g: 0x39, b: 0x00),  //  9 brown
        RGB(r: 0x9A, g: 0x67, b: 0x59),  // 10 light red
        RGB(r: 0x44, g: 0x44, b: 0x44),  // 11 dark grey
        RGB(r: 0x6C, g: 0x6C, b: 0x6C),  // 12 medium grey
        RGB(r: 0x9A, g: 0xD2, b: 0x84),  // 13 light green
        RGB(r: 0x6C, g: 0x5E, b: 0xB5),  // 14 light blue
        RGB(r: 0x95, g: 0x95, b: 0x95),  // 15 light grey
    ]

    /// Perceptually weighted squared distance between two colours.
    ///
    /// Squared, not rooted: the square root is monotonic, so it cannot change
    /// which colour wins, and skipping it keeps the inner loop cheap. The
    /// weights are the usual luma coefficients, which stop the search from
    /// trading a large green error for a small blue one.
    ///
    /// Every comparison in the engine must go through this function, so that a
    /// tie is a tie everywhere.
    public static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = Double(a.r) - Double(b.r)
        let dg = Double(a.g) - Double(b.g)
        let db = Double(a.b) - Double(b.b)
        return 0.299 * dr * dr + 0.587 * dg * dg + 0.114 * db * db
    }

    /// The palette index closest to `color`.
    ///
    /// Exact ties break toward the lower index. That rule is what makes
    /// conversion reproducible: without it, two runs could disagree on a pixel
    /// that sits exactly between two colours, and the golden-file tests would
    /// flake.
    public func nearestIndex(to color: RGB) -> UInt8 {
        let table = colors
        var bestIndex = 0
        var bestDistance = Self.distance(color, table[0])
        for index in 1..<table.count {
            let candidate = Self.distance(color, table[index])
            // Strictly less than, so an equal distance leaves the earlier —
            // lower — index in place.
            if candidate < bestDistance {
                bestDistance = candidate
                bestIndex = index
            }
        }
        return UInt8(bestIndex)
    }
}
