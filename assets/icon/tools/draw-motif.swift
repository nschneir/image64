// Draws source motifs (modern, smooth, high-res) that are then fed to the real
// image64 converter. Source canvas is 1280x800 = 4x the 320x200 hires grid.
// The "design square" is the central 800x800 (full height), which maps to a
// 200x200 hires-pixel square in the converted picture.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let W = 1280
let H = 800
// Design square: x in [240, 1040), y in [0, 800)
let DX = 240.0

func ctx() -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                      bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.setAllowsAntialiasing(true)
    return c
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func hex(_ v: UInt32, _ a: Double = 1) -> CGColor {
    rgb(Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF), a)
}

func gradient(_ stops: [(Double, CGColor)]) -> CGGradient {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    return CGGradient(colorsSpace: cs, colors: stops.map { $0.1 } as CFArray,
                      locations: stops.map { CGFloat($0.0) })!
}

func write(_ c: CGContext, _ path: String) {
    let img = c.makeImage()!
    let url = URL(fileURLWithPath: path)
    let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
}

// Y is up in CG; the design square spans the whole height.

// MARK: - palette motif (dogfood: painter's palette + brush)

/// A brush drawn along an axis: tip at `tip`, pointing away at `angle` degrees
/// (0 = up). Widths in source pixels.
func drawBrush(_ c: CGContext, tip: CGPoint, angle: Double, length: Double, width: Double,
               paint: (UInt32, UInt32)) {
    c.saveGState()
    c.translateBy(x: tip.x, y: tip.y)
    c.rotate(by: angle * .pi / 180)
    let w = width
    let bristleLen = length * 0.26
    let ferruleLen = length * 0.20
    // handle (rounded far end)
    let handleRect = CGRect(x: -w * 0.42, y: bristleLen + ferruleLen * 0.6,
                            width: w * 0.84, height: length - bristleLen - ferruleLen * 0.6)
    c.saveGState()
    c.addPath(CGPath(roundedRect: handleRect, cornerWidth: w * 0.42, cornerHeight: w * 0.42, transform: nil))
    c.clip()
    let wood = gradient([(0, hex(0xA86A20)), (0.42, hex(0x8E5029)), (1, hex(0x4E3204))])
    c.drawLinearGradient(wood, start: CGPoint(x: -w * 0.42, y: 0), end: CGPoint(x: w * 0.42, y: 0), options: [])
    c.restoreGState()
    // ferrule
    c.saveGState()
    c.addRect(CGRect(x: -w * 0.5, y: bristleLen - 4, width: w, height: ferruleLen + 8))
    c.clip()
    let metal = gradient([(0, hex(0xF2F2F2)), (0.42, hex(0xB0B0B0)), (1, hex(0x4A4A4A))])
    c.drawLinearGradient(metal, start: CGPoint(x: -w * 0.5, y: 0), end: CGPoint(x: w * 0.5, y: 0), options: [])
    c.restoreGState()
    // bristles, loaded with paint
    let bri = CGMutablePath()
    bri.move(to: CGPoint(x: -w * 0.48, y: bristleLen))
    bri.addLine(to: CGPoint(x: w * 0.48, y: bristleLen))
    bri.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: w * 0.30, y: bristleLen * 0.18))
    bri.addQuadCurve(to: CGPoint(x: -w * 0.48, y: bristleLen), control: CGPoint(x: -w * 0.30, y: bristleLen * 0.18))
    bri.closeSubpath()
    c.saveGState()
    c.addPath(bri)
    c.clip()
    let p = gradient([(0, hex(paint.0)), (1, hex(paint.1))])
    c.drawLinearGradient(p, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: bristleLen * 1.1), options: [])
    c.restoreGState()
    c.restoreGState()
}

