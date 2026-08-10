import C64Kit
import CoreGraphics
import Observation
import SwiftUI

/// The picture pane — draws whatever `AppModel.previewImage` currently holds
/// with C64-appropriate chunky pixels, and hangs a small spinner in the
/// corner while a fresh conversion is in flight.
///
/// `model` is a plain `let`: `AppModel` is `@Observable`, so SwiftUI already
/// tracks reads of `previewImage` and `isConverting` from inside `body` and
/// redraws when they change. `@Bindable` would only be needed if this view
/// wrote back to the model, which it does not.
struct PreviewView: View {
    let model: AppModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Subtle plate behind the picture so the preview pane reads as
            // its own surface next to the source pane.
            Color(nsColor: .windowBackgroundColor)

            if let cgImage = model.previewImage {
                // `.interpolation(.none)` is the whole point: C64 pixels are
                // supposed to look like C64 pixels, and any smoothing at the
                // scale factors this view runs at (roughly 1×–3×) turns the
                // characteristic blockiness into mush.
                //
                // The 8:5 aspect ratio lives on the view rather than being
                // baked into the CGImage. Today `ConversionOperation`
                // renders a 640×400 buffer, which is already 8:5, so this
                // constraint is redundant — but pinning it here means a
                // future preview at a different render size (or a
                // multicolor-native 320×200 buffer) still lands in the
                // right shape without extra plumbing.
                //
                // The frame pins `idealWidth`/`idealHeight` to zero as well as
                // the maxima. A `.resizable()` Image still reports its pixel
                // size as its ideal size, and the 640×400 preview buffer was
                // therefore claiming 640 points of ideal width — which is what
                // let this pane squeeze the source pane down to a sliver when
                // `HSplitView` divided the window by ideal size on the first
                // layout after a conversion landed. With an ideal of zero the
                // pane asks for nothing and the split is decided by the two
                // panes' equal minimum widths instead.
                Image(decorative: cgImage, scale: 1, orientation: .up)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(8.0 / 5.0, contentMode: .fit)
                    .frame(
                        minWidth: 0, idealWidth: 0, maxWidth: .infinity,
                        minHeight: 0, idealHeight: 0, maxHeight: .infinity,
                        alignment: .center)
            } else if !model.isConverting {
                // Brief in-between state: an image has been loaded but the
                // first conversion has not landed yet. Kept quiet so it
                // does not draw the eye away from what is about to appear.
                Text("No preview yet")
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity,
                        alignment: .center)
            }

            if model.isConverting {
                // Overlay rather than replace: the user wants to watch the
                // picture change as they nudge sliders, not stare at a
                // spinner where the picture used to be.
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
