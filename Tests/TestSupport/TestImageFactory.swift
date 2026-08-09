import C64Kit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes the PNG fixtures the image-loading and CLI tests read back.
///
/// Shared rather than duplicated per test file so a fixture's pixels mean the
/// same thing everywhere: the CLI tests convert the *same* gradient the engine
/// tests measure, so a disagreement between the two front ends cannot hide
/// behind differently-drawn inputs. That is also why this lives in its own
/// `TestSupport` target rather than in `C64KitTests`: `CLITests` needs the same
/// fixtures, and a second copy of this file would let the two suites drift.
///
/// Deliberately does **not** go through `ImageLoading.writePNG`, even though
/// that would be less code: a fixture built by the system under test cannot
/// witness that system's bugs. The eight lines of `CGImageDestination` here are
/// the price of an independent input.
public enum TestImageFactory {

    /// Draws a `width`×`height` image whose columns ramp linearly from `from`
    /// (column 0) to `to` (the last column) and writes it to `url` as a PNG.
    ///
    /// A horizontal ramp rather than a vertical one on purpose: it is the axis
    /// that anamorphic scaling squeezes (320-wide sources become 160-wide
    /// multicolour images), so a resize that loses or transposes the horizontal
    /// factor shows up as wrong pixel values rather than merely wrong extents.
    /// Passing the same colour for `from` and `to` yields a solid fill.
    ///
    /// Fixture construction is not a runtime path, so the CoreGraphics and
    /// ImageIO failures below — all of which mean "the parameters are
    /// impossible" — trap rather than propagate; that keeps the signature
    /// callable from non-throwing setup code.
    public static func makePNG(
        width: Int, height: Int, horizontalGradient from: RGB, to: RGB, at url: URL
    ) {
        precondition(width > 0 && height > 0, "fixture size must be positive")

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else {
            preconditionFailure("could not create a \(width)×\(height) fixture context")
        }

        // One fill per column: exact byte values, no gradient interpolation to
        // reason about when a test asserts what a particular column holds.
        for x in 0..<width {
            let color = gradientColor(from: from, to: to, width: width, x: x)
            context.setFillColor(
                CGColor(
                    srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                    blue: CGFloat(color.b) / 255, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }

        guard let image = context.makeImage() else {
            preconditionFailure("could not snapshot the fixture context")
        }
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            preconditionFailure("could not create a PNG destination at \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination), "could not write \(url.path)")
    }

    /// Draws a `width`×`height` solid fill whose components are **Display P3**
    /// values and writes it as a PNG tagged with that profile.
    ///
    /// The engine's other fixtures are all authored in sRGB, which means they
    /// cannot tell colour-managed decoding from reading the file's bytes
    /// straight through. A wide-gamut source can: the same bytes mean a
    /// different colour, so the prepared buffer only holds the right values if
    /// the profile was honoured. Photographs off a modern phone are P3, so this
    /// is the common case, not an exotic one.
    public static func makeDisplayP3PNG(
        width: Int, height: Int, solid components: (r: Double, g: Double, b: Double), at url: URL
    ) {
        precondition(width > 0 && height > 0, "fixture size must be positive")

        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: p3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let color = CGColor(
                colorSpace: p3,
                components: [
                    CGFloat(components.r), CGFloat(components.g), CGFloat(components.b), 1,
                ])
        else {
            preconditionFailure("could not create a \(width)×\(height) Display P3 fixture")
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let image = context.makeImage() else {
            preconditionFailure("could not snapshot the fixture context")
        }
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            preconditionFailure("could not create a PNG destination at \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination), "could not write \(url.path)")
    }

    /// The colour `makePNG` paints into column `x` of a `width`-wide gradient.
    ///
    /// Exposed so a test can state the expected pixel without restating the
    /// interpolation — and so that if the ramp ever changes, the expectations
    /// change with it instead of silently disagreeing.
    public static func gradientColor(from: RGB, to: RGB, width: Int, x: Int) -> RGB {
        let t = width == 1 ? 0 : Double(x) / Double(width - 1)
        func ramp(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded())
        }
        return RGB(r: ramp(from.r, to.r), g: ramp(from.g, to.g), b: ramp(from.b, to.b))
    }
}
