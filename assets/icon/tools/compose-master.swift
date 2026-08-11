// Composes 1024x1024 icon masters from real image64 converter output.
//
// All C64 pixels are upscaled by integer nearest-neighbour into an exact-size
// CGImage first, then drawn 1:1 into the composition context, so no CG
// resampling ever touches them.
//
// macOS icon grid: 1024 canvas, 800x800 content square (x/y 112..912),
// corner radius 180 (the Big Sur rounded-rect proportion, on a grid that
// divides evenly by the C64 pixel scale).

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let CANVAS = 1024
let CONTENT = 800
let ORIGIN = 112.0
let RADIUS = 180.0

struct Bitmap {
    var w: Int
    var h: Int
    var px: [UInt8]  // RGBA8, row-major, top-down

    init(w: Int, h: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)) {
        self.w = w
        self.h = h
        px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            px[i * 4] = fill.0; px[i * 4 + 1] = fill.1
            px[i * 4 + 2] = fill.2; px[i * 4 + 3] = fill.3
        }
    }

    subscript(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        get {
            let i = (y * w + x) * 4
            return (px[i], px[i + 1], px[i + 2], px[i + 3])
        }
        set {
            let i = (y * w + x) * 4
            px[i] = newValue.0; px[i + 1] = newValue.1
            px[i + 2] = newValue.2; px[i + 3] = newValue.3
        }
    }

    func cgImage() -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var data = px
        let provider = CGDataProvider(data: Data(data) as CFData)!
        data = []
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }
}

func loadBitmap(_ path: String) -> Bitmap {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    var bm = Bitmap(w: img.width, h: img.height)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    bm.px.withUnsafeMutableBytes { buf in
        let c = CGContext(data: buf.baseAddress, width: img.width, height: img.height,
                          bitsPerComponent: 8, bytesPerRow: img.width * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .none
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    }
    return bm
}

func writePNG(_ img: CGImage, _ path: String) {
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                             UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
    print("wrote \(path)")
}

/// Nearest-neighbour crop+scale out of a 640x400 render, addressed in hires
/// (320x200) pixel units. Every hires pixel is a 2x2 block in the render, so
/// sampling the block's top-left corner is exact.
func nnFromRender(_ render: Bitmap, cropX: Int, cropY: Int, side: Int, scale: Int) -> Bitmap {
    var out = Bitmap(w: side * scale, h: side * scale)
    for dy in 0..<(side * scale) {
        let sy = min(199, max(0, cropY + dy / scale)) * 2
        for dx in 0..<(side * scale) {
            let sx = min(319, max(0, cropX + dx / scale)) * 2
            out[dx, dy] = render[sx, sy]
        }
    }
    return out
}

/// Nearest-neighbour scale of a whole render by an integer factor (of the
/// 640x400 pixels, i.e. factor 1 keeps the shipped PNG 1:1).
func nnWhole(_ render: Bitmap, scale: Int) -> Bitmap {
    var out = Bitmap(w: render.w * scale, h: render.h * scale)
    for dy in 0..<out.h {
        let sy = dy / scale
        for dx in 0..<out.w {
            out[dx, dy] = render[dx / scale, sy]
        }
    }
    return out
}

func roundedContentPath() -> CGPath {
    CGPath(roundedRect: CGRect(x: ORIGIN, y: ORIGIN, width: Double(CONTENT), height: Double(CONTENT)),
           cornerWidth: RADIUS, cornerHeight: RADIUS, transform: nil)
}

func canvasContext() -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: CANVAS, height: CANVAS, bitsPerComponent: 8,
                      bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return c
}

func rgbColor(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255, alpha: 1)
}

// Colodore palette entries used for icon fields.
let C64_BLUE: UInt32 = 0x2E2C9B        // index 6
let C64_LIGHT_BLUE: UInt32 = 0x706DEB  // index 14
let C64_BLACK: UInt32 = 0x000000

// MARK: - candidate builders

/// Full-bleed square crop of a converted picture, `side` hires px scaled to 800.
func buildSquare(render: String, cropX: Int, cropY: Int, side: Int, out: String) {
    let r = loadBitmap(render)
    precondition(r.w == 640 && r.h == 400, "expected a 640x400 render")
    precondition(CONTENT % side == 0, "side must divide 800")
    let art = nnFromRender(r, cropX: cropX, cropY: cropY, side: side, scale: CONTENT / side)
    let c = canvasContext()
    c.saveGState()
    c.addPath(roundedContentPath())
    c.clip()
    c.draw(art.cgImage(), in: CGRect(x: ORIGIN, y: ORIGIN, width: Double(CONTENT), height: Double(CONTENT)))
    c.restoreGState()
    writePNG(c.makeImage()!, out)
}