func drawPalette(_ c: CGContext) {
    // Flat C64 blue background: converts to a solid field of palette index 6,
    // so the picture merges with the icon's border field.
    c.setFillColor(hex(0x2E2C9B))
    c.fill(CGRect(x: 0, y: 0, width: Double(W), height: Double(H)))

    let pcx = DX + 390.0
    let pcy = 380.0
    let rx = 336.0
    let ry = 266.0
    let rot = -8 * Double.pi / 180

    // Palette body: white with a light-grey underside so the C64 render keeps
    // white + light grey rather than banding through yellow.
    c.saveGState()
    c.translateBy(x: pcx, y: pcy)
    c.rotate(by: rot)
    c.saveGState()
    c.addEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
    c.clip()
    let pal = gradient([(0, hex(0xFFFFFF)), (0.80, hex(0xF8F8F8)), (1, hex(0xB2B2B2))])
    c.drawLinearGradient(pal, start: CGPoint(x: 0, y: ry), end: CGPoint(x: 0, y: -ry), options: [])
    c.restoreGState()
    // rim
    c.setStrokeColor(hex(0x8E5029))
    c.setLineWidth(26)
    c.addEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
    c.strokePath()
    // thumb hole, in the background colour
    c.setFillColor(hex(0x2E2C9B))
    c.fillEllipse(in: CGRect(x: -rx * 0.80, y: -ry * 0.70, width: 168, height: 128))
    c.restoreGState()

    // Paint blobs on the arc clear of the brush's diagonal
    // Colours sit on C64 palette pairs so the quantizer lands on clean bands
    // rather than three-way banding.
    let blobs: [(Double, Double, Double, UInt32, UInt32)] = [
        (380, 435, 74, 0xCE7076, 0x9E4045),  // light red -> red
        (465, 548, 78, 0xF4F888, 0xDCC858),  // yellow
        (570, 605, 80, 0x62BC58, 0x4C9C45),  // green
        (720, 560, 76, 0x8CDCD6, 0x6CC0BA),  // cyan
        (865, 300, 66, 0x9A44A4, 0x82348B),  // purple
    ]
    for (bx, by, r, hi, lo) in blobs {
        let g = gradient([(0, hex(hi)), (1, hex(lo))])
        c.saveGState()
        c.addEllipse(in: CGRect(x: bx - r, y: by - r, width: r * 2, height: r * 2))
        c.clip()
        c.drawRadialGradient(g, startCenter: CGPoint(x: bx - r * 0.18, y: by + r * 0.22), startRadius: 0,
                            endCenter: CGPoint(x: bx, y: by), endRadius: r * 1.5,
                            options: [.drawsAfterEndLocation])
        c.restoreGState()
    }

    // Brush: tip resting on the palette below the thumb hole, handle leaving
    // through the top-right corner of the design square.
    drawBrush(c, tip: CGPoint(x: 540, y: 175), angle: -46, length: 720, width: 120,
              paint: (0xFF7080, 0xA81828))
}

// MARK: - sunset motif (photographic-ish: shows off dithering)

