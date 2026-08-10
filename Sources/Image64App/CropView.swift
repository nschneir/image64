import C64Kit
import CoreGraphics
import Observation
import SwiftUI

/// The source pane — draws the loaded picture and lets the user shape the
/// 8:5 crop that feeds the converter. All eight handles (four corners, four
/// edges) plus body drag are honored; a double-click snaps the crop back to
/// the largest centered 8:5 rectangle.
///
/// The crop rectangle in `AppModel.cropRect` lives in *source pixel*
/// coordinates so the pipeline can sample it directly. The view scales the
/// image to fit the pane and converts every drag delta from view points back
/// into source pixels before handing it to `CropInteraction.drag`, which is
/// the single source of truth for clamping, aspect lock, and minimum size.
///
/// `model` is a plain `let`: `AppModel` is `@Observable`, so SwiftUI already
/// tracks the reads of `sourceImage` and `cropRect` in `body`. Writes back
/// to the model happen inside gesture closures, which is fine — they run on
/// the main actor and trigger the normal invalidation.
struct CropView: View {
    let model: AppModel

    var body: some View {
        // The parent already shows `DropView` when no source is loaded, so
        // this view never needs to render its own empty state — it just
        // steps out of the way if it is somehow shown without a source.
        if let source = model.sourceImage {
            CropCanvas(model: model, source: source)
        } else {
            EmptyView()
        }
    }
}

/// Split out so the `source` unwrap above narrows the type and we can lean
/// on a stored `@State` for the in-progress drag rect without shuffling
/// optionals through every gesture closure.
private struct CropCanvas: View {
    let model: AppModel
    let source: CGImage

    /// The crop rectangle at the moment a drag began. Every `.onChanged`
    /// tick recomputes the new rect from THIS value plus the accumulated
    /// translation — never from `model.cropRect`, which is the drag's own
    /// output from the previous tick. Reading the output back in would let
    /// the rect integrate its own motion and slide away under the cursor.
    @State private var dragStart: CGRect?

    /// Minimum crop width in source pixels. Matches the guardrail baked
    /// into `CropInteraction.drag` and keeps a badly-aimed drag from
    /// collapsing the rect to a sliver the user cannot recover from.
    private static let minCropWidth: CGFloat = 80

    /// Visible handle marker size, in view points.
    private static let handleMarker: CGFloat = 8
    /// Hit target around each handle. Larger than the marker so the corner
    /// is comfortable to grab with a mouse without being so large that
    /// neighboring handles overlap on a small pane.
    private static let handleHit: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let sourceSize = CGSize(width: source.width, height: source.height)
            let displayed = fittedSize(source: sourceSize, in: geo.size)
            // Uniform scale — `fittedSize` preserves aspect ratio, so
            // width and height ratios are equal within float noise. Using
            // width keeps the single-scalar assumption explicit.
            let scale = displayed.width / sourceSize.width
            let imageOrigin = CGPoint(
                x: (geo.size.width - displayed.width) / 2,
                y: (geo.size.height - displayed.height) / 2)

            let cropInView = CGRect(
                x: imageOrigin.x + model.cropRect.origin.x * scale,
                y: imageOrigin.y + model.cropRect.origin.y * scale,
                width: model.cropRect.width * scale,
                height: model.cropRect.height * scale)

