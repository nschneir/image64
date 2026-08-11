// Builds AppIcon.iconset (and an inspection sheet) from the 1024x1024 icon
// master. See ../README.md for the whole regeneration chain.
//
// Why not sips/Image I/O's default resampling: the master is real image64
// converter output, so its pixels ARE the artwork. Any smoothing filter turns
// a 4x4 block of one C64 colour into a gradient and the "this is a C64
// picture" read is the first thing lost. But pure point sampling is just as
// wrong at the small end, where one output pixel covers 4-8 C64 pixels and
// point sampling picks one of them arbitrarily — thin features (the brush,
// the palette rim) survive or vanish on a coin flip.
//
// So the downscale is split at a crossover size (--nn-min, default 128):
//   >= crossover  nearest neighbour  (integer factors, pixels stay pixels)
//   <  crossover  box average        (every source pixel gets a vote)
// Every step is an exact integer factor of 1024, so both are deterministic:
// no filter kernels, no rounding, byte-identical output on every machine.
//
// Alpha: the master is transparent outside the rounded content square, so the
// box average has to be alpha-weighted or the corners pick up dark fringes.
// Everything here works in *premultiplied* RGBA, where a plain per-channel
// mean is already the correct alpha-weighted average; CGImageDestination
// un-premultiplies on the way into the PNG.
//
// Usage:
//   swiftc -O make-iconset.swift -o iconsettool
//   ./iconsettool iconset <master.png> <out-dir> [--nn-min N]
//   ./iconsettool sheet   <master.png> <out.png> [--nn-min N]

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - bitmap

/// RGBA8, row-major, top-down, **premultiplied**.
struct Bitmap {
    var w: Int
    var h: Int
    var px: [UInt8]

    init(w: Int, h: Int) {
        self.w = w
        self.h = h
        px = [UInt8](repeating: 0, count: w * h * 4)
    }

    subscript(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        get {
            let i = (y * w + x) * 4
            return (px[i], px[i + 1], px[i + 2], px[i + 3])
        }
        set {
            let i = (y * w + x) * 4
            px[i] = newValue.0
            px[i + 1] = newValue.1
            px[i + 2] = newValue.2
            px[i + 3] = newValue.3
        }
    }

    func cgImage() -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
    }
}

