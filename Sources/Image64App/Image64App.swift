import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import C64Kit

/// The App type is deliberately not named `Image64App`: that is the module's
/// own name, and shadowing it makes references from later files ambiguous.
///
/// The model is reached from here — not from inside `RootView` — because the
/// File menu commands are declared on the `Scene` and need to close over the
/// same `AppModel` instance the window is showing.
@main
struct Image64AppMain: App {
    // Without an .app bundle, LaunchServices treats the executable as a
    // background helper: no menu bar, no Dock activation, focus stays on the
    // launching terminal. Setting the activation policy to `.regular` before
    // the first window shows fixes both — the app owns its menu bar and comes
    // to the front on launch, matching how the .app bundle
    // (`scripts/make-app.sh`) behaves. The delegate is the only reliable place
    // to run this: `App.init` fires too early on some macOS versions.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The delegate owns the model rather than a `@State` here, because
    /// `application(_:open:)` can arrive before this scene has rendered
    /// anything — see `AppDelegate`. This indirection keeps every call site
    /// below reading `model`, as they did when it was `@State`.
    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        WindowGroup("image64") {
            RootView(model: model)
        }
        .commands {
            // Without an .app bundle there is no Info.plist for the standard
            // About panel to read, so it falls back to the executable's
            // generic folder-ish icon and an empty name — which is what the
            // maintainer was looking at. Supplying the options dictionary
            // fixes the name, version, and credits today; the icon stays
            // generic until Task 15 wraps the binary in a bundle with a real
            // one, because the panel takes its icon from `NSApp.applicationIconImage`
            // and there is nothing to point that at yet.
            CommandGroup(replacing: .appInfo) {
                Button("About image64") {
                    let credits = NSAttributedString(
                        string: """
                            Converts modern images into Commodore 64 bitmap-mode pictures.
                            MIT license.
                            """,
                        attributes: [
                            .font: NSFont.systemFont(
                                ofSize: NSFont.smallSystemFontSize)
                        ])
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "image64",
                            .applicationVersion: "0.1.0",
                            // The panel prints "Version <applicationVersion>
                            // (<version>)" and shows a bare "()" if the build
                            // number is absent rather than empty.
                            .version: "",
                            .credits: credits,
                        ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openImagePanel(model: model) }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                // `recentDocumentURLs` is read when SwiftUI builds this menu,
                // not when the user opens it, so the list only refreshes on
                // the next menu rebuild. That is the price of surfacing
                // AppKit's recent-documents list from a non-document-based
                // SwiftUI app; a document type would get live updates for
                // free but would also drag in a whole file-format contract
                // we do not want.
                Menu("Open Recent") {
                    ForEach(NSDocumentController.shared.recentDocumentURLs, id: \.self) { url in
                        Button(url.lastPathComponent) { model.load(url: url) }
                    }
                    if !NSDocumentController.shared.recentDocumentURLs.isEmpty {
                        Divider()
                        Button("Clear Menu") {
                            NSDocumentController.shared.clearRecentDocuments(nil)
                        }
                    }
                }
            }
            // Menu-bar command first — the toolbar `ExportMenu` duplicates
            // this button for one-click access, but if a keyboard shortcut
            // ever lands ambiguously between the two the File menu item is
            // the source of truth. PNG export used to live here on ⇧⌘E; it
            // is a verification aid for checking the converter's output, so
            // it now belongs to the CLI only.
            CommandGroup(after: .saveItem) {
                Button("Export C64 File…") { exportC64File(model: model) }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.converted == nil)
                Button("Export Runnable PRG…") { exportPRG(model: model) }
                    .disabled(model.converted == nil)
                Divider()
                // Disabled rather than hidden when VICE is absent: a hidden
                // command teaches the user the feature does not exist, a
                // disabled one that something is missing (`brew install
                // vice`). The README and skill spell out the install.
                Button("Show in VICE") { showInVICE(model: model) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.converted == nil || ViceLauncher.findX64sc() == nil)
            }
        }
    }
}

private struct RootView: View {
    let model: AppModel