/// The whole 320x200 picture on a border-colour field, VICE-style.
func buildLetterbox(render: String, field: UInt32, scale: Int, out: String) {
    let r = loadBitmap(render)
    let art = nnWhole(r, scale: scale)  // 640*scale x 400*scale
    let c = canvasContext()
    c.saveGState()
    c.addPath(roundedContentPath())
    c.clip()
    c.setFillColor(rgbColor(field))
    c.fill(CGRect(x: 0, y: 0, width: Double(CANVAS), height: Double(CANVAS)))
    let x = ORIGIN + (Double(CONTENT) - Double(art.w)) / 2
    let y = ORIGIN + (Double(CONTENT) - Double(art.h)) / 2
    c.draw(art.cgImage(), in: CGRect(x: x, y: y, width: Double(art.w), height: Double(art.h)))
    c.restoreGState()
    writePNG(c.makeImage()!, out)
}

/// The whole picture inside a monitor-style bezel: dark grey shell, classic
/// light-blue border field, converted picture in the middle. Only the picture
/// pixels come from the converter; bezel and field are flat palette colours.
func buildScreen(render: String, out: String) {
    let r = loadBitmap(render)
    let art = nnWhole(r, scale: 1)  // 640x400, the shipped render 1:1
    let c = canvasContext()
    c.saveGState()
    c.addPath(roundedContentPath())
    c.clip()
    // shell
    c.setFillColor(rgbColor(0x3A3A3A))
    c.fill(CGRect(x: 0, y: 0, width: Double(CANVAS), height: Double(CANVAS)))
    // border field: the classic light-blue frame, 40 px around the picture,
    // so the shell takes the rest (a monitor's thicker top and chin).
    let x = ORIGIN + (Double(CONTENT) - 640) / 2
    let y = ORIGIN + (Double(CONTENT) - 400) / 2
    c.setFillColor(rgbColor(C64_LIGHT_BLUE))
    c.fill(CGRect(x: x - 40, y: y - 40, width: 720, height: 480))
    c.draw(art.cgImage(), in: CGRect(x: x, y: y, width: 640, height: 400))
    c.restoreGState()
    writePNG(c.makeImage()!, out)
}

/// Half modern source / half converted, split down the middle of a square crop.
func buildSplit(source: String, render: String, cropX: Int, cropY: Int, side: Int,
                divider: Bool, out: String) {
    let r = loadBitmap(render)
    let scale = CONTENT / side
    let art = nnFromRender(r, cropX: cropX, cropY: cropY, side: side, scale: scale)
    let srcImg = CGImageSourceCreateImageAtIndex(
        CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil)!, 0, nil)!
    // The source is 4x the hires grid (1280x800 -> 320x200).
    let srcRect = CGRect(x: Double(cropX * 4), y: Double(cropY * 4),
                         width: Double(side * 4), height: Double(side * 4))
    let cropped = srcImg.cropping(to: srcRect)!

    let c = canvasContext()
    c.saveGState()
    c.addPath(roundedContentPath())
    c.clip()
    // right half: converted pixels
    c.saveGState()
    c.clip(to: CGRect(x: ORIGIN + Double(CONTENT) / 2, y: ORIGIN,
                      width: Double(CONTENT) / 2, height: Double(CONTENT)))
    c.draw(art.cgImage(), in: CGRect(x: ORIGIN, y: ORIGIN, width: Double(CONTENT), height: Double(CONTENT)))
    c.restoreGState()
    // left half: the smooth original
    c.saveGState()
    c.clip(to: CGRect(x: ORIGIN, y: ORIGIN, width: Double(CONTENT) / 2, height: Double(CONTENT)))
    c.interpolationQuality = .high
    c.draw(cropped, in: CGRect(x: ORIGIN, y: ORIGIN, width: Double(CONTENT), height: Double(CONTENT)))
    c.restoreGState()
    if divider {
        c.setFillColor(rgbColor(0xFFFFFF))
        c.fill(CGRect(x: ORIGIN + Double(CONTENT) / 2 - 4, y: ORIGIN, width: 8, height: Double(CONTENT)))
    }
    c.restoreGState()
    writePNG(c.makeImage()!, out)
}

