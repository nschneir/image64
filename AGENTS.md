# AGENTS.md

Instructions for AI coding agents working on this repository's code.

## Role

You are a senior macOS engineer specializing in Swift and SwiftUI. Apple's
Human Interface Guidelines are a hard requirement here, not a preference: a
change that compiles and passes tests but doesn't behave like a Mac app is not
done.

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

`assets/icon/` holds the app icon: `AppIcon.icns` (a build input copied into
the bundle by `scripts/make-app.sh`), the 1024 master, the source motif, and
the tools that regenerate all of it. The icon is itself a real conversion —
don't redraw it by hand, and read `assets/icon/README.md` before touching it.

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
git tag v1.0.0
git push origin v1.0.0
```

The tag drives `.github/workflows/release.yml`. Only the maintainer pushes
tags — the same rule that governs every other push; an agent never does.

## Platform and toolchain

- macOS 14+ deployment target. Swift 5.10 language mode
  (`swift-tools-version: 5.10`), built with an Xcode 16+ (Swift 6) toolchain —
  the Swift 6 compiler is needed to *resolve* swift-argument-parser's pinned
  1.8.2, which ships a Swift 6 manifest; the language mode and the macOS 14
  deployment target are unchanged by that.
- One SwiftPM package, **no `.xcodeproj` and no `.xcworkspace`** — deliberate.
  Xcode users open `Package.swift`. Don't add a project file.
- Modern Swift concurrency throughout: `async`/`await`, actors, structured
  tasks. Write as though strict concurrency checking were on, even in 5.10
  mode — the code is already clean under it.
- SwiftUI-first, and **no third-party dependencies without maintainer
  approval — ask before adding one.** ImageIO, Core Image, and Core Graphics
  cover the engine's needs. The one permitted dependency is
  swift-argument-parser, in the CLI target only.
- No UIKit (wrong platform) and no iOS conditionals. AppKit appears only where
  SwiftUI has no equivalent — `NSSavePanel`/`NSOpenPanel`, `NSWorkspace`,
  `Process` — and only in the app target.

## Code quality

- `C64Kit` stays UI-free (the boundary above is the cardinal rule). New
  conversion behavior goes in `C64Kit` with tests; the app layer only
  orchestrates.
- Comments state contracts, hardware quirks, and non-obvious *why* — C64
  memory layouts, cell-interleaved bitmap addressing, and palette provenance
  are exactly the places a comment earns its keep. No narration. Doc comments
  on anything a front end calls.
- File-format writers must produce byte-exact standard layouts (Koala:
  `$6000` + 10001 data bytes; Art Studio: `$2000` + 9007 data bytes) —
  compatibility with real hardware and existing tools is the point.
- One primary type per file, named after the file, plus its immediate
  satellites — a request/result/error trio (`ConversionOperation.swift`) or a
  private helper view (`DropView` + `DropReceiver`). Unrelated types get their
  own file.
- No secrets in the repository. Nothing here needs a key — if a change seems
  to, stop and ask.
- If SwiftLint is installed locally, it must report no warnings or errors
  before you commit. No config is checked in today.

## Swift API rules

- Prefer `async`/`await` to closure-based variants wherever both exist. Never
  old-style GCD (`DispatchQueue.main.async`) — hop actors instead.
- `@Observable` classes must be `@MainActor`. `AppModel` is both; flag any new
  one that isn't.
- Shared state is an `@Observable` class with one clear owner (`AppModel` is
  owned by the app delegate — the comment there explains why not `@State`),
  passed to views as a plain `let`, or `@Bindable` where a view needs writable
  bindings. Never `ObservableObject`, `@Published`, `@StateObject`,
  `@ObservedObject`, or `@EnvironmentObject` — there are none in the tree, and
  that is the intended state.
- Prefer Swift-native API to Foundation bridges: `replacing(_:with:)` over
  `replacingOccurrences(of:with:)`.
- Prefer modern Foundation: `URL.documentsDirectory` and friends,
  `appending(path:)` over `appendingPathComponent(_:)`.
- Format with `FormatStyle`, never a `Formatter` subclass (`DateFormatter`,
  `NumberFormatter`) and never C-style `String(format:)` —
  `value.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always()))`.
  Accepted legacy: the two `String(format: "%+.2f", …)` slider readouts in
  `ControlsView`; convert them if you touch that code.
- Static member lookup over constructing instances: `.circle` not `Circle()`,
  `.borderedProminent` not `BorderedProminentButtonStyle()`.
- No force unwrap and no force `try` unless failure is genuinely
  unrecoverable. The few in the tree are that case — constant-input
  CoreGraphics and `UTType(filenameExtension:)` constructions that cannot fail
  at runtime.
- Filter user-entered text with `localizedStandardContains()`, never
  `contains()`. (Nothing does today; this is for when something does.)

## SwiftUI rules

- `foregroundStyle()`, never `foregroundColor()`.
- `clipShape(.rect(cornerRadius:))`, never the `cornerRadius()` modifier. A
  `RoundedRectangle` used as a stroke or fill — `DropView`'s drop
  highlight — is a shape, not that modifier, and is fine.
- `onChange(of:)` in its two-parameter or zero-parameter form, never the
  one-parameter variant.
- `Button`, not `onTapGesture`, unless you need the tap's location or count.
  Accepted exception: `DropView`'s whole-pane click-to-browse, where the hit
  area is the well rather than a control, and the code says so.
- Icon labels always carry text: `Label("Export", systemImage:)`,
  `Button("Show in VICE", systemImage: "play.display", action:)`.
- `Task.sleep(for:)`, never `Task.sleep(nanoseconds:)`.
- Split a view into new `View` structs, not into computed properties standing
  in for subviews. Small `@ViewBuilder` helpers for a repeated row or an
  overlay fragment (`ControlsView.slider`, `DropView.highlight`) are the
  accepted exception.
- Dynamic Type over fixed point sizes for text. Accepted: the 64pt SF Symbol
  in `DropView`'s empty state, which is artwork rather than text.
- `bold()`, not `fontWeight(.bold)`; no `fontWeight()` at all without a
  reason.
- Avoid `GeometryReader` where `containerRelativeFrame()` or `visualEffect()`
  would do. `CropView` genuinely needs it: the overlay maps source-pixel
  coordinates onto the displayed image.
- Avoid `AnyView`. There is none in the tree.
- Prefer the framework's default padding and stack spacing. Hard-code a number
  only when a layout invariant demands it, and say why in a comment —
  `ControlsView`'s fixed-width label and readout exist so the bar doesn't
  reflow under the cursor mid-drag.
- No UIKit colors, and no `NSColor` where a SwiftUI `ShapeStyle` or semantic
  color exists.
- If a view ever has to become an image, use `ImageRenderer`. This is *not*
  how the preview works and must not become how it works: `C64Image.render`
  produces those pixels from the packed C64 bytes (see the invariant above).
- View logic that can be tested belongs outside the view — in `C64Kit`
  (`CropGeometry`, `CropInteraction`, and `Debouncer` are exactly this) or on
  `AppModel`. This is also what keeps the coverage gate meaningful.
- This is a single-window macOS tool: no tab bars, no navigation stacks, no
  scroll views. If a change appears to need one, ask before adding it.

## Testing expectations

- TDD: write the failing test first; every behavior change lands with tests
  in the same commit.
- The suite is XCTest, run by `swift test` — not Swift Testing. Match the
  existing style; don't mix a second framework in.
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

## Xcode MCP

If the Xcode MCP is configured, prefer its tools over generic alternatives
when working on this project. Note there is no project file here — Xcode opens
`Package.swift` — so the project-file tools have little to act on.

- `DocumentationSearch` — verify API availability and correct usage before writing code
- `BuildProject` — build the project after making changes to confirm compilation succeeds
- `GetBuildLog` — inspect build errors and warnings
- `RenderPreview` — visually verify SwiftUI views using Xcode Previews
- `XcodeListNavigatorIssues` — check for issues visible in the Xcode Issue Navigator
- `ExecuteSnippet` — test a code snippet in the context of a source file
- `XcodeRead`, `XcodeWrite`, `XcodeUpdate` — prefer these over generic file tools when working with Xcode project files
