# image64 — C64 Bitmap Image Converter for macOS

**Date:** 2026-08-08
**Status:** Draft for review

## Overview

image64 is a native macOS tool that converts modern images into pictures that
satisfy the Commodore 64's bitmap-mode display constraints. It has two front
ends over one engine: a windowed app — drag an image in, crop it, tweak a few
conversion knobs while watching a live preview — and a command-line tool for
scripted and agent-driven use. Both exports load on real C64 hardware, in
VICE, or via the Project64 toolchain.

### Goals

- Convert any common image format (PNG, JPEG, HEIC, TIFF, GIF, WebP — anything
  ImageIO reads) to C64 hires or multicolor bitmap mode.
- Drag-and-drop input, side-by-side before/after display, interactive crop on
  the source image.
- Live preview that re-converts as settings change.
- Export native C64 file formats plus a modern PNG of the result.
- A CLI (`image64` command) exposing the same conversion and export
  operations, executing the same engine code as the app — the front ends must
  not be able to drift apart.
- An agent skill (`skills/c64-image-conversion/SKILL.md`, following
  Project64's skill conventions) so AI agents can use the CLI effectively;
  its factual claims are tested against the implemented CLI.

### Non-Goals

- No sprite, character-set (PETSCII), FLI/IFLI, or interlace modes.
- No per-cell manual color editing or paint tools — this is a converter, not a
  pixel editor.
- No batch conversion **in the app**. Converting many files is the CLI's job
  — a shell loop over `image64 convert` — and the agent skill documents the
  pattern. The app stays a one-image-at-a-time tool.
- No Undo for crop or slider changes in v1 — Reset plus cheap re-adjustment
  covers it; revisit if users ask.
- No Windows/Linux port; macOS 14+ only.

## Background: C64 Bitmap Mode Constraints

The C64 has a fixed 16-color palette and two bitmap modes:

| | Hires | Multicolor |
|---|---|---|
| Resolution | 320×200 | 160×200 (pixels displayed double-wide) |
| Cell size | 8×8 px | 4×8 px |
| Cell grid | 40×25 | 40×25 |
| Colors per cell | 2, free choice | 4: one screen-wide shared background + 3 per-cell |
| Memory | 8000 B bitmap + 1000 B screen RAM | + 1000 B color RAM + 1 background byte |

Both modes display at 8:5 aspect (320:200), so the crop is always locked to
8:5 regardless of mode.

Palette RGB values come from a selectable palette table: **Colodore**
(default) or **Pepto**. Colodore is the default because its gamma-corrected
values match what people expect C64 colors to look like; Pepto's raw CRT
measurement reads dark and muddy on a modern display (its "red" is brown).
The palette affects both color-matching during conversion and preview
rendering, but not the exported C64 files (which store 4-bit color indices).

## User Experience

### Window layout

A single-window app:

```
┌────────────────────────────────────────────────────────┐
│  toolbar: [mode: Hires|Multicolor]        [Export ▾]   │
├───────────────────────────┬────────────────────────────┤
│                           │                            │
│   BEFORE                  │   AFTER                    │
│   source image with       │   converted preview,       │
│   draggable 8:5 crop      │   pixel-perfect upscale    │
│   rectangle               │                            │
│                           │                            │
├───────────────────────────┴────────────────────────────┤
│  controls: dither [None|Bayer|Floyd–Steinberg]         │
│  brightness ─────○───  contrast ───○────  sat ──○───   │
│  palette [Colodore|Pepto]              [Reset]         │
└────────────────────────────────────────────────────────┘
```

### Flow

1. **Drop / open.** The empty state is a full-window drop target ("Drop an
   image here") that highlights on drag-over. Equal citizens: **File ▸
   Open…** (⌘O), **File ▸ Open Recent**, paste (⌘V), dropping a file onto
   the app's Dock icon, and Finder "Open With" (the app bundle registers
   `public.image` document types). Dropping or opening a new image replaces
   the current one (no confirmation — nothing destructive is lost). The
   window title shows the source filename.
2. **Crop.** The before pane shows the source with an overlaid crop rectangle,
   aspect-locked to 8:5. Corner/edge handles resize it; dragging inside moves
   it. Initial crop is the largest centered 8:5 rect. Double-click resets it.
3. **Convert.** Every change (crop, mode, dither, sliders, palette) triggers a
   re-conversion off the main thread, debounced at ~100 ms. The after pane
   updates when it completes; conversion of a full frame must stay well under
   one second on Apple Silicon.
4. **Export.** Menu-bar commands **File ▸ Export C64 File…** (⌘E) and
   **File ▸ Export PNG…** (⇧⌘E), duplicated by a toolbar menu:
   - **C64 file** — Koala (.koa) when in multicolor mode, Art Studio (.art)
     when in hires mode.
   - **PNG** — the converted image upscaled ×2 (multicolor pixels rendered
     double-wide), i.e. always 640×400.
   Both use a standard save panel with a filename derived from the source.

Every control carries an accessibility label; the app is fully operable
with VoiceOver except the crop rectangle (whose result is always reachable
by leaving the default crop and using the CLI's `--crop` instead).

### Controls (v1 scope)

- **Mode:** Hires / Multicolor segmented control (default Multicolor).
- **Dither:** None / Ordered (Bayer 4×4) / Floyd–Steinberg (default).
- **Brightness, Contrast, Saturation:** −1…+1 sliders, default 0, applied to
  the cropped image before quantization.
- **Palette:** Colodore (default) / Pepto.
- **Reset:** returns all controls to defaults (does not touch the crop).

No per-color locking, manual background selection, or dither-strength control
in v1; the settings model is designed so these can be added later.

## Architecture

Swift 5.10+, SwiftUI, macOS 14+. One engine, two thin front ends (app and
CLI), with strict boundaries:

### `C64Kit` (pure conversion engine — no UI imports)

A local Swift package, fully unit-testable:

- **`C64Palette`** — the 16 colors as linear-RGB values for Colodore and
  Pepto; nearest-color lookup.
- **`ConversionSettings`** — value type: mode, dither, brightness, contrast,
  saturation, palette.
- **`C64Converter`** — `convert(_ image: CGImage, settings:) -> C64Image`.
  Input is the already-cropped source; the converter owns resize, adjust,
  quantize, and cell-constraint enforcement (pipeline below).
- **`C64Image`** — the result: `bitmap: [UInt8]` (8000), `screenRAM: [UInt8]`
  (1000), `colorRAM: [UInt8]` (1000, multicolor only), `background: UInt8`
  (multicolor only), plus `render(palette:) -> CGImage` producing the
  pixel-accurate preview from those bytes — the preview is generated from the
  exported data, never from an intermediate, so what you see is exactly what
  the C64 will show.
- **`C64FileWriter`** — serializes a `C64Image` to Koala or Art Studio bytes.
- **`ConversionOperation`** — the shared front-end entry point: load an image
  file, apply a crop rect (or the largest centered 8:5 default), run
  `C64Converter`, and write the requested output files. **Both front ends
  call this and nothing else** — the app adds interactivity around it and the
  CLI adds argument parsing, but the code that executes a conversion is the
  same in both. New operations go here, never in a front end.

### App layer (SwiftUI)

- **`AppModel`** (`@Observable`) — source image, crop rect, settings, latest
  `C64Image`, conversion-in-progress flag. Owns a debounced conversion task
  (each new request cancels the pending one).
- **Views:** `DropView` (empty state + drop handling on the whole window),
  `CropView` (source display + crop overlay with handle hit-testing),
  `PreviewView` (nearest-neighbor-interpolated result), `ControlsView`,
  `ExportMenu`.

**App bundle.** `swift run Image64App` is the developer loop, but a bare
SwiftPM executable is not a Mac app: no menu-bar name, no Dock icon, no
document types. `scripts/make-app.sh` wraps the release binary in a minimal
`image64.app` (Info.plist with `CFBundleName`, `CFBundleIdentifier`,
`CFBundleDocumentTypes` for `public.image` as a viewer, `LSMinimumSystemVersion`
14.0) so Finder launch, Dock drops, and "Open With" behave like a Mac app.
File-open events are handled via an `NSApplicationDelegateAdaptor`
implementing `application(_:open:)`.

### CLI layer (`image64` executable)

A second thin front end (swift-argument-parser is the one permitted
dependency), for scripts and AI agents. It parses arguments into the same
`ConversionSettings` + crop rect the app produces and hands them to
`ConversionOperation` — no conversion logic of its own:

    image64 convert photo.jpg -o picture.koa       # multicolor (inferred from .koa)
    image64 convert photo.jpg -o picture.art       # hires (inferred from .art)
    image64 convert photo.jpg -o out.koa --png out.png \
        --crop 120,80,1600,1000 --dither bayer --palette colodore \
        --brightness 0.1 --contrast 0.2 --saturation -0.1

- `--mode hires|multicolor` overrides the extension inference.
- `--crop x,y,w,h` in source pixels; snapped to 8:5 (error if impossible);
  default is the largest centered 8:5 rect — identical to the app's default.
- Defaults for every option match the app's defaults exactly.
- `--json` prints a machine-readable result (output paths, mode, background
  color index, palette) — the intended agent interface, following Project64's
  convention.
- Existing output files are overwritten without prompting (standard Unix
  behavior; scripts depend on it).
- Exit 1 with an actionable message on unreadable input or unwritable output.
- Batch conversion is a shell loop — documented in the README and the agent
  skill:

      for f in art/*.png; do
          image64 convert "$f" -o "out/$(basename "${f%.*}").koa"
      done

### Agent skill (`skills/c64-image-conversion/SKILL.md`)

A skill in Project64's format (YAML frontmatter with `name` and a
"Use when…" `description`, then a practical body) teaching an AI agent to
convert images with the `image64` CLI:

- How to find or build the binary (`swift build -c release` →
  `.build/release/image64`).
- The `convert` command surface with every option, defaults, and the exact
  `--json` output shape.
- Guidance an agent can act on: multicolor for photographs, hires for line
  art and text; crop before converting rather than letting the centered
  default guess; what the background-color index in the JSON means.
- The verification loop: display the exported file on an emulated C64 via
  the neighboring Project64 toolset (`c64 session start`, `c64 run out.koa`,
  `c64 screen`).

Like Project64, the skill's documentation is tested: a test asserts that the
options documented in SKILL.md and the options reported by
`image64 convert --help` match bidirectionally, so the skill cannot drift
from the CLI.

## Conversion Pipeline

Given the cropped `CGImage` and settings:

1. **Resize** to 320×200 (hires) or 160×200 (multicolor) using Lanczos
   (Core Image `CILanczosScaleTransform`) — high-quality downsampling matters
   more than speed here.
2. **Adjust** brightness/contrast/saturation (Core Image `CIColorControls`),
   then read back as an sRGB byte buffer.
3. **Quantize + dither** every pixel to the 16-color C64 palette. Nearest
   color is chosen by weighted-RGB distance (perceptual weights 0.299/0.587/
   0.114 on linearized values — cheap and good enough for a 16-color target).
   Floyd–Steinberg diffuses quantization error serpentine-scan; Bayer applies
   a 4×4 threshold matrix before nearest-color lookup; None is plain nearest.
4. **Enforce cell constraints** (the C64-specific step):
   - **Hires:** for each 8×8 cell, count color frequencies; keep the top 2;
     remap every other pixel in the cell to whichever of the two is nearest.
   - **Multicolor:** first pick the shared background color = the palette
     color that, if made the background, minimizes total remapping error
     across the whole image (approximated as the globally most frequent
     color). Then for each 4×8 cell, keep the background plus the cell's top
     3 remaining colors; remap the rest to nearest-of-four.
   - This two-pass approach (global dither, then per-cell reduction) is the
     standard C64 converter design. The alternative — solving dithering and
     cell constraints jointly per cell — produces marginally better output at
     substantially higher complexity and runtime, and is explicitly out of
     scope for v1.
5. **Pack** the constrained pixel indices into `C64Image` bytes: bitmap bit
   pairs/bits in the C64's cell-interleaved layout, cell colors into screen
   RAM nibbles (and color RAM low nibbles for multicolor).

The whole pipeline runs on a background task; steps 3–5 are plain Swift over
byte buffers (≈64 K pixels — comfortably fast without SIMD heroics).

## Export File Formats

- **Koala (.koa)** — multicolor. 10003 bytes: 2-byte load address `$6000`,
  8000-byte bitmap, 1000-byte screen RAM, 1000-byte color RAM, 1 background
  byte.
- **Art Studio (.art)** — hires. 9009 bytes: 2-byte load address `$2000`,
  8000-byte bitmap, 1000-byte screen RAM, 7 padding bytes (zero).
- **PNG** — 640×400 rendering of `C64Image` via ImageIO.

## Error Handling

- Unreadable/unsupported dropped file → inline alert, keep current state.
- Extremely large sources (> 16K px per side) → downscale to a working copy
  before display; conversion quality is unaffected since output is ≤ 320×200.
- Conversion cancellation (settings changed mid-run) is normal flow, not an
  error; the newest request always wins.
- Export write failures → standard `NSError` alert from the save panel flow.

## Testing

- **Unit tests on `C64Kit`** (the bulk of the value):
  - Invariants: every hires cell ≤ 2 distinct colors; every multicolor cell ≤
    background + 3; bitmap/screen/color arrays exactly sized.
  - Round-trip: pack then `render()` then re-analyze yields identical cell
    colors.
  - File writer: exact byte lengths, load addresses, and layout offsets for
    both formats.
  - Golden tests: a small set of reference images converted with fixed
    settings, compared against committed expected outputs.
- **CLI tests:** run the built `image64` binary end-to-end on fixture images —
  argument parsing, extension inference, crop snapping errors, `--json`
  shape, and byte-identical output to a direct `ConversionOperation` call
  with the same parameters (the lockstep guarantee, asserted).
- **Verification on target:** load an exported .koa in VICE via the Project64
  `c64` CLI as a manual acceptance check.
- App-layer logic (debounce, crop math) tested where practical; no UI
  snapshot testing in v1.

## Milestones

1. `C64Kit`: palette, quantization, cell enforcement, packing, file writers,
   `ConversionOperation` — with the full unit-test suite.
2. CLI: the `image64 convert` command over `ConversionOperation`, with its
   end-to-end tests, plus the `c64-image-conversion` agent skill and its
   doc-accuracy test. (Also the acceptance vehicle: exports verifiable in
   VICE before any UI exists.)
3. App shell: window, drag-and-drop, before/after panes, async conversion.
4. Crop overlay interaction.
5. Controls + live re-conversion + export, File menu with Open/Export
   commands and shortcuts, accessibility labels.
6. App bundle packaging (`scripts/make-app.sh`, document types, Dock drops).
7. Golden-image polish pass: tune dithering defaults against real photos,
   verify in VICE.