// MARK: - contact sheet

func label(_ c: CGContext, _ text: String, x: Double, y: Double, size: Double, gray: Double = 0.15) {
    let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    c.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, c)
}

/// Nearest-neighbour downscale (point sampling) — what the pinned iconset
/// recipe will do — then magnified back up with nearest neighbour so the
/// result is inspectable on screen.
func nnDownscale(_ bm: Bitmap, to size: Int) -> Bitmap {
    var out = Bitmap(w: size, h: size)
    let f = bm.w / size
    for y in 0..<size {
        for x in 0..<size {
            out[x, y] = bm[x * f + f / 2, y * f + f / 2]
        }
    }
    return out
}

func nnUp(_ bm: Bitmap, scale: Int) -> Bitmap {
    var out = Bitmap(w: bm.w * scale, h: bm.h * scale)
    for y in 0..<out.h {
        for x in 0..<out.w {
            out[x, y] = bm[x / scale, y / scale]
        }
    }
    return out
}

/// Box-average downscale by an integer factor — what a Lanczos/area resample
/// approximates, and what actually survives at 16/32 px.
func areaDownscale(_ bm: Bitmap, to size: Int) -> Bitmap {
    var out = Bitmap(w: size, h: size)
    let f = bm.w / size
    for y in 0..<size {
        for x in 0..<size {
            var r = 0, g = 0, b = 0, a = 0
            for dy in 0..<f {
                for dx in 0..<f {
                    let p = bm[x * f + dx, y * f + dy]
                    // the master is premultiplied-free RGBA; weight by alpha
                    let al = Int(p.3)
                    r += Int(p.0) * al; g += Int(p.1) * al; b += Int(p.2) * al; a += al
                }
            }
            if a == 0 {
                out[x, y] = (0, 0, 0, 0)
            } else {
                out[x, y] = (UInt8(r / a), UInt8(g / a), UInt8(b / a),
                             UInt8(a / (f * f)))
            }
        }
    }
    return out
}

func buildSheet(candidates: [(String, String)], out: String) {
    let n = candidates.count
    let col = 400.0
    let gap = 24.0
    let leftPad = 210.0
    let topPad = 74.0
    let bigSize = 320.0
    let rowGap = 52.0
    let width = leftPad + Double(n) * col + gap
    let height = topPad + bigSize + rowGap + 3 * (256 + rowGap) + 130 + 90

    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                      bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // A neutral mid grey behind everything: icons must hold up on both light
    // and dark desktops.
    c.setFillColor(CGColor(gray: 0.62, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: width, height: height))

    func rowY(_ fromTop: Double, _ h: Double) -> Double { height - fromTop - h }

    let y1 = rowY(topPad, bigSize)
    let y2 = rowY(topPad + bigSize + rowGap, 256)
    let y3 = rowY(topPad + bigSize + rowGap + (256 + rowGap), 256)
    let y4 = rowY(topPad + bigSize + rowGap + 2 * (256 + rowGap), 256)
    let y5 = rowY(topPad + bigSize + rowGap + 3 * (256 + rowGap), 110)

    label(c, "image64 app icon candidates", x: 40, y: height - 46, size: 32, gray: 0.06)
    label(c, "1024 master", x: 26, y: y1 + bigSize / 2, size: 20, gray: 0.1)
    label(c, "32 px", x: 26, y: y2 + 140, size: 20, gray: 0.1)
    label(c, "(area downscale, x8)", x: 26, y: y2 + 112, size: 14, gray: 0.28)
    label(c, "16 px", x: 26, y: y3 + 140, size: 20, gray: 0.1)
    label(c, "(area downscale, x16)", x: 26, y: y3 + 112, size: 14, gray: 0.28)
    label(c, "16 px", x: 26, y: y4 + 140, size: 20, gray: 0.1)
    label(c, "(nearest downscale —", x: 26, y: y4 + 112, size: 14, gray: 0.28)
    label(c, "the plan's pinned recipe)", x: 26, y: y4 + 90, size: 14, gray: 0.28)
    label(c, "actual size", x: 26, y: y5 + 52, size: 20, gray: 0.1)
    label(c, "32 / 16 area, 32 / 16 nearest", x: 26, y: y5 + 24, size: 13, gray: 0.28)

    for (i, cand) in candidates.enumerated() {
        let (path, name) = cand
        let x = leftPad + Double(i) * col
        let master = loadBitmap(path)
        // 1024 master, drawn down to bigSize with high quality (this row is
        // about composition, not pixel fidelity)
        c.interpolationQuality = .high
        c.draw(master.cgImage(), in: CGRect(x: x, y: y1, width: bigSize, height: bigSize))
        label(c, name, x: x, y: y1 - 32, size: 22, gray: 0.06)

        let a32 = areaDownscale(master, to: 32)
        let a16 = areaDownscale(master, to: 16)
        let n32 = nnDownscale(master, to: 32)
        let n16 = nnDownscale(master, to: 16)
        c.interpolationQuality = .none
        c.draw(nnUp(a32, scale: 8).cgImage(), in: CGRect(x: x, y: y2, width: 256, height: 256))
        c.draw(nnUp(a16, scale: 16).cgImage(), in: CGRect(x: x, y: y3, width: 256, height: 256))
        c.draw(nnUp(n16, scale: 16).cgImage(), in: CGRect(x: x, y: y4, width: 256, height: 256))
        // actual-size strip
        c.draw(a32.cgImage(), in: CGRect(x: x, y: y5 + 60, width: 32, height: 32))
        c.draw(a16.cgImage(), in: CGRect(x: x + 52, y: y5 + 68, width: 16, height: 16))
        c.draw(n32.cgImage(), in: CGRect(x: x + 110, y: y5 + 60, width: 32, height: 32))
        c.draw(n16.cgImage(), in: CGRect(x: x + 162, y: y5 + 68, width: 16, height: 16))
    }
    writePNG(c.makeImage()!, out)
}

