# image64

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE.md)
![Swift 5.10](https://img.shields.io/badge/Swift-5.10-orange.svg)
![Xcode 16+](https://img.shields.io/badge/Xcode-16%2B-orange.svg)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)
![Built with AI](https://img.shields.io/badge/built%20with-AI-green.svg)

image64 is a native macOS tool that converts modern images into pictures that
satisfy the Commodore 64's bitmap-mode display constraints. It is both a
windowed app — drag an image in, crop it, watch the live C64 preview — and an
`image64` command-line tool for scripted use; the two front ends execute the
same engine code, and exports are the native C64 formats plus a runnable
program that puts the picture on screen on real hardware or in VICE.

It is a companion to [Project64](https://nschneir.github.io/Project64/), the
agentic C64 development toolset; exported images drop straight into that
workflow.

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
  (`.art`) for hires — and a runnable `.prg`, a self-displaying C64 program
  for emulators and real hardware. The preview is rendered from the exact
  bytes that get exported, so what you see is what the C64 shows.
- **Script it** with the CLI, which runs the identical conversion code:

      image64 convert photo.jpg -o picture.koa            # multicolor, from .koa
      image64 convert photo.jpg -o picture.art            # hires, from .art
      image64 convert photo.jpg -o out.koa --dither bayer --palette colodore
      image64 convert photo.jpg -o out.koa --prg out.prg  # + a program that shows it

  Every command takes `--json` for machine-readable output — the intended
  interface for AI agents, as in
  [Project64](https://nschneir.github.io/Project64/). Outputs overwrite
  without prompting, so a shell loop batch-converts a directory:

      for f in art/*.png; do
          image64 convert "$f" -o "out/$(basename "${f%.*}").koa"
      done

  AI agents get a doc-tested skill covering the full CLI surface and the
  VICE verification loop: `skills/c64-image-conversion/SKILL.md`. Its
  self-check step uses `--png`, which renders the packed C64 bytes back out
  as a picture an agent or a golden test can look at (640×400 — the display
  geometry, hires pixels scaled ×2/×2 and multicolor ×4/×2, so both modes
  land on the same canvas with the right proportions rather than a
  half-width-squashed 160×200 buffer). It is a verification rendering, not
  an output format.

## Status

**v1.0.0.** The engine, CLI, and app are all implemented, with a green test
suite behind a 95% line-coverage gate. A pre-built, universal `image64.app` is
attached to the [v1.0.0
release](https://github.com/nschneir/image64/releases/tag/v1.0.0) (see
[Download](#download)); the `image64` CLI comes from a source build (below).

## Building

Building requires **Xcode 16 or newer** (or its command-line tools); running
requires **macOS 14 or newer**. The Xcode 16 floor is a toolchain requirement,
not a language one: this package is `swift-tools-version: 5.10` and stays in the
Swift 5 language mode, but swift-argument-parser's pinned version declares a
Swift 6 manifest, so dependency resolution needs a Swift 6 compiler. The
deployment target is macOS 14 either way.

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

## Download

A zipped `image64.app` is attached to each [GitHub
Release](https://github.com/nschneir/image64/releases) as it is tagged;
[v1.0.0](https://github.com/nschneir/image64/releases/tag/v1.0.0) is the
current one. Unzip, drag to Applications, and — because the bundle is unsigned
and un-notarized in v1 — right-click the app and choose **Open** the first time
to approve it past Gatekeeper.

The bundle is a universal binary (Apple Silicon + Intel) and requires macOS 14
or newer. It contains the app only; the `image64` CLI comes from a source build.

## Trying the output

A `.koa` or `.art` is the standard interchange format for its mode — raw
display data that C64 paint programs and viewers read, not something the
machine can run on its own. To actually *see* a conversion, export the
runnable PRG alongside it. With [VICE](https://vice-emu.sourceforge.io/)
installed:

    image64 convert photo.jpg -o picture.koa --prg picture.prg
    x64sc picture.prg

In the app there is nothing to arrange: **Show in VICE** (⌘R) writes the program
and launches the emulator on it. The command line needs one caveat — VICE's
official macOS app distribution does not put `x64sc` on your `PATH`, so the line
above works only for a shell install (`brew install vice`). With the app
distribution, invoke its launcher script directly:

    /path/to/VICE-GTK3-3.9/bin/x64sc picture.prg

(the `bin/x64sc` script beside `VICE.app`, not the executable inside it — the
script is what sets up the environment the emulator needs). The app finds that
script by itself, which is why its button works with no `PATH` setup at all.

Or, using [Project64](https://nschneir.github.io/Project64/)'s CLI:

    c64 session start
    c64 run picture.prg

## AI Disclosure

image64 is developed primarily by AI — Anthropic's Claude, working through
Claude Code — under human direction: a human sets the goals, reviews the
designs and plans, and approves the work; the AI writes the specs, plans,
code, tests, and documentation.

## Related projects

image64 is one of three Commodore toolsets built the same way — AI-written,
human-directed, and pointed at real hardware behavior rather than an
approximation of it.

- **[Project64](https://nschneir.github.io/Project64/)** — tools, skills, and
  an MCP for agentic Commodore 64 coding and debugging through the VICE
  emulator, driven by a `c64` command-line tool. It is image64's downstream
  neighbor: an exported `.prg` runs with `c64 run picture.prg`.
- **[PET Project](https://nschneir.github.io/PET-Project/)** — the same
  toolset aimed at the Commodore PET, driven by a `pet` command-line tool and
  VICE's `xpet`, covering the PET's own models and its 40/80-column screens.

## License

MIT license. See [LICENSE.md](LICENSE.md).
