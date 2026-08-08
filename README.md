# image64

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE.md)
![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-orange.svg)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)
![Built with AI](https://img.shields.io/badge/built%20with-AI-green.svg)

image64 is a native macOS tool that converts modern images into pictures that
satisfy the Commodore 64's bitmap-mode display constraints. It is both a
windowed app — drag an image in, crop it, watch the live C64 preview — and an
`image64` command-line tool for scripted use; the two front ends execute the
same engine code, and exports load on real hardware or in the VICE emulator.

It is a companion to [Project64](../Project64), the agentic C64 development
toolset; exported images drop straight into that workflow.

## What it does

- **Drag and drop** any image macOS can read (PNG, JPEG, HEIC, TIFF, GIF,
  WebP, …), or open/paste one.
- **Crop** the source with an interactive rectangle locked to the C64's 8:5
  display aspect.
- **Convert** to either bitmap mode, side by side with the original:

  | | Hires | Multicolor |
  |---|---|---|
  | Resolution | 320×200 | 160×200 (double-wide pixels) |
  | Colors per cell | 2 of 16, per 8×8 cell | shared background + 3 of 16, per 4×8 cell |

- **Tune** the result with live-updating controls: dithering (Floyd–Steinberg,
  ordered Bayer, or none), brightness / contrast / saturation, and palette
  (Colodore or Pepto).
- **Export** native C64 files — Koala (`.koa`) for multicolor, Art Studio
  (`.art`) for hires — plus a modern PNG of the converted image. The preview
  is rendered from the exact bytes that get exported, so what you see is what
  the C64 shows.
- **Script it** with the CLI, which runs the identical conversion code:

      image64 convert photo.jpg -o picture.koa            # multicolor, from .koa
      image64 convert photo.jpg -o picture.art            # hires, from .art
      image64 convert photo.jpg -o out.koa --dither bayer --palette colodore

  Every command takes `--json` for machine-readable output — the intended
  interface for AI agents, as in [Project64](../Project64). Outputs
  overwrite without prompting, so a shell loop batch-converts a directory:

      for f in art/*.png; do
          image64 convert "$f" -o "out/$(basename "${f%.*}").koa"
      done

  AI agents get a doc-tested skill covering the full CLI surface and the
  VICE verification loop: `skills/c64-image-conversion/SKILL.md`.

## Status

**In development.** The design and implementation plan are complete; the
code is being built task-by-task, tests first. No releases yet.

## Building

Requires Xcode 16+ (or its command-line tools) on macOS 14+.

    git clone https://github.com/nschneir/image64.git
    cd image64
    swift build                # engine + CLI + app
    swift test                 # full test suite
    swift run Image64App       # launch the app
    scripts/make-app.sh        # package dist/image64.app (unsigned, local use)

One SwiftPM package, three targets — open `Package.swift` in Xcode if you
prefer an IDE. The conversion engine is `C64Kit`, a UI-free library target
with its own test suite; the app and the `image64` CLI are thin front ends
over it.

## Trying the output

Exported files load anywhere C64 software runs. With
[VICE](https://vice-emu.sourceforge.io/) installed:

    x64sc picture.koa

or, using [Project64](../Project64)'s CLI:

    c64 session start
    c64 run picture.koa

## AI Disclosure

image64 is developed primarily by AI — Anthropic's Claude, working through
Claude Code — under human direction: a human sets the goals, reviews the
designs and plans, and approves the work; the AI writes the specs, plans,
code, tests, and documentation.

## License

MIT license. See [LICENSE.md](LICENSE.md).
