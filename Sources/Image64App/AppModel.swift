import AppKit
import C64Kit
import CoreGraphics
import Foundation
import Observation

/// The window's state, and the one place that turns user actions into
/// conversions.
///
/// `@Observable` so SwiftUI redraws whichever fields the views actually read;
/// `@MainActor` so every UI-facing write happens on the actor the views run
/// on. The heavy work — the conversion pipeline itself — is dispatched off
/// this actor through the debouncer and a detached task, and only the
/// finished result hops back to install.
@Observable
@MainActor
final class AppModel {
    var sourceImage: CGImage?
    var sourceURL: URL?

    /// Source pixel coordinates, y = 0 at the top, always 8:5 by
    /// construction — `CropGeometry.defaultCrop` starts from the largest
    /// centred 8:5 rectangle, and every future edit runs back through the
    /// same snapper.
    var cropRect: CGRect = .zero

    var settings: ConversionSettings = ConversionSettings()
    var converted: C64Image?

    /// The 640×400 image `ConversionOperation.previewImage` renders from
    /// `converted`. Kept here — rather than recomputed on every SwiftUI read
    /// — because it is what the window paints on every frame, and rendering
    /// it once per conversion is enough.
    var previewImage: CGImage?

    var isConverting: Bool = false
    var loadError: String?

    /// The debouncer collapses a burst of slider ticks or crop-handle drags
    /// into a single conversion. One instance for the model's whole life —
    /// tearing it down between submits would defeat the point. `nonisolated`
    /// because `Debouncer` is an actor: safe to read from anywhere, and the
    /// call sites here are on `MainActor` regardless.
    nonisolated let debouncer = Debouncer(delay: .milliseconds(100))

    /// Monotonically increases every time `scheduleConvert` fires. Captured
    /// by the debounced work before the compute begins and rechecked when
    /// it returns, so a slow conversion the user has already superseded
    /// drops its result on the floor instead of overwriting the picture
    /// they actually want. Only the newest submit wins.
    private var generation: Int = 0

    init() {}

    // MARK: - Loading

    /// Opens `url`, replaces the source, and kicks off the first conversion.
    ///
    /// Synchronous because `ImageLoading.loadCGImage` is: the decode is
    /// quick enough that hopping off `MainActor` for it would cost more in
    /// actor switches than it saved in blocked frames.
    ///
    /// A failure leaves the previous `sourceImage`, `converted`, and
    /// `previewImage` in place, so a misclicked open does not blank the
    /// window on the user — only `loadError` changes. For the same reason,
    /// the recent-documents note only fires on success: File ▸ Open Recent
    /// should point at files that actually opened.
    func load(url: URL) {
        do {
            let image = try ImageLoading.loadCGImage(from: url)
            sourceImage = image
            sourceURL = url
            cropRect = CropGeometry.defaultCrop(
                sourceWidth: image.width, sourceHeight: image.height)
            loadError = nil
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            scheduleConvert()
        } catch {
            loadError = "Could not open ‘\(url.lastPathComponent)’."
        }
    }

    // MARK: - Converting

    /// Submits a conversion to run after the debounce quiets down.
    ///
    /// Safe to call from any slider `onChange` — the debouncer coalesces
    /// bursts, and the generation counter drops any result the user has
    /// already superseded by the time it finishes. Bridged through a `Task`
    /// because `Debouncer.submit` is `async`; the enclosing method is `sync`
    /// so SwiftUI bindings can call it straight from their change handlers.
    func scheduleConvert() {
        guard sourceImage != nil else { return }
        let debouncer = self.debouncer
        Task {
            await debouncer.submit { [weak self] in
                await self?.runConvert()
            }
        }
    }

    /// The body of one debounced conversion — snapshot on main, compute
    /// off, install on main.
    ///
    /// The snapshot hop matters: `ConversionSettings` is a value type and
    /// `CGImage` is reference-counted immutable, so what crosses to the
    /// background is its own thing and cannot see mid-conversion edits the
    /// user makes while the pipeline runs. Without the hop the compute
    /// would race the UI over the fields it reads.
    private func runConvert() async {
        let snapshot: (CGImage, CGRect, ConversionSettings, Int)? = await MainActor.run {
            guard let source = self.sourceImage else { return nil }
            let generation = self.beginConvert()
            return (source, self.cropRect, self.settings, generation)
        }
        guard let (source, crop, settings, generation) = snapshot else { return }

        let image = await Task.detached(priority: .userInitiated) {
            ConversionOperation.convert(source, cropRect: crop, settings: settings)
        }.value

        await MainActor.run {
            self.install(image: image, generation: generation, palette: settings.palette)
        }
    }

    /// Bumps `generation`, marks the model busy, and hands the new number
    /// back so the caller can check for supersession when the compute
    /// returns.
    private func beginConvert() -> Int {
        generation += 1
        isConverting = true
        return generation
    }

    /// Installs `image` if this call is still the newest in flight; drops
    /// it otherwise. Either way `isConverting` clears — the task itself is
    /// done, even when its result is not the one the user will see.
    private func install(image: C64Image, generation: Int, palette: C64Palette) {
        guard generation == self.generation else {
            isConverting = false
            return
        }
        converted = image
        previewImage = ConversionOperation.previewImage(for: image, palette: palette)
        isConverting = false
    }
}
