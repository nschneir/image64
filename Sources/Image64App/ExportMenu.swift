import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import C64Kit

// MARK: - Content types
//
// `.koa` and `.art` are not registered system-wide, so `UTType.png`-style
// constants do not exist for them. `UTType(filenameExtension:)` synthesizes a
// dynamic type from the suffix, which is exactly what `NSSavePanel` needs to
// pin the extension in the panel's name field. The force-unwrap is safe:
// `UTType(filenameExtension:)` only returns nil for an empty string on
// macOS 14+, and these literals are non-empty.
private let koaType = UTType(filenameExtension: "koa")!
private let artType = UTType(filenameExtension: "art")!
private let prgType = UTType(filenameExtension: "prg")!

// MARK: - Format routing

/// The one file format that carries pictures in `mode`.
///
/// Written as an exhaustive switch rather than a table lookup so the compiler
/// forces this function to be revisited if `BitmapMode` ever grows a new case.
private func format(for mode: BitmapMode) -> C64FileFormat {
    switch mode {
    case .multicolor: return .koala
    case .hires: return .artStudio
    }
}

@MainActor
private func defaultName(model: AppModel, ext: String) -> String {
    let stem = model.sourceURL?.deletingPathExtension().lastPathComponent ?? "image"
    return "\(stem).\(ext)"
}

// MARK: - Export actions

/// Saves the last-converted picture as its native C64 file (`.koa` or `.art`).
///
/// The format is derived from `converted.mode`, not `model.settings.mode`: the
/// user may have flipped the mode toggle after the last conversion completed,
/// and writing a `.koa` header onto hires bytes (or vice versa) produces a file
/// that loads as garbage on real hardware. Whatever the preview is showing is
/// what gets written.
@MainActor
func exportC64File(model: AppModel) {
    guard let converted = model.converted else { return }
    let format = format(for: converted.mode)
    let panel = NSSavePanel()
    panel.allowedContentTypes = [format == .koala ? koaType : artType]
    panel.nameFieldStringValue = defaultName(model: model, ext: format.rawValue)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        let data = try C64FileWriter.data(for: converted, format: format)
        try data.write(to: url)
    } catch {
        NSAlert(error: error).runModal()
    }
}

/// Saves the last-converted picture as a runnable `.prg` — the same
/// self-displaying program `ViceLauncher` shows, written where the user asks.
///
/// Derived from `converted` for the same staleness reason as the C64 export:
/// the program must display the picture the preview is showing.
@MainActor
func exportPRG(model: AppModel) {
    guard let converted = model.converted else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [prgType]
    panel.nameFieldStringValue = defaultName(model: model, ext: "prg")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        try C64PrgWriter.data(for: converted).write(to: url)
    } catch {
        NSAlert(error: error).runModal()
    }
}

// MARK: - Toolbar button

/// The single toolbar action: export the converted picture as a C64 file.
///
/// This was a `Menu` with a second "Export PNG…" item. PNG export is a
/// verification aid — useful when eyeballing the converter's output against a
/// reference, not something the app's audience wants — so it now lives only in
/// the CLI. With one item left, a dropdown is strictly worse than a button:
/// it costs an extra click and hides the only thing it can do. Hence a plain
/// toolbar `Button`.
///
/// The type keeps the name `ExportMenu` because `Image64App.swift` refers to
/// it, and no `.keyboardShortcut` is attached here on purpose: ⌘E is declared
/// once in the File menu wiring, which is the single source of truth.
/// Duplicating it on the toolbar button makes SwiftUI warn about conflicting
/// shortcut registrations and ties the shortcut to whichever view happens to
/// be realized.
struct ExportMenu: View {
    let model: AppModel

    var body: some View {
        Button {
            exportC64File(model: model)
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(model.converted == nil)
    }
}
