# AGENTS.md

Instructions for AI coding agents working on this repository's code.

## What this is

image64: a native macOS tool (Swift/SwiftUI, macOS 14+) that converts modern
images to Commodore 64 bitmap-mode pictures — hires (320×200, 2 colors per
8×8 cell) and multicolor (160×200, shared background + 3 colors per 4×8
cell) — with drag-and-drop input, interactive 8:5 cropping, live before/after
preview, and export to Koala (`.koa`), Art Studio (`.art`), and a runnable
`.prg` that displays the picture. Two front ends — the windowed app and the
`image64` CLI — drive the same engine. The CLI additionally writes a
verification PNG (`--png`); the app deliberately does not, PNG being a
check-the-output aid rather than a product of the tool.

Where things are documented (don't duplicate them here):

- `README.md` — what the tool does, building, CLI usage, trying exports in
  VICE.
- `docs/superpowers/` — design specs and plans (committed in this repo).
- `skills/c64-image-conversion/` — agent-facing CLI usage (doc-tested).

## Layout and architecture

One engine, two thin front ends, with strict boundaries:

1. **`Sources/C64Kit/`** — the library target holding the entire conversion
   engine: palette tables (Colodore/Pepto), quantization + dithering, per-cell
   color-constraint enforcement, C64 byte packing, file writers, and
   `ConversionOperation` (load → crop → convert → write, the shared front-end
   entry point). It imports no UI frameworks (CoreGraphics/CoreImage are
   fine; SwiftUI/AppKit are not) and is fully unit-testable from the command
   line.
2. **The app target** — SwiftUI shell: window, drag-and-drop, crop overlay,
   controls, async conversion orchestration, save panels. Keep it thin;
   anything testable without a window belongs in `C64Kit`.
3. **The CLI target** — `image64` executable: argument parsing over
   `ConversionOperation`, every command supporting `--json` (the intended AI
   interface, per Project64's convention).

**App/CLI lockstep is the cardinal rule.** Both front ends execute a command
by calling `ConversionOperation` — never by reimplementing any part of it.
New operations go in `C64Kit` and are surfaced by both front ends; a CLI run
and an app export with the same parameters must produce byte-identical files
(there is a test asserting this — keep it passing).

The preview is rendered *from the packed C64 bytes* (`C64Image.render`),
never from an intermediate representation — what the user sees must be
exactly what exports. Preserve that invariant in any change to the pipeline.

## Commands

```sh
swift build                 # build everything (engine, CLI, app)
swift test                  # full test suite
swift test --filter C64KitTests   # engine tests only
scripts/coverage.sh         # the coverage gate (see Testing expectations)
swift run image64 --help    # the CLI
swift run Image64App        # launch the app
scripts/make-app.sh         # package dist/image64.app (unsigned, local use)
```

Keep shell invocations in the plain form above: one command, executable
first. Wrapping them — `cd dir && …`, `time …`, loops — defeats the
maintainer's approval allowlist (it matches on the command prefix) and turns
routine commands into approval prompts.

**Everything is validated locally, by decision — do not add CI checks
without asking.** The gate is you, running the affected tests before you
commit; nothing downstream will catch what you skip. The maintainer-approved
release workflow below is not a "CI check" in the sense of that rule: it fires
on a tag push (or a manual smoke dispatch), not on your commits or a PR, and it
re-runs `swift test` only to refuse to package a broken build.

### Releases

```sh
# cut a release: workflow zips dist/image64.app and attaches it
git tag v0.1.0
git push origin v0.1.0
```

The tag drives `.github/workflows/release.yml`. Only the maintainer pushes
tags — the same rule that governs every other push; an agent never does.

## Code quality

- Swift 5.10 language mode (`swift-tools-version: 5.10`), built with an
  Xcode 16+ toolchain — the Swift 6 compiler is needed to *resolve*
  swift-argument-parser's pinned version, which ships a Swift 6 manifest; the
  language mode and the macOS 14 deployment target are unchanged by that.
  SwiftUI-first; no third-party dependencies without maintainer
  approval — ImageIO, Core Image, and Core Graphics cover the engine's needs.
  The one permitted dependency is swift-argument-parser, in the CLI target
  only.
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
- `scripts/coverage.sh` must report ≥95% line coverage over C64Kit +
  Image64CLI before merge; Image64App is excluded because SwiftUI view bodies
  don't execute under XCTest — app logic that can be tested lives in C64Kit.
- Acceptance check for format changes: load an exported file in VICE (the
  neighboring Project64 repo's `c64` CLI makes this scriptable).

## Git

- Commit messages follow `type(scope): summary` style (`feat(engine): …`,
  `fix(crop): …`, `docs(readme): …`).
- Commit locally; do not push unless the maintainer asks.
