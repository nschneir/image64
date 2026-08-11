import AppKit
import C64Kit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Open panel

/// Presents the standard open panel and hands the chosen file to the model.
///
/// This lives beside `DropView` rather than in `Image64App.swift` because the
/// empty state is now the primary place a user reaches for it — the File ▸
/// Open… command calls the same function, so both routes share one panel
/// configuration instead of drifting apart.
///
/// `reveal` is called only when a file was actually chosen and loaded, and it
/// is what puts the window back when the command ran with the window closed —
/// see `mainWindowID`. Cancelling the panel deliberately reveals nothing: the
/// user asked for no picture, and conjuring an empty window at them is not an
/// answer to that.
@MainActor
func openImagePanel(model: AppModel, reveal: () -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.image]
    if panel.runModal() == .OK, let url = panel.url {
        model.load(url: url)
        reveal()
    }
}

// MARK: - Empty state

/// What the window shows before any image is loaded: an icon, a prompt, and
/// the same drop-and-paste behavior the whole window carries after loading.
/// The behavior itself lives in `DropReceiver` so the empty state and the
/// always-on overlay share one implementation.
struct DropView: View {
    let model: AppModel

    /// Passed through to `openImagePanel` so both routes into the panel share
    /// one signature. Clicking this well means the window is already on screen,
    /// so the reveal is a no-op here — but a no-op that keeps the File menu
    /// command and the well running the identical code.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            // Says "click" out loud because the affordance is invisible
            // otherwise — there is no button here, just a well.
            Text("Drop or paste an image, or click to browse")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("PNG, JPEG, HEIC, TIFF, GIF, WebP")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if let message = model.loadError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // `.contentShape` before the tap gesture so the hit area is the whole
        // pane, not just the glyph and the two lines of text: clicking an
        // empty drop target to get a file browser is the standard macOS
        // affordance (Xcode's asset well, Safari's downloads shelf), and it
        // only reads as one if the entire well is clickable.
        .contentShape(Rectangle())
        .onTapGesture {
            openImagePanel(model: model) { revealMainWindow(using: openWindow) }
        }
        .help("Click to choose an image, or drop one here")
        .dropReceiver(model: model)
    }
}

// MARK: - Modifier that any view can attach

extension View {
    /// Wraps the view so it accepts file/image drops and ⌘V pastes, routing
    /// both through `AppModel.load(url:)`. Applied both by the empty-state
    /// `DropView` and by the loaded window so a fresh image can replace the
    /// current one without a trip through File ▸ Open.
    func dropReceiver(model: AppModel) -> some View {
        modifier(DropReceiver(model: model))
    }
}

private struct DropReceiver: ViewModifier {
    let model: AppModel
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay(highlight)
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
            .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted, perform: handleDrop)
            .background(pasteShortcut)
    }

    // MARK: Highlight

    @ViewBuilder
    private var highlight: some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )
                .allowsHitTesting(false)
        }
    }

    // MARK: Drop

    /// Take the first provider that either carries a file URL or an image
    /// blob, resolve it to a URL on disk, and hand it to `AppModel.load`.
    /// Returning `false` when nothing usable arrived lets the drag cursor
    /// snap back so the user sees the drop was refused.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard
                    let data = item as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                Task { @MainActor in
                    model.load(url: url)
                }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let url = writeTempImage(data: data) else { return }
                Task { @MainActor in
                    model.load(url: url)
                }
            }
            return true
        }

        return false
    }

    // MARK: Paste

    /// A zero-size button that owns the ⌘V shortcut for whichever window is
    /// front. SwiftUI on macOS 14 does not offer a first-class "global paste"
    /// hook, and a hidden button carrying the shortcut is the reliable
    /// pattern — the button is off screen but the key equivalent still fires
    /// while its view hierarchy is in the responder chain.
    private var pasteShortcut: some View {
        Button("Paste", action: handlePaste)
            .keyboardShortcut("v", modifiers: .command)
            .hidden()
    }

    private func handlePaste() {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first {
            model.load(url: url)
            return
        }

        if let image = NSImage(pasteboard: pasteboard),
           let data = pngData(from: image),
           let url = writeTempImage(data: data) {
            model.load(url: url)
        }
    }
}

// MARK: - Temp file helpers

/// A dropped image blob and a pasted `NSImage` both need to reach the loader
/// as a URL, because `AppModel.load` is URL-based end-to-end (recent
/// documents, error messages, everything). Round-tripping through a temp
/// file keeps the drop and paste paths on exactly the same code as the Open
/// panel path, and macOS reaps the temp directory on its own schedule.
private func writeTempImage(data: Data) -> URL? {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dropped-\(UUID().uuidString).png")
    do {
        try data.write(to: url)
        return url
    } catch {
        return nil
    }
}

/// PNG rather than the pasteboard's native format because it is lossless
/// and universally readable by ImageIO — the file only lives long enough
/// for `loadCGImage` to decode it, so encoder cost is not worth optimizing.
private func pngData(from image: NSImage) -> Data? {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff)
    else { return nil }
    return bitmap.representation(using: .png, properties: [:])
}