            ZStack(alignment: .topLeading) {
                Image(decorative: source, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: displayed.width, height: displayed.height)
                    .position(
                        x: imageOrigin.x + displayed.width / 2,
                        y: imageOrigin.y + displayed.height / 2)

                // Dimming mask with a cutout for the crop. Even-odd fill
                // is the idiomatic SwiftUI trick: one path with two
                // subpaths, and the interior of the second (the crop) is
                // considered "outside" the fill, leaving it transparent.
                // Simpler than masking a solid color with a destination-out
                // rectangle and avoids an extra composited layer.
                Path { path in
                    path.addRect(CGRect(origin: imageOrigin, size: displayed))
                    path.addRect(cropInView)
                }
                .fill(Color.black.opacity(0.4), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                // Crop border. Drawn as its own overlay (rather than a
                // stroke on the mask path) so it stays crisp regardless
                // of the mask's fill rule.
                Rectangle()
                    .stroke(Color.white, lineWidth: 1)
                    .frame(width: cropInView.width, height: cropInView.height)
                    .position(x: cropInView.midX, y: cropInView.midY)
                    .allowsHitTesting(false)

                // Body drag + double-click reset. `minimumDistance: 0` so
                // the drag begins on mouse-down; without it, a
                // double-click would race the drag and single-pixel nudges
                // would need a threshold jump before they registered.
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: cropInView.width, height: cropInView.height)
                    .position(x: cropInView.midX, y: cropInView.midY)
                    .gesture(dragGesture(for: .body, scale: scale))
                    .gesture(
                        TapGesture(count: 2).onEnded {
                            model.cropRect = CropGeometry.defaultCrop(
                                sourceWidth: source.width,
                                sourceHeight: source.height)
                            model.scheduleConvert()
                        })

                // Handles. Corner handles sit on the four corners of the
                // border; edge handles sit at the midpoints. Each hit
                // target is `handleHit` on a side and contains a small
                // visible marker of size `handleMarker` so the affordance
                // reads without swallowing surrounding clicks.
                ForEach(Self.handleLayout, id: \.handle) { spec in
                    let center = spec.center(cropInView)
                    ZStack {
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .frame(
                                width: Self.handleHit,
                                height: Self.handleHit)
                        Rectangle()
                            .fill(Color.white)
                            .frame(
                                width: Self.handleMarker,
                                height: Self.handleMarker)
                            .allowsHitTesting(false)
                    }
                    .position(x: center.x, y: center.y)
                    .gesture(dragGesture(for: spec.handle, scale: scale))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Gesture plumbing

    private func dragGesture(for handle: CropHandle, scale: CGFloat)
        -> some Gesture
    {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = model.cropRect }
                guard let start = dragStart, scale > 0 else { return }
                let srcDelta = CGSize(
                    width: value.translation.width / scale,
                    height: value.translation.height / scale)
                model.cropRect = CropInteraction.drag(
                    start,
                    handle: handle,
                    by: srcDelta,
                    in: CGSize(
                        width: source.width, height: source.height),
                    minWidth: Self.minCropWidth)
                model.scheduleConvert()
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    // MARK: - Layout helpers

    /// Largest rectangle at the source's aspect ratio that fits `container`.
    private func fittedSize(source: CGSize, in container: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0,
            container.width > 0, container.height > 0
        else {
            return .zero
        }
        let scaleX = container.width / source.width
        let scaleY = container.height / source.height
        let s = min(scaleX, scaleY)
        return CGSize(width: source.width * s, height: source.height * s)
    }

    // MARK: - Handle layout

    /// Position rule for one handle relative to the view-space crop rect.
    /// Kept as a small value type so the eight handles share one gesture
    /// factory instead of eight nearly-identical stanzas.
    private struct HandleSpec {
        let handle: CropHandle
        let center: (CGRect) -> CGPoint
    }

    private static let handleLayout: [HandleSpec] = [
        HandleSpec(handle: .topLeft) { CGPoint(x: $0.minX, y: $0.minY) },
        HandleSpec(handle: .topRight) { CGPoint(x: $0.maxX, y: $0.minY) },
        HandleSpec(handle: .bottomLeft) { CGPoint(x: $0.minX, y: $0.maxY) },
        HandleSpec(handle: .bottomRight) { CGPoint(x: $0.maxX, y: $0.maxY) },
        HandleSpec(handle: .top) { CGPoint(x: $0.midX, y: $0.minY) },
        HandleSpec(handle: .bottom) { CGPoint(x: $0.midX, y: $0.maxY) },
        HandleSpec(handle: .left) { CGPoint(x: $0.minX, y: $0.midY) },
        HandleSpec(handle: .right) { CGPoint(x: $0.maxX, y: $0.midY) },
    ]
}
