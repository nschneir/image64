---
name: c64-image-conversion
description: Use when converting a modern image (PNG, JPEG, HEIC, …) into a Commodore 64 bitmap-mode picture — a Koala (.koa) or Art Studio (.art) file, plus an optional runnable .prg that displays it — using the image64 CLI. Covers mode choice, cropping, dithering, palettes, the --json output, and verifying the result on an emulated C64.
---

## Finding the binary

Build the CLI from the repo root:

```sh
swift build -c release
```

Then invoke it as `.build/release/image64`. If a step below shows a bare `image64` command, prefix it with that path (or put `.build/release` on `PATH` for the session).

Do not substitute another C64 image converter if the build fails. Stop and report the build error to the maintainer. The point of this skill is byte-identical output from this specific tool, so a different converter is not an acceptable fallback.

## Converting

Full synopsis:

```
image64 convert <input> --output <out.koa|out.art> [--prg <out.prg>] [--png <out.png>] [--mode <mode>] [--crop <x,y,w,h>] [--dither <dither>] [--palette <palette>] [--brightness <n>] [--contrast <n>] [--saturation <n>] [--json]
```

Options:

- `--output` (`-o`): where to write the C64 picture. Required unless `--prg` is given — one of the two must be present, so a run that only wants the runnable program can omit this. The extension picks the format: `.koa` = Koala Painter, `.art` = Advanced Art Studio.
- `--prg`: also write a runnable C64 program that displays the picture — a self-contained `.prg` that sets up the VIC-II and shows the image when it is loaded and run. This is the artifact to hand to an emulator or real hardware; a bare `.koa`/`.art` is display data, not a program. Can be passed without `--output` if the program is all you want.
- `--png`: also write a 640×400 PNG rendered from the exact packed C64 bytes. Not a C64 format — it is a verification rendering, for your own eyes and for the golden tests. Worth passing on any conversion you intend to check.
- `--mode`: `hires` or `multicolor`. Optional. The output extension already implies a mode; `--mode` only exists so you can force a mismatch when you want one. See the mode-inference rule below.
- `--crop`: crop rectangle `x,y,w,h` in source pixels, y = 0 at the top. The `h` you type is ignored and recomputed as `round(w × 5 / 8)` so the frame is always the 8:5 shape the C64 needs. Defaults to the largest centred 8:5 rectangle of the source.
- `--dither`: `none`, `bayer`, or `fs`. Default `fs` (Floyd–Steinberg). Controls how quantization error is spread before the palette snap.
- `--palette`: `colodore` or `pepto`. Default `colodore`. The sixteen-colour table used for the snap.
- `--brightness`: −1…1, default 0.0. Applied to the input before quantization.
- `--contrast`: −1…1, default 0.0. Same.
- `--saturation`: −1…1, default 0.0. Same.
- `--json`: print one JSON object describing the conversion to stdout instead of a human summary. Nothing else is printed on stdout.

Mode inference: `.koa` implies multicolor, `.art` implies hires. Pass `--mode` only when you deliberately want to override that; the CLI rejects an impossible pairing (for example `--mode hires -o foo.koa`) with an error rather than quietly writing the wrong file.

Existing output files are overwritten without prompting, so re-running a batch over the same paths is safe.

## Choosing settings

**Multicolor** (`.koa`): 160×200 double-wide pixels. Every 4×8 cell shares one image-wide background colour plus three of the sixteen palette entries picked per cell. Use for photographs, gradients, and anything where colour density inside a region matters more than horizontal resolution.

**Hires** (`.art`): 320×200 pixels. Every 8×8 cell picks two of the sixteen palette entries. Use for line art, text, logos, and dithered duotones — anything where the horizontal edge matters more than colour count.

Cropping: `--crop x,y,w,h` coordinates are in the *source* image's pixels with y=0 at the top. Because the CLI recomputes `h` as `round(w × 5 / 8)` to enforce the 8:5 frame, treat the `h` you pass as a placeholder. Reach for `--crop` when the subject is off-centre; otherwise the default centred 8:5 rectangle is fine.

Dithering:

