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
        // Without a `defaultSize` SwiftUI opens the window at the *minimum*
        // size its content reports — which is by definition the most cramped
        // arrangement the UI still fits in, not a first impression to lead
        // with. This asks for a window wide enough that the controls bar draws
        // at its natural width (see `ControlsView.sliderWidth`) and tall enough
        // that crop and preview are both worth looking at. It is a preference,
        // not a demand: AppKit constrains a new window's frame to the screen's
        // visible area, so on a laptop display the window simply opens as large
        // as fits, and the content minimum — which is honest now, see
        // `RootView` — guarantees nothing clips at that smaller size either.
        .defaultSize(width: 1560, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About image64") { showAboutPanel() }
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
                // disabled one that something is missing — the VICE app from
                // vice-emu.sourceforge.io, or a `brew install vice`, in that
                // order of likelihood, which is also the order
                // `ViceLauncher.findX64sc()` looks and the order the error
                // alert names them. The README and skill spell out the install.
                Button("Show in VICE") { showInVICE(model: model) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!canShowInVICE(model: model))
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
        // No `minWidth` on purpose. A frame minimum *overrides* the content's
        // own, and SwiftUI hands whatever this view reports to the window as
        // `contentMinSize` — so the `minWidth: 980` that used to be here was a
        // fabricated floor 556pt narrower than the width the controls bar
        // actually needs (1536pt at `.controlSize(.regular)`, measured). The
        // bar cannot compress below its natural width, so it overflowed a
        // window opened at that floor: the Mode picker laid out at x = -219 and
        // Reset past the right edge, which is the clipped bottom bar that was
        // reported. Omitting the minimum lets SwiftUI derive it from the bar
        // itself, so it cannot drift out of date the next time a control is
        // added there — a number here would only lie again.
        //
        // The derived minimum is also what makes the window correct itself: an
        // undersized frame is now illegal rather than merely cramped, so AppKit
        // grows it back on the first layout, wherever it came from — a restored
        // frame saved by an older build included. With the fabricated 980 in
        // place, such a frame was legal and simply stayed clipped.
        //
        // `minHeight` is a different kind of constraint and stays: nothing
        // clips vertically at any height (the split view's own natural minimum
        // is ~185pt and both panes are flexible), so this is a usability floor
        // — the smallest crop-and-preview pair worth showing — rather than a
        // fit requirement.
        .frame(minHeight: 560)
        .navigationTitle(model.sourceURL?.lastPathComponent ?? "image64")
        // Two toolbar items, both actions: Show in VICE and the export menu in
        // `.primaryAction` placement, which macOS lays out last (trailing). The
        // mode picker used to sit here in `.navigation` placement; a settings
        // control in the unified title bar reads as clutter and is not what
        // that area is for, so it moved into the controls bar. What is left is
        // the standard macOS title-bar shape: a short run of trailing actions
        // on the same thing the window is showing, with the primary one last.
        .toolbar {
            // Same helper the File ▸ Show in VICE command calls, and the same
            // enablement rule — a converted picture plus a VICE we can find.
            ToolbarItem {
                Button {
                    showInVICE(model: model)
                } label: {
                    Label("Show in VICE", systemImage: "play.display")
                }
                .help("Run the converted picture in the VICE emulator")
                .disabled(!canShowInVICE(model: model))
            }
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

/// Shows the About panel: icon, name, version, a one-line description, and the
/// copyright.
///
/// The *standard* panel rather than a custom SwiftUI window, deliberately. It
/// is the shape a Mac user already knows, it inherits behavior no About box
/// should be reimplementing (a single shared instance, Escape to close, correct
/// placement, selectable text, the right materials in both appearances), and
/// every field below is one the panel already has a slot for — this fills those
/// slots in rather than laying anything out.
///
/// Under `swift run Image64App` there is no Info.plist for the panel to read,
/// so it falls back to the executable's generic folder-ish icon and an empty
/// name. Supplying the options dictionary fixes name, version, description, and
/// copyright in both cases: packaged (`scripts/make-app.sh`) and bare. The icon
/// is not in the dictionary because the panel reads
/// `NSApp.applicationIconImage`, which LaunchServices already populates from
/// the bundle's `CFBundleIconFile` (assets/icon/AppIcon.icns) — the packaged
/// app gets the real app icon for free, and a bare `swift run` has no bundle to
/// load it from, so a hardcoded developer path is the only thing overriding it
/// here could buy.
@MainActor
private func showAboutPanel() {
    NSApplication.shared.orderFrontStandardAboutPanel(
        options: [
            .applicationName: "image64",
            .applicationVersion: displayVersion,
            // The panel prints "Version <applicationVersion> (<version>)" and
            // shows a bare "()" if the build number is absent rather than
            // empty.
            .version: "",
            .credits: aboutCredits,
            aboutPanelCopyright: displayCopyright,
        ])
}

/// The panel's copyright slot.
///
/// `NSAboutPanelOptionKey` has no constant for it: the documented default is
/// that the panel reads `NSHumanReadableCopyright` from the bundle, which the
/// packaged app supplies but a bare `swift run` has no plist for. `"Copyright"`
/// is the panel's own long-standing key for overriding that, so passing it
/// fills the slot in both cases — and it is a slot, not an extra line: the
/// panel renders it in its own small centered style below the credits, exactly
/// where a Mac user looks for the license.
private let aboutPanelCopyright = NSApplication.AboutPanelOptionKey(rawValue: "Copyright")

/// The centered line under the version telling the user what this app is.
///
/// One line, because the panel is an identity card and not a feature list; the
/// license sits below it in the panel's copyright slot rather than being
/// repeated here.
///
/// The panel centers its icon, name, and version but left-aligns the credits —
/// credits are an `NSTextView`, and that is a text view's natural alignment. In
/// an otherwise centered panel that reads as a block shoved to one side, which
/// is why the paragraph style says `.center` explicitly. The small system font
/// is what Apple's own panels use for this block, and the label color is stated
/// rather than left to the text view so the line follows the appearance in dark
/// mode as the panel's other text does.
private let aboutCredits: NSAttributedString = {
    let centered = NSMutableParagraphStyle()
    centered.alignment = .center
    return NSAttributedString(
        string: "Converts modern images into Commodore 64 bitmap-mode pictures.",
        attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centered,
        ])
}()

/// The copyright and license line the About panel reports.
///
/// Read from the bundle for the same reason as `displayVersion`:
/// `scripts/make-app.sh` writes `NSHumanReadableCopyright` — which is also what
/// Finder's Get Info shows — so a packaged app reports whatever it shipped
/// with, and the literal is the `swift run` fallback. The wording tracks
/// `LICENSE.md`; keep the two in step.
private let displayCopyright: String =
    Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
    ?? "Copyright © 2026 image64 contributors. MIT license."

/// The version string the About panel reports.
///
/// Read from the bundle so a packaged `image64.app` always names the version it
/// actually shipped: `scripts/make-app.sh` writes
/// `CFBundleShortVersionString` from its version argument, and the release
/// workflow passes the pushed tag. Under `swift run Image64App` there is no
/// Info.plist at all, so the literal is the development fallback — and the one
/// place a version literal still lives in this target, matching the script's
/// own default.
private let displayVersion: String =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"

/// Whether **Show in VICE** — the File-menu command and the toolbar button,
/// which must agree — can do anything right now.
///
/// One predicate for both call sites: two copies of a disable rule drift, and
/// this one has a subtlety worth stating once. `ViceLauncher.findX64sc()` does a
/// LaunchServices lookup plus, on a miss, a full `PATH` walk of
/// `isExecutableFile` checks — synchronous filesystem I/O — and a SwiftUI
/// `body` is re-evaluated on every observable change, including every tick of a
/// slider drag. So the lookup is resolved once per process instead.
///
/// The tradeoff, deliberately taken: installing VICE while image64 is running
/// will not light the command up until the app is relaunched. That is a
/// once-ever inconvenience; main-actor I/O on every redraw is a permanent one.
@MainActor
private func canShowInVICE(model: AppModel) -> Bool {
    model.converted != nil && ViceInstallation.executable != nil
}

/// `x64sc`'s location, resolved on first read and cached for the process
/// lifetime — see `canShowInVICE` for why. A `static let` so the one-time,
/// thread-safe initialization is the language's rather than ours; `URL?` is
/// `Sendable`, so the cache needs no isolation of its own.
private enum ViceInstallation {
    static let executable: URL? = ViceLauncher.findX64sc()
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