    var body: some View {
        // The controls bar used to be a `.safeAreaInset(edge: .bottom)`, which
        // hangs the bar *over* the content and only insets the safe area —
        // `HSplitView` does not honor that inset for its own children, so the
        // bar sat on top of the bottom of both panes. An explicit `VStack`
        // makes the split view and the bar siblings that divide the window
        // between them, so overlap is structurally impossible.
        VStack(spacing: 0) {
            HSplitView {
                sourcePane
                PreviewView(model: model)
                    .frame(
                        minWidth: 340, maxWidth: .infinity,
                        maxHeight: .infinity)
                    .dropReceiver(model: model)
            }
            Divider()
            ControlsView(model: model)
        }
        // Taller and wider than before: the controls bar now takes real
        // vertical space instead of floating over the panes, and at
        // `.controlSize(.regular)` its row needs the extra width to lay out
        // without the sliders collapsing.
        .frame(minWidth: 980, minHeight: 560)
        .navigationTitle(model.sourceURL?.lastPathComponent ?? "image64")
        // Exactly one toolbar item. The mode picker used to sit here in
        // `.navigation` placement; a settings control in the unified title bar
        // reads as clutter and is not what that area is for, so it moved into
        // the controls bar. A single trailing action button is the standard
        // macOS title-bar shape.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ExportMenu(model: model)
                    .help("Export the converted picture as a C64 file")
            }
        }
        // Centralized settings observer: one `.onChange` on the whole
        // `ConversionSettings` value replaces per-control `.onChange` in
        // every ControlsView slider/picker AND catches the Reset button in
        // one place. `ConversionSettings` is `Equatable`, so the comparison
        // is O(1) for the small value type it is, and correctness is
        // guaranteed for bulk mutations like Reset that would otherwise fire
        // N separate observers.
        .onChange(of: model.settings) { _, _ in
            model.scheduleConvert()
        }
    }

    // Both panes carry `.dropReceiver` so the entire window accepts a drop
    // once an image is loaded — not just the empty state. Dropping a new
    // file over the source view or the preview replaces the current image.
    //
    // The explicit `minWidth`/`maxWidth` and `.layoutPriority(1)` fix the
    // source pane collapsing to a sliver as soon as a conversion landed:
    // `HSplitView` divides its initial space by each child's ideal size, and
    // `CropView`'s `GeometryReader` reports no ideal width at all, so the
    // preview's image took everything. Giving both panes the same flexible
    // frame — and the source pane a higher layout priority so it is served
    // first — makes the initial division even and keeps the divider draggable.
    @ViewBuilder private var sourcePane: some View {
        Group {
            if model.sourceImage != nil {
                CropView(model: model)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .dropReceiver(model: model)
            } else {
                DropView(model: model)
            }
        }
        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }
}

@MainActor
private func showInVICE(model: AppModel) {
    guard let converted = model.converted else { return }
    do {
        try ViceLauncher.show(
            converted,
            title: model.sourceURL?.deletingPathExtension().lastPathComponent ?? "image64")
    } catch {
        NSAlert(error: error).runModal()
    }
}

/// Holds the one `AppModel` and handles the launch-time AppKit callbacks the
/// SwiftUI `App` type cannot express.
///
/// The model lives here, not in a `@State` on the `App`, because AppKit
/// delivers the open-documents Apple event between
/// `applicationWillFinishLaunching` and `applicationDidFinishLaunching` — i.e.
/// before the scene has rendered and before any `onAppear`/`task` could have
/// handed a scene-owned model over. Owning it means a URL arriving that early
/// always has somewhere to go; the window then draws whatever state it finds.
@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Where Finder ▸ Open With, a drop on the Dock icon, and `open -a
    /// image64 file` all land — the routes the `CFBundleDocumentTypes` entry
    /// in `scripts/make-app.sh` advertises.
    ///
    /// The app shows one picture at a time, so the first URL wins and it
    /// replaces whatever is loaded, exactly as a drag-and-drop onto the window
    /// does. Loading is `AppModel.load` — the same entry point as every other
    /// route into the app — so recent documents and error reporting behave
    /// identically here.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        model.load(url: url)
    }
}