// MARK: - CLI

let args = Array(CommandLine.arguments.dropFirst())
switch args[0] {
case "square":
    // square <render.png> <cropX> <cropY> <side> <out.png>
    buildSquare(render: args[1], cropX: Int(args[2])!, cropY: Int(args[3])!,
                side: Int(args[4])!, out: args[5])
case "screen":
    // screen <render.png> <out.png>
    buildScreen(render: args[1], out: args[2])
case "letterbox":
    // letterbox <render.png> <field:blue|lightblue|black> <scale> <out.png>
    let field: UInt32 = args[2] == "lightblue" ? C64_LIGHT_BLUE : (args[2] == "black" ? C64_BLACK : C64_BLUE)
    buildLetterbox(render: args[1], field: field, scale: Int(args[3])!, out: args[4])
case "split":
    // split <source.png> <render.png> <cropX> <cropY> <side> <divider:0|1> <out.png>
    buildSplit(source: args[1], render: args[2], cropX: Int(args[3])!, cropY: Int(args[4])!,
               side: Int(args[5])!, divider: args[6] == "1", out: args[7])
case "sheet":
    // sheet <out.png> <path1> <name1> <path2> <name2> ...
    var cands: [(String, String)] = []
    var i = 2
    while i + 1 < args.count + 1 && i + 1 <= args.count {
        cands.append((args[i], args[i + 1]))
        i += 2
    }
    buildSheet(candidates: cands, out: args[1])
case "verify":
    // verify <candidate.png> <blockSize>: confirm NxN blocks are uniform inside
    // the content square (i.e. nothing smoothed the pixel grid)
    let bm = loadBitmap(args[1])
    let n = Int(args[2])!
    // optional region: x0 y0 x1 y1 (defaults to the whole content square)
    let x0 = args.count > 3 ? Int(args[3])! : Int(ORIGIN)
    let y0 = args.count > 4 ? Int(args[4])! : Int(ORIGIN)
    let x1 = args.count > 5 ? Int(args[5])! : Int(ORIGIN) + CONTENT
    let y1 = args.count > 6 ? Int(args[6])! : Int(ORIGIN) + CONTENT
    var bad = 0
    var y = y0
    while y + n <= y1 {
        var x = x0
        while x + n <= x1 {
            let ref = bm[x, y]
            for dy in 0..<n {
                for dx in 0..<n where bm[x + dx, y + dy] != ref {
                    bad += 1
                }
            }
            x += n
        }
        y += n
    }
    print("non-uniform samples in \(n)x\(n) blocks: \(bad)")
default:
    fatalError("unknown command \(args[0])")
}