- `--dither none` — flat graphics, pixel art already at the target palette, sharp logos.
- `--dither fs` — photographs and continuous-tone imagery. Default because it wins most of the time.
- `--dither bayer` — a periodic ordered stipple. Choose it when the picture will be re-encoded downstream and you want a stable pattern that does not drift.

Palette: `--palette colodore` is calibrated from a real C64 and is the default. `--palette pepto` is the community's earlier baseline; use it when matching artwork produced against that table.

Colour adjustments: `--brightness`, `--contrast`, and `--saturation` take a value in −1…1 and are applied before quantization. Start small — ±0.1 to ±0.3 is usually enough. Pushing saturation up modestly often helps multicolor photos survive the sixteen-colour snap.

## Reading --json

With `--json`, the CLI writes exactly one JSON object to stdout and nothing else, so you can pipe stdout straight into a parser.

```json
{
  "input": "/path/to/photo.jpg",
  "outputs": ["/path/to/out.koa", "/path/to/out.png"],
  "mode": "multicolor",
  "palette": "colodore",
  "dither": "fs",
  "background": 6,
  "crop": {"x": 40, "y": 0, "width": 560, "height": 350}
}
```

Keys:

- `input` — the source path that was read.
- `outputs` — every file that was written, in the order they were produced. Includes the C64 output, plus the runnable program when `--prg` was given and the PNG when `--png` was given.
- `mode` — the mode actually used (`multicolor` or `hires`), after any inference from the output extension.
- `palette` — the palette name applied (`colodore` or `pepto`).
- `dither` — the dither strategy applied (`none`, `bayer`, or `fs`).
- `background` — the shared multicolor background as a palette index in 0–15. Absent (or `null`) for hires, because hires has no image-wide colour.
- `crop` — the rectangle that was actually sampled, as `{x, y, width, height}` in source pixels. When `--crop` was passed, this is the height-snapped rectangle, not the `h` you typed; when it was not, this is the centred 8:5 default the tool picked.

## Seeing the result yourself

Always pass `--png` alongside the C64 output and look at the PNG. The PNG is rendered directly from the packed C64 bytes, so it is a faithful preview: if the PNG looks right, the `.koa` or `.art` is right, and if the PNG looks wrong, so is the C64 file. It is a verification rendering rather than a C64 format — 640×400 because that is the display geometry (hires pixels scaled ×2/×2, multicolor ×4/×2), so both modes land on the same canvas in the proportions a C64 would show.

Iterate by rerunning the same command with adjusted `--crop`, `--dither`, `--brightness`, `--contrast`, or `--saturation`, then re-viewing the PNG. Each rerun overwrites the previous outputs, so the loop is cheap.

## Converting many files

Outputs overwrite without prompting, and the tool exits non-zero on a per-invocation failure but does not abort a shell loop for you. A minimal batch:

```sh
for f in art/*.png; do
    image64 convert "$f" -o "out/$(basename "${f%.*}").koa"
done
```

If the loop should stop on the first failure, check `$?` after each call (or run with `set -e`). Add `--png "out/$(basename "${f%.*}").png"` when you want the previewable PNG alongside every C64 file.

## Verifying on a C64

A `.koa` or `.art` is display data, not a program: an emulator cannot run one directly. Convert with `--prg` and verify that instead:

```sh
image64 convert photo.jpg -o picture.koa --prg picture.prg
```

The neighboring Project64 checkout ships a `c64` CLI that automates a VICE session end-to-end. It requires Project64 to be present on disk and VICE to be installed. Because Project64's verbs are bare words rather than options, keep the example in a `text` fence so it does not get read as image64 syntax:

```text
c64 session start
c64 run picture.prg
c64 screen
c64 session stop
```

`c64 run` loads and starts the program on the emulated machine; `c64 screen` captures what the VIC-II is drawing, which is the picture. If you have VICE but not Project64, `x64sc picture.prg` does the same thing by hand.

A quick sanity check without an emulator: the native formats are fixed sizes. A `.koa` file is exactly 10003 bytes ($6000 load address plus 10001 data bytes). A `.art` file is exactly 9009 bytes ($2000 load address plus 9007 data bytes). Anything else is a broken write.