func drawSunset(_ c: CGContext) {
    let horizon = 300.0
    // Sky
    c.saveGState()
    c.clip(to: CGRect(x: 0, y: horizon, width: Double(W), height: Double(H) - horizon))
    let sky = gradient([(0, hex(0xFFE9A0)), (0.16, hex(0xFF9A3C)), (0.42, hex(0xE04A6A)),
                        (0.68, hex(0x7A3390)), (1, hex(0x141A64))])
    c.drawLinearGradient(sky, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: Double(H)), options: [])
    c.restoreGState()

    // Sun
    let sx = DX + 400.0
    let sy = horizon + 120
    c.saveGState()
    let sunR = 130.0
    c.addEllipse(in: CGRect(x: sx - sunR, y: sy - sunR, width: sunR * 2, height: sunR * 2))
    c.clip()
    let sun = gradient([(0, hex(0xFFFFF0)), (0.55, hex(0xFFE070)), (1, hex(0xFFA028))])
    c.drawRadialGradient(sun, startCenter: CGPoint(x: sx, y: sy), startRadius: 0,
                         endCenter: CGPoint(x: sx, y: sy), endRadius: sunR,
                         options: [.drawsAfterEndLocation])
    c.restoreGState()

    // Sea
    c.saveGState()
    c.clip(to: CGRect(x: 0, y: 0, width: Double(W), height: horizon))
    let sea = gradient([(0, hex(0x0B1040)), (0.5, hex(0x2A2680)), (1, hex(0xB04A70))])
    c.drawLinearGradient(sea, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: horizon), options: [])
    // sun glitter column
    let col = gradient([(0, hex(0xFFC050, 0.0)), (1, hex(0xFFD870, 0.85))])
    c.saveGState()
    let colPath = CGMutablePath()
    colPath.move(to: CGPoint(x: sx - 40, y: horizon))
    colPath.addLine(to: CGPoint(x: sx + 40, y: horizon))
    colPath.addLine(to: CGPoint(x: sx + 150, y: 0))
    colPath.addLine(to: CGPoint(x: sx - 150, y: 0))
    colPath.closeSubpath()
    c.addPath(colPath)
    c.clip()
    c.drawLinearGradient(col, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: horizon), options: [])
    c.restoreGState()
    // wave lines
    c.setLineWidth(9)
    var y = 30.0
    while y < horizon - 20 {
        let alpha = 0.10 + 0.22 * (y / horizon)
        c.setStrokeColor(hex(0xFFE0B0, alpha))
        let jitter = sin(y * 0.11) * 120
        c.move(to: CGPoint(x: 0, y: y))
        c.addLine(to: CGPoint(x: Double(W), y: y + jitter * 0.02))
        c.strokePath()
        y += 34
    }
    c.restoreGState()

    // Island silhouette on the horizon
    c.setFillColor(hex(0x140C22))
    let isl = CGMutablePath()
    isl.move(to: CGPoint(x: DX - 40, y: horizon))
    isl.addCurve(to: CGPoint(x: DX + 210, y: horizon),
                 control1: CGPoint(x: DX + 40, y: horizon + 130),
                 control2: CGPoint(x: DX + 130, y: horizon + 40))
    isl.closeSubpath()
    c.addPath(isl)
    c.fillPath()
}

// MARK: - swoosh motif (bold paint swipe; own concept, small-size legibility)

