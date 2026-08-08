# AGENTS.md

Instructions for AI coding agents working on this repository's code.

## What this is

image64: a native macOS app (Swift/SwiftUI, macOS 14+) that converts modern
images to Commodore 64 bitmap-mode pictures — hires (320×200, 2 colors per
8×8 cell) and multicolor (160×200, shared background + 3 colors per 4×8
cell) — with drag-and-drop input, interactive 8:5 cropping, live before/after
preview, and export to Koala (`.koa`), Art Studio (`.art`), and PNG.

Where things are documented (don't duplicate them here):

- `README.md` — what the app does, building, trying exports in VICE.
- `docs/superpowers/` — design specs and plans. **Local-only and gitignored**
  (maintainer's checkout); never commit or push anything under it.

## Layout and architecture

Two layers with a strict boundary:

1. **`C64Kit/`** — a local Swift package holding the entire conversion
   engine: palette tables (Pepto/Colodore), quantization + dithering, per-cell
   color-constraint enforcement, C64 byte packing, and file writers. It
   imports no UI frameworks (CoreGraphics/CoreImage are fine; SwiftUI/AppKit
   are not) and is fully unit-testable from the command line.
2. **The app target** — SwiftUI shell: window, drag-and-drop, crop overlay,
   controls, async conversion orchestration, save panels. Keep it thin;
   anything testable without a window belongs in `C64Kit`.

The preview is rendered *from the packed C64 bytes* (`C64Image.render`),
never from an intermediate representation — what the user sees must be
exactly what exports. Preserve that invariant in any change to the pipeline.

## Commands

```sh
swift build --package-path C64Kit      # build the engine
swift test --package-path C64Kit       # engine unit tests — the bulk of the suite
xcodebuild -project image64.xcodeproj -scheme image64 build   # full app build
xcodebuild -project image64.xcodeproj -scheme image64 test    # app-target tests
```

Keep shell invocations in the plain form above: one command, executable
first. Wrapping them — `cd dir && …`, `time …`, loops — defeats the
maintainer's approval allowlist (it matches on the command prefix) and turns
routine commands into approval prompts.

**Everything is validated locally, by decision — do not add CI checks
without asking.** The gate is you, running the affected tests before you
commit; nothing downstream will catch what you skip.

## Code quality

- Swift 5.10+, SwiftUI-first; no third-party dependencies without maintainer
  approval — ImageIO, Core Image, and Core Graphics cover this app's needs.
- `C64Kit` stays UI-free (the boundary above is the cardinal rule). New
  conversion behavior goes in `C64Kit` with tests; the app layer only
  orchestrates.
- Comments state contracts, hardware quirks, and non-obvious *why* — C64
  memory layouts, cell-interleaved bitmap addressing, and palette provenance
  are exactly the places a comment earns its keep. No narration.
- File-format writers must produce byte-exact standard layouts (Koala:
  `$6000` + 10001 data bytes; Art Studio: `$2000` + 9007 data bytes) —
  compatibility with real hardware and existing tools is the point.

## Testing expectations

- TDD: write the failing test first; every behavior change lands with tests
  in the same commit.
- The engine invariants are the non-negotiable suite: every hires cell ≤ 2
  distinct colors; every multicolor cell ≤ background + 3; exact
  bitmap/screen/color array sizes; pack → render → re-analyze round-trips.
- Golden tests pin conversion output: reference images plus expected `.koa`/
  `.art` bytes live under a `Fixtures/` directory (gitignore excepts them).
  Regenerate goldens only when a pipeline change is *intended* to alter
  output, and say so in the commit message.
- Acceptance check for format changes: load an exported file in VICE (the
  neighboring Project64 repo's `c64` CLI makes this scriptable).

## Git

- Commit messages follow `type(scope): summary` style (`feat(engine): …`,
  `fix(crop): …`, `docs(readme): …`).
- Commit locally; do not push unless the maintainer asks.
- `docs/superpowers/` is local-only — never commit or push anything under it.
