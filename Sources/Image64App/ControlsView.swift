import C64Kit
import Observation
import SwiftUI

/// The bottom bar of knobs: mode, dither, palette, the three tone sliders, and
/// Reset.
///
/// Everything here runs at `.controlSize(.regular)`. The previous version used
/// caption-sized labels and cramped spacing, which is not a macOS look — the
/// HIG has one standard control size for a window's primary chrome, and
/// shrinking controls to fit more of them is how a bar stops reading as a
/// native bar. Groups are separated by vertical dividers rather than by
/// whitespace alone so the three clusters (what to produce, how to quantize,
/// how to tone) are legible at a glance.
///
/// `@Bindable` is required because SwiftUI needs writable bindings
/// (`$model.settings.foo`) to hand to `Picker` and `Slider`, and an
/// `@Observable` reference type only produces those through the `@Bindable`
/// property wrapper — a plain `let` would give read-only access.
struct ControlsView: View {
    @Bindable var model: AppModel

    /// Height of the group separators. Matches a regular control's height so
    /// the rules read as dividers between clusters rather than as full-height
    /// bars cutting the window.
    private static let dividerHeight: CGFloat = 24

    /// The track width of a tone slider: what it wants, and the least it will
    /// accept.
    ///
    /// This bar is the widest thing in the window, so its natural width *is*
    /// the window's minimum width — SwiftUI derives `contentMinSize` from it
    /// (see `RootView`). Pinned at the ideal, that minimum came to 1536pt,
    /// wider than the 1440pt a 13" MacBook Air runs at by default: the window
    /// would not have fit the screen, which is the same clipped bar in a
    /// different disguise. Letting the three tracks give up 60pt each puts the
    /// smallest window the bar can draw in at 1405pt (measured), which fits,
    /// while `defaultSize` still opens wide enough to show them at `ideal`.
    ///
    /// The label and readout beside them stay fixed-width — see `slider(…)` —
    /// so squeezing the window shortens the tracks without the row reflowing
    /// under the cursor, which is the invariant that matters during a drag.
    private static let sliderWidth: (min: CGFloat, ideal: CGFloat) = (90, 150)

    var body: some View {
        HStack(spacing: 12) {
            // The mode picker used to live in the title bar. A segmented
            // control in the toolbar is not a standard macOS title-bar
            // element — the unified title bar is for window-level actions,
            // not for document settings — and it read as clutter next to the
            // window title. It belongs with the other conversion settings.
            Picker("Mode", selection: $model.settings.mode) {
                Text("Hires").tag(BitmapMode.hires)
                Text("Multicolor").tag(BitmapMode.multicolor)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help(
                "Hires: 320×200, 2 colors per 8×8 cell — line art and text. "
                    + "Multicolor: 160×200 wide pixels, 3 colors + shared "
                    + "background per 4×8 cell — photographs.")
            .accessibilityLabel("Bitmap mode")

            groupDivider

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
            .fixedSize()
            .help(
                "How quantization error is spread before snapping to the "
                    + "16-color palette. Floyd–Steinberg for photos; None for "
                    + "flat graphics.")
            .accessibilityLabel("Dithering")

            Picker("Palette", selection: $model.settings.palette) {
                ForEach(C64Palette.allCases, id: \.self) { p in
                    Text(label(for: p)).tag(p)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help(
                "Which measured C64 color table to match against. Colodore is "
                    + "the modern reference; Pepto is the older community "
                    + "standard.")
            .accessibilityLabel("Palette")

            groupDivider

            slider(title: "Brightness", value: $model.settings.brightness)
            slider(title: "Contrast", value: $model.settings.contrast)
            slider(title: "Saturation", value: $model.settings.saturation)

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
            .help(
                "Restore all conversion settings to their defaults. The crop "
                    + "is kept.")
            .accessibilityLabel("Reset adjustments")
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // `.bar` is the material AppKit uses for toolbars and bottom bars, so
        // the strip separates itself from the panes above without a hand-rolled
        // color that would miss vibrancy and dark mode. The rule along its top
        // edge comes from the `VStack` in `Image64App.swift`.
        .background(.bar)
        // One `.onChange` on the whole `ConversionSettings` value catches every
        // knob mutation. Sprinkling per-control `.onChange` would multiply
        // the surface area, and would break silently the moment a future
        // control forgets to add its own — this keeps "any setting changed"
        // as a single, provable rule.
        .onChange(of: model.settings) { _, _ in
            model.scheduleConvert()
        }
    }

    private var groupDivider: some View {
        Divider().frame(height: Self.dividerHeight)
    }

    /// The three tone sliders share the same shape, so pull the arrangement
    /// into one helper rather than repeating it three times.
    ///
    /// The label and the readout are both fixed-width — the label
    /// trailing-aligned against the slider, the readout in monospaced digits
    /// with an explicit sign. Without both, every drag of any slider reflows
    /// the whole bar as "0.00" becomes "-0.75" and the row jitters under the
    /// cursor.
    @ViewBuilder
    private func slider(title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .frame(width: 68, alignment: .trailing)

            Slider(value: value, in: -1...1)
                .frame(
                    minWidth: Self.sliderWidth.min,
                    idealWidth: Self.sliderWidth.ideal,
                    maxWidth: Self.sliderWidth.ideal)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: "%+.2f", value.wrappedValue))

            Text(String(format: "%+.2f", value.wrappedValue))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
        .help("\(title) adjustment applied before conversion, −1 to +1.")
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
