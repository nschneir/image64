import C64Kit
import Observation
import SwiftUI

/// The bottom-bar of knobs: dither, palette, and the three tone sliders.
///
/// `@Bindable` is required because SwiftUI needs writable bindings
/// (`$model.settings.foo`) to hand to `Picker` and `Slider`, and an
/// `@Observable` reference type only produces those through the `@Bindable`
/// property wrapper — a plain `let` would give read-only access.
struct ControlsView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            // DitherMode is not `CaseIterable` in C64Kit, and this View is not
            // the place to add that conformance — hardcoding the three cases
            // keeps the picker source-of-truth local and avoids reaching into
            // the engine module just to enumerate an enum.
            Picker("Dither", selection: $model.settings.dither) {
                ForEach([DitherMode.none, .bayer, .fs], id: \.self) { d in
                    Text(label(for: d)).tag(d)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Dithering")

            Picker("Palette", selection: $model.settings.palette) {
                ForEach(C64Palette.allCases, id: \.self) { p in
                    Text(label(for: p)).tag(p)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Palette")

            slider(
                title: "Brightness",
                value: $model.settings.brightness)
            slider(
                title: "Contrast",
                value: $model.settings.contrast)
            slider(
                title: "Saturation",
                value: $model.settings.saturation)

            Spacer()

            // Reset preserves `cropRect` on purpose: the user framed the
            // picture with intent, and wiping their crop when they only meant
            // to undo a slider nudge would be surprising. The explicit
            // `scheduleConvert()` covers the case where every value is
            // already at its default — `.onChange` won't fire, but a re-render
            // still costs nothing and keeps the button feeling responsive.
            Button("Reset") {
                model.settings = ConversionSettings()
                model.scheduleConvert()
            }
            .accessibilityLabel("Reset adjustments")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // One `.onChange` on the whole `ConversionSettings` value catches every
        // knob mutation. Sprinkling per-control `.onChange` would multiply
        // the surface area, and would break silently the moment a future
        // control forgets to add its own — this keeps "any setting changed"
        // as a single, provable rule.
        .onChange(of: model.settings) { _, _ in
            model.scheduleConvert()
        }
    }

    /// The three tone sliders share the same shape — a label with the live
    /// value, then a fixed-width slider — so pull the arrangement into one
    /// helper rather than repeating it three times.
    @ViewBuilder
    private func slider(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(value.wrappedValue, specifier: "%.2f")")
                .font(.caption)
            Slider(value: value, in: -1...1)
                .frame(width: 140)
                .accessibilityLabel(title)
                .accessibilityValue("\(value.wrappedValue, specifier: "%.2f")")
        }
    }

    private func label(for dither: DitherMode) -> String {
        switch dither {
        case .none: return "None"
        case .bayer: return "Bayer"
        case .fs: return "Floyd–Steinberg"
        }
    }

    private func label(for palette: C64Palette) -> String {
        switch palette {
        case .colodore: return "Colodore"
        case .pepto: return "Pepto"
        }
    }
}
