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

/// Saves a 640×400 PNG of the last-converted picture.
///
/// The image is rendered through `ConversionOperation.previewImage`, the same
/// entry point the preview view uses, so the PNG is byte-for-byte the pixels
/// the user just saw on screen. Rendering a fresh CGImage from `converted`
/// via a different path would risk drift between "what I see" and "what I get".
@MainActor
func exportPNG(model: AppModel) {
    guard let converted = model.converted else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = defaultName(model: model, ext: "png")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        let image = ConversionOperation.previewImage(for: converted, palette: model.settings.palette)
        try ImageLoading.writePNG(image, to: url)
    } catch {
        NSAlert(error: error).runModal()
    }
}

// MARK: - Toolbar menu

/// Toolbar dropdown that mirrors the File menu's Export items.
///
/// No `.keyboardShortcut` is attached here on purpose: the shortcuts for both
/// export actions are declared once in the File menu wiring in
/// `Image64App.swift`, which is the single source of truth. Duplicating them
/// on the toolbar buttons causes SwiftUI to warn about conflicting shortcut
/// registrations and would tie the shortcut to whichever view happens to be
/// realized.
struct ExportMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            Button("Export C64 File…") { exportC64File(model: model) }
                .disabled(model.converted == nil)
            Button("Export PNG…") { exportPNG(model: model) }
                .disabled(model.converted == nil)
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.converted == nil)
    }
}
