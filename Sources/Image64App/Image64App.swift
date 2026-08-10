import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import C64Kit

/// The App type is deliberately not named `Image64App`: that is the module's
/// own name, and shadowing it makes references from later files ambiguous.
///
/// The model lives here — not inside `RootView` — because the File menu
/// commands are declared on the `Scene` and need to close over the same
/// `AppModel` instance the window is showing.
@main
struct Image64AppMain: App {
    // Without an .app bundle, LaunchServices treats the executable as a
    // background helper: no menu bar, no Dock activation, focus stays on the
    // launching terminal. Setting the activation policy to `.regular` before
    // the first window shows fixes both — the app owns its menu bar and comes
    // to the front on launch, matching how the Task 15 .app bundle will
    // behave. The delegate is the only reliable place to run this: `App.init`
    // fires too early on some macOS versions.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("image64") {
            RootView(model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openImage(model: model) }
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
            // Menu-bar commands first — the toolbar `ExportMenu` duplicates
            // these buttons for one-click access, but if a keyboard shortcut
            // ever lands ambiguously between the two the File menu items are
            // the source of truth.
            CommandGroup(after: .saveItem) {
                Button("Export C64 File…") { exportC64File(model: model) }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.converted == nil)
                Button("Export PNG…") { exportPNG(model: model) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.converted == nil)
            }
        }
    }
}

private struct RootView: View {
    let model: AppModel

    var body: some View {
        // Local `@Bindable` shadow: the property is declared `let model:
        // AppModel` because `RootView` does not own the observable, but the
        // toolbar picker needs a two-way binding (`$model.settings.mode`).
        // On macOS 14 this is the idiomatic way to derive bindings from a
        // passed-in `@Observable` reference without changing the property
        // declaration or the call site.
        @Bindable var model = model
        HSplitView {
            sourcePane
            PreviewView(model: model)
                .dropReceiver(model: model)
        }
        .frame(minWidth: 900, minHeight: 500)
        .navigationTitle(model.sourceURL?.lastPathComponent ?? "image64")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Mode", selection: $model.settings.mode) {
                    Text("Hires").tag(BitmapMode.hires)
                    Text("Multicolor").tag(BitmapMode.multicolor)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Bitmap mode")
            }
            ToolbarItem(placement: .primaryAction) {
                ExportMenu(model: model)
            }
        }
        .safeAreaInset(edge: .bottom) {
            ControlsView(model: model)
        }
        // Centralized settings observer: one `.onChange` on the whole
        // `ConversionSettings` value replaces per-control `.onChange` in
        // every ControlsView slider/picker AND catches the toolbar mode
        // picker and the Reset button in one place. `ConversionSettings`
        // is `Equatable`, so the comparison is O(1) for the small value
        // type it is, and correctness is guaranteed for bulk mutations
        // like Reset that would otherwise fire N separate observers.
        .onChange(of: model.settings) { _, _ in
            model.scheduleConvert()
        }
    }

    // Both panes carry `.dropReceiver` so the entire window accepts a drop
    // once an image is loaded — not just the empty state. Dropping a new
    // file over the source view or the preview replaces the current image.
    @ViewBuilder private var sourcePane: some View {
        if model.sourceImage != nil {
            CropView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .dropReceiver(model: model)
        } else {
            DropView(model: model)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private func openImage(model: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.image]
    if panel.runModal() == .OK, let url = panel.url {
        model.load(url: url)
    }
}