func loadBitmap(_ path: String) -> Bitmap {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { fatalError("cannot read \(path)") }
    var bm = Bitmap(w: img.width, h: img.height)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    bm.px.withUnsafeMutableBytes { buf in
        let c = CGContext(
            data: buf.baseAddress, width: img.width, height: img.height,
            bitsPerComponent: 8, bytesPerRow: img.width * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .none
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    }
    return bm
}

func writePNG(_ img: CGImage, _ path: String) {
    let dst = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    guard CGImageDestinationFinalize(dst) else { fatalError("cannot write \(path)") }
}

// MARK: - downscales

/// Point sampling at the centre of each source block. `size` must divide `bm.w`.
func nearestDownscale(_ bm: Bitmap, to size: Int) -> Bitmap {
    precondition(bm.w == bm.h && bm.w % size == 0, "non-integer downscale factor")
    let f = bm.w / size
    var out = Bitmap(w: size, h: size)
    for y in 0..<size {
        for x in 0..<size {
            out[x, y] = bm[x * f + f / 2, y * f + f / 2]
        }
    }
    return out
}

/// Box average over each f x f source block. Correct as a plain per-channel
/// mean because the buffers are premultiplied.
func areaDownscale(_ bm: Bitmap, to size: Int) -> Bitmap {
    precondition(bm.w == bm.h && bm.w % size == 0, "non-integer downscale factor")
    let f = bm.w / size
    let n = f * f
    var out = Bitmap(w: size, h: size)
    for y in 0..<size {
        for x in 0..<size {
            var r = 0, g = 0, b = 0, a = 0
            for dy in 0..<f {
                for dx in 0..<f {
                    let p = bm[x * f + dx, y * f + dy]
                    r += Int(p.0)
                    g += Int(p.1)
                    b += Int(p.2)
                    a += Int(p.3)
                }
            }
            // Round half up so a 50/50 edge does not drift dark.
            out[x, y] = (
                UInt8((r + n / 2) / n), UInt8((g + n / 2) / n),
                UInt8((b + n / 2) / n), UInt8((a + n / 2) / n)
            )
        }
    }
    return out
}

func downscale(_ bm: Bitmap, to size: Int, nnMin: Int) -> Bitmap {
    if size == bm.w { return bm }
    return size >= nnMin ? nearestDownscale(bm, to: size) : areaDownscale(bm, to: size)
}

func magnify(_ bm: Bitmap, _ scale: Int) -> Bitmap {
    var out = Bitmap(w: bm.w * scale, h: bm.h * scale)
    for y in 0..<out.h {
        for x in 0..<out.w {
            out[x, y] = bm[x / scale, y / scale]
        }
    }
    return out
}

// MARK: - iconset

/// The ten entries `iconutil` expects, as (file stem, pixel size). 16pt@1x
/// through 512pt@2x; the duplicated pixel sizes (32, 128 twice, …) are the
/// point/scale pairs macOS asks for by name, not by size.
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func buildIconset(master: String, outDir: String, nnMin: Int) {
    let bm = loadBitmap(master)
    precondition(bm.w == 1024 && bm.h == 1024, "master must be 1024x1024, got \(bm.w)x\(bm.h)")
    try? FileManager.default.removeItem(atPath: outDir)
    try! FileManager.default.createDirectory(
        atPath: outDir, withIntermediateDirectories: true)
    // One downscale per distinct pixel size, reused by both point sizes that
    // want it, so icon_32x32 and icon_16x16@2x are byte-identical (they are
    // the same image at different scale factors — differing would be a bug).
    var cache: [Int: Bitmap] = [:]
    for (stem, size) in entries {
        let img = cache[size] ?? downscale(bm, to: size, nnMin: nnMin)
        cache[size] = img
        writePNG(img.cgImage(), "\(outDir)/\(stem).png")
        let how = size == bm.w ? "master" : (size >= nnMin ? "nearest" : "area")
        print("\(stem).png  \(size)px  \(how)")
    }
}

// MARK: - inspection sheet

func label(_ c: CGContext, _ text: String, x: Double, y: Double, size: Double, gray: Double = 0.15) {
    let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
            gray: gray, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attrs))
    c.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, c)
}