func drawSwoosh(_ c: CGContext) {
    // Flat C64 blue field
    c.setFillColor(hex(0x2E2C9B))
    c.fill(CGRect(x: 0, y: 0, width: Double(W), height: Double(H)))

    // Tapering brush swipe, lower-left to upper-right, built as a filled
    // outline so the width can vary along the sweep.
    // Centreline of the swipe, offset by a width that tapers from thick
    // (loaded brush, lower left) to thin (flicked tip, upper right).
    let a = CGPoint(x: DX + 85, y: 205)
    let c1 = CGPoint(x: DX + 350, y: 640)
    let c2 = CGPoint(x: DX + 460, y: 245)
    let b = CGPoint(x: DX + 730, y: 660)
    func bez(_ t: Double) -> CGPoint {
        let mt = 1 - t
        let x = mt * mt * mt * a.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * b.x
        let y = mt * mt * mt * a.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * b.y
        return CGPoint(x: x, y: y)
    }
    func halfWidth(_ t: Double) -> Double { 116 - 66 * pow(t, 0.9) }
    let steps = 400
    var upper: [CGPoint] = []
    var lower: [CGPoint] = []
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        let p0 = bez(max(0, t - 0.002))
        let p1 = bez(min(1, t + 0.002))
        var nx = -(p1.y - p0.y)
        var ny = p1.x - p0.x
        let len = max(1e-6, (nx * nx + ny * ny).squareRoot())
        nx /= len; ny /= len
        let pt = bez(t)
        let hw = halfWidth(t)
        upper.append(CGPoint(x: pt.x + nx * hw, y: pt.y + ny * hw))
        lower.append(CGPoint(x: pt.x - nx * hw, y: pt.y - ny * hw))
    }
    let p = CGMutablePath()
    p.move(to: upper[0])
    for pt in upper.dropFirst() { p.addLine(to: pt) }
    // rounded tip at the far end
    let tipC = bez(1)
    p.addArc(center: tipC, radius: halfWidth(1),
             startAngle: atan2(upper[steps].y - tipC.y, upper[steps].x - tipC.x),
             endAngle: atan2(lower[steps].y - tipC.y, lower[steps].x - tipC.x),
             clockwise: true)
    for pt in lower.reversed() { p.addLine(to: pt) }
    // rounded butt at the loaded end
    let buttC = bez(0)
    p.addArc(center: buttC, radius: halfWidth(0),
             startAngle: atan2(lower[0].y - buttC.y, lower[0].x - buttC.x),
             endAngle: atan2(upper[0].y - buttC.y, upper[0].x - buttC.x),
             clockwise: true)
    p.closeSubpath()
    c.saveGState()
    c.addPath(p)
    c.clip()
    let g = gradient([(0, hex(0xE0641C)), (0.30, hex(0xF0A028)), (0.55, hex(0xF4EC70)),
                      (0.80, hex(0x6CD860)), (1, hex(0x84E0F0))])
    c.drawLinearGradient(g, start: CGPoint(x: a.x, y: a.y - 60), end: CGPoint(x: b.x, y: b.y + 60), options: [])
    c.restoreGState()
}

// MARK: - canvas motif (framed picture on an easel-ish canvas — alt dogfood)

func drawCanvasMotif(_ c: CGContext) {
    // Bold "画" of a scene inside a white canvas frame, square design
    c.setFillColor(hex(0x14123C))
    c.fill(CGRect(x: 0, y: 0, width: Double(W), height: Double(H)))
    let g = gradient([(0, hex(0x2E2C9B)), (1, hex(0x0A0920))])
    c.saveGState()
    c.drawRadialGradient(g, startCenter: CGPoint(x: DX + 400, y: 400), startRadius: 0,
                         endCenter: CGPoint(x: DX + 400, y: 400), endRadius: 620,
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
    // canvas
    let frame = CGRect(x: DX + 110, y: 150, width: 580, height: 500)
    c.setFillColor(hex(0xFFF8E0))
    c.fill(frame)
    let inner = frame.insetBy(dx: 26, dy: 26)
    c.saveGState()
    c.clip(to: inner)
    let sky = gradient([(0, hex(0xFFD070)), (0.5, hex(0xF06A50)), (1, hex(0x3A2A80))])
    c.drawLinearGradient(sky, start: CGPoint(x: 0, y: inner.minY), end: CGPoint(x: 0, y: inner.maxY), options: [])
    c.setFillColor(hex(0x2A5C30))
    let hill = CGMutablePath()
    hill.move(to: CGPoint(x: inner.minX, y: inner.minY))
    hill.addLine(to: CGPoint(x: inner.minX, y: inner.minY + 120))
    hill.addCurve(to: CGPoint(x: inner.maxX, y: inner.minY + 90),
                  control1: CGPoint(x: inner.minX + 180, y: inner.minY + 240),
                  control2: CGPoint(x: inner.maxX - 150, y: inner.minY + 10))
    hill.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
    hill.closeSubpath()
    c.addPath(hill)
    c.fillPath()
    c.restoreGState()
}

let motif = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
let c = ctx()
switch motif {
case "palette": drawPalette(c)
case "sunset": drawSunset(c)
case "swoosh": drawSwoosh(c)
case "canvas": drawCanvasMotif(c)
default: fatalError("unknown motif")
}
write(c, out)
print("wrote \(out)")
