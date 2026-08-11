# App icon

`AppIcon.icns` is the icon `scripts/make-app.sh` copies into
`image64.app/Contents/Resources/`. Every C64-looking pixel in it is real output
of image64's own converter — the icon is a Commodore 64 multicolour picture, not
a hand-drawn imitation of one.

| File | What it is |
| --- | --- |
| `AppIcon.icns` | The shipped icon. Build input, not generated at build time. |
| `AppIcon-1024.png` | The 1024×1024 master every iconset size comes from. |
| `src/palette-motif-1280x800.png` | The smooth, modern source image fed to the converter. |
| `tools/draw-motif.swift` | Draws that source motif (and the three unused alternates). |
| `tools/compose-master.swift` | Crops/upscales converter output into the 1024 master. |
| `tools/make-iconset.swift` | Master → `AppIcon.iconset`, plus inspection sheets. |

## The picture

A painter's palette with five paint blobs and a brush, on a flat field of
colodore palette blue (`#2E2C9B`, C64 colour 6 — see
`Sources/C64Kit/C64Palette.swift`). The field is part of the *source* image, so
it converts to exactly that palette entry: the background and the subject are
the same C64 pixels, not artwork pasted onto a coloured rectangle.

Geometry: 1024×1024 canvas, an 800×800 content square at offset 112, corner
radius 180 (the Big Sur rounded-rect proportion), transparent outside. 800
matters — it is 200 hires pixels at exactly ×4, so the C64 pixel grid lands on
integer boundaries and no resampling ever touches it. Conversion used
`--dither none` deliberately: the flat-colour render reads as an icon where
Floyd–Steinberg speckle turns to mud below 64 px, and it is still a genuine
multicolour picture.

## Regenerating

Needs the release CLI (`swift build -c release`, binary at
`.build/arm64-apple-macosx/release/image64`) and full Xcode's toolchain for
`swiftc` (`export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer`).

```sh
cd assets/icon
swiftc -O tools/draw-motif.swift     -o /tmp/drawtool
swiftc -O tools/compose-master.swift -o /tmp/composetool
swiftc -O tools/make-iconset.swift   -o /tmp/iconsettool

# 1. smooth 1280x800 source motif (= 4x the 320x200 hires grid, so no crop
#    is implied and the converter sees an ordinary modern image)
/tmp/drawtool palette src/palette-motif-1280x800.png

# 2. convert it for real. `--png` alone is rejected, hence the .koa alongside.
../../.build/arm64-apple-macosx/release/image64 convert \
    src/palette-motif-1280x800.png -o /tmp/icon.koa \
    --png /tmp/icon-render.png --dither none

# 3. crop the central 200x200 hires square out of the 640x400 render and blit
#    it at x4 into the 1024 canvas
/tmp/composetool square /tmp/icon-render.png 60 0 200 AppIcon-1024.png

# 4. iconset + icns
/tmp/iconsettool iconset AppIcon-1024.png /tmp/AppIcon.iconset
iconutil -c icns /tmp/AppIcon.iconset -o AppIcon.icns
```

The intermediate `.iconset` is not committed — `iconutil` reads it, the `.icns`
is the artifact. `compose-master.swift verify AppIcon-1024.png 4 <x0 y0 x1 y1>`
re-checks that the pixel grid survived (see below).

## Downscale: nearest above 128 px, area average below

`make-iconset.swift` does not use `sips` or Image I/O's default resampling.
Smoothing filters turn a 4×4 block of one C64 colour into a gradient, and that
read is the first thing an icon like this can lose. But point sampling is just
as wrong at the small end. So the downscale switches method at a crossover
(`--nn-min`, default **128**):

| Size | Method | Why |
| --- | --- | --- |
| 1024 | master verbatim | |
| 512, 256 | nearest | Provably lossless: 2×2 and 4×4 blocks nest inside the master's uniform 4×4 hires pixels. Measured — nearest and area differ on **0** fully-opaque pixels at both sizes, only on the antialiased corner arc, and a ×5 crop of that arc shows no visible difference. |
| 128 | nearest | One output pixel = one multicolour pixel wide, but two hires *rows* tall, so area averaging starts altering the artwork here (569 fully-opaque pixels differ). Nearest keeps the pixel blocks; the cost is a ~1 px stair-step on the corner curve, invisible at actual size. |
| 64, 32, 16 | area average | One output pixel covers 8+ C64 pixels and point sampling picks one arbitrarily. At 64 px nearest visibly breaks the palette rim and ragged-edges the silhouette; at 32 the silhouette is badly jagged; at 16 it collapses into noise. Area keeps the rim continuous, the brush diagonal legible and the squircle smooth. |

Both methods are exact integer-factor operations on a 1024 master — no filter
kernels, no rounding choices, so the output is byte-identical on any machine.

Two things worth knowing if you revisit this:

- **The 16/32 px soft edge is geometric, not a bug.** The content square's
  edges (offset 112, side 800) land on half-pixel boundaries at 16 px
  (112/64 = 1.75) and 32 px (112/32 = 3.5), so an honest area average makes
  those edge pixels partly transparent — it reads as antialiasing. Aligning
  them would mean a 768 px content square, which is *not* an integer multiple
  of the 200-hires-pixel crop (768/200 = 3.84) and would break the "no
  resampling touches a C64 pixel" invariant. The soft edge is the cheaper
  trade.
- **`iconutil` re-encodes 16 and 32.** Those go into the icns `ic04`/`ic05`
  ARGB slots rather than PNG ones, so a round-trip is not byte-identical.
  Verified harmless: alpha and every fully-opaque pixel survive exactly, and
  the only pixels that move are translucent ones, which come back up to ~50/255
  brighter (a straight/premultiplied disagreement in `iconutil`'s ARGB
  encoder). It touches the 1 px antialiased edge and nothing else. All ten
  slots are present: `ic04 ic05 ic07 ic08 ic09 ic10 ic11 ic12 ic13 ic14`.
- **macOS 26 restyles legacy `.icns` icons.** Verified by rasterizing
  `NSWorkspace.icon(forFile:)`: in dark appearance the system strips the flat
  background field and composites the foreground onto its own dark backdrop —
  it does the same thing to Apple's own icons (Podcasts' purple field and
  Calculator's body get identical treatment). So on 26 the C64 palette-blue
  field is the system's to override; the palette and brush are what always
  survive. Controlling that would mean shipping a layered Icon Composer
  `.icon` asset instead, which is a follow-up, not v1.

## Looking at the result

```sh
/tmp/iconsettool sheet AppIcon-1024.png /tmp/sheet.png   # both methods, 16-128, light+dark
/tmp/iconsettool zoom  AppIcon-1024.png /tmp/z32.png 32 14   # one size, magnified
```

Judge the small sizes from these, not from the 1024 master — the master looks
good no matter what the downscale does.