/// Both downscale methods at every small size, magnified back up with point
/// sampling so the actual output pixels are visible, over light and dark so
/// the transparent surround is judged the way the Dock and Finder show it.
func buildSheet(master: String, out: String, nnMin: Int) {
    let bm = loadBitmap(master)
    let sizes = [16, 32, 64, 128]
    let cell = 256.0
    let gap = 18.0
    let leftPad = 150.0
    let topPad = 70.0
    let cols = 4  // nearest/light, nearest/dark, area/light, area/dark
    let w = leftPad + Double(cols) * (cell + gap) + gap
    let h = topPad + Double(sizes.count) * (cell + gap) + gap + 130

    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(
        data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(gray: 0.93, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    // CoreText and CG both draw y-up here; rows are laid out from the top by
    // subtracting, so the sheet reads top-to-bottom as written.
    func rowY(_ i: Int) -> Double { h - topPad - Double(i + 1) * cell - Double(i) * gap }
    func colX(_ i: Int) -> Double { leftPad + Double(i) * (cell + gap) }

    let heads = ["nearest / light", "nearest / dark", "area / light", "area / dark"]
    for (i, t) in heads.enumerated() {
        label(c, t, x: colX(i), y: h - topPad + 22, size: 26)
    }
    label(c, "crossover: nearest >= \(nnMin)px", x: gap, y: h - 34, size: 26, gray: 0.35)

    for (row, size) in sizes.enumerated() {
        let y = rowY(row)
        let chosen = size >= nnMin ? "nearest" : "area"
        label(c, "\(size)px", x: gap, y: y + cell / 2 + 16, size: 34)
        label(c, "→ \(chosen)", x: gap, y: y + cell / 2 - 20, size: 22, gray: 0.4)
        let scale = Int(cell) / size
        for (col, method) in [nearestDownscale, areaDownscale].enumerated() {
            let big = magnify(method(bm, size), scale).cgImage()
            for (half, bg) in [0.98, 0.16].enumerated() {
                let x = colX(col * 2 + half)
                let r = CGRect(x: x, y: y, width: cell, height: cell)
                c.setFillColor(CGColor(gray: bg, alpha: 1))
                c.fill(r)
                c.draw(big, in: r)
                c.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
                c.setLineWidth(1)
                c.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            }
        }
    }

    // Actual-size strip: what the Dock and the menu bar really show.
    var x = leftPad
    let stripY = gap + 40
    for size in sizes {
        for (col, method) in [nearestDownscale, areaDownscale].enumerated() {
            let img = method(bm, size).cgImage()
            c.setFillColor(CGColor(gray: col == 0 ? 0.98 : 0.16, alpha: 1))
            c.fill(CGRect(x: x, y: stripY, width: Double(size), height: Double(size)))
            c.draw(img, in: CGRect(x: x, y: stripY, width: Double(size), height: Double(size)))
            x += Double(size) + 10
        }
        x += 24
    }
    label(c, "actual size (nearest, area) x 16/32/64/128", x: leftPad, y: gap + 8, size: 22, gray: 0.35)

    writePNG(c.makeImage()!, out)
    print("wrote \(out)")
}

/// One size, both methods, at an arbitrary magnification — for settling a
/// crossover argument that the contact sheet only hints at.
func buildZoom(master: String, out: String, size: Int, mag: Int) {
    let bm = loadBitmap(master)
    let cell = Double(size * mag)
    let gap = 20.0
    let w = cell * 2 + gap * 3
    let h = cell + gap * 2 + 44
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(
        data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Mid grey: neither Finder-white nor Dock-dark, so neither method gets a
    // free pass from a background that happens to match the fringe.
    c.setFillColor(CGColor(gray: 0.55, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    for (i, method) in [nearestDownscale, areaDownscale].enumerated() {
        let x = gap + Double(i) * (cell + gap)
        c.draw(
            magnify(method(bm, size), mag).cgImage(),
            in: CGRect(x: x, y: gap + 44, width: cell, height: cell))
        label(
            c, i == 0 ? "\(size)px nearest" : "\(size)px area", x: x, y: gap + 12, size: 30,
            gray: 0.05)
    }
    writePNG(c.makeImage()!, out)
    print("wrote \(out)")
}

// MARK: - main

var args = Array(CommandLine.arguments.dropFirst())
var nnMin = 128
if let i = args.firstIndex(of: "--nn-min"), i + 1 < args.count {
    nnMin = Int(args[i + 1])!
    args.removeSubrange(i...(i + 1))
}

switch args.first {
case "iconset":
    guard args.count == 3 else { fatalError("iconset <master.png> <out-dir>") }
    buildIconset(master: args[1], outDir: args[2], nnMin: nnMin)
case "sheet":
    guard args.count == 3 else { fatalError("sheet <master.png> <out.png>") }
    buildSheet(master: args[1], out: args[2], nnMin: nnMin)
case "zoom":
    guard args.count == 5 else { fatalError("zoom <master.png> <out.png> <size> <mag>") }
    buildZoom(master: args[1], out: args[2], size: Int(args[3])!, mag: Int(args[4])!)
default:
    print(
        """
        usage:
          iconsettool iconset <master.png> <out-dir> [--nn-min N]
          iconsettool sheet   <master.png> <out.png> [--nn-min N]
          iconsettool zoom    <master.png> <out.png> <size> <mag>
        """)
    exit(2)
}
