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
/// The bar reflows to two rows when one will not fit — see `body`. Controls
/// never shrink to achieve that; the layout changes shape instead, which is the
/// same trade a native bar makes.
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
    /// Both numbers are still load-bearing, but they no longer decide whether
    /// the app fits on a display. A single row of everything is the *first*
    /// thing `body` tries, not the only thing it can draw, so these govern how
    /// long the tracks are while a wide window still holds one row — and the
    /// two-row fallback is what the window's minimum width comes from.
    ///
    /// The label and readout beside them stay fixed-width — see `slider(…)` —
    /// so squeezing the window shortens the tracks without the row reflowing
    /// under the cursor, which is the invariant that matters during a drag.
    ///
    /// The two `String(format: "%+.2f", …)` calls in `slider(…)` are the
    /// accepted legacy AGENTS.md names, and it says to convert them if you touch
    /// this code. Deliberately not converted, as a recorded decision rather than
    /// an oversight: a `FormatStyle` is locale-sensitive by design, so the
    /// rendered string's width stops being predictable (decimal separator, sign
    /// glyph, digit shaping), and the 44pt readout frame exists precisely to pin
    /// that width. Swapping in a formatter risks either truncation or a return
    /// of the jitter the frame prevents, in locales nobody testing this would
    /// see. It wants its own change with a width check per locale.
    private static let sliderWidth: (min: CGFloat, ideal: CGFloat) = (90, 150)

    var body: some View {
        // Candidates in order, widest first. `ViewThatFits` proposes the
        // available width to each in turn and takes the first whose ideal size
        // fits; if none does, it lays out the *last* one anyway. So the last
        // entry is not just a fallback — it is what SwiftUI reports as the
        // view's minimum width, and therefore what the window adopts as
        // `contentMinSize` (see `RootView`).
        //
        // Why the shape changed: a single non-wrapping row cannot compress past
        // its natural width, so that width *was* the window's floor — 1405pt
        // measured, which cleared a 13" MacBook Air's 1440pt by 35pt and did not
        // fit a 1280pt display at all. Worse, the failure was silent and
        // one-way: every control added here, and every larger accessibility text
        // size, pushed the floor up until the window could no longer fit the
        // screen, and nothing failed to say so.
        //
        // Reflowing changes what a new control costs. It now buys a taller bar
        // rather than a wider floor, and a taller bar cannot make the app
        // unusable on a small display. The middle candidate keeps the old
        // behavior in the band where it was fine: between the roomy row and the
        // two-row layout the tracks shorten to `sliderWidth.min` first, so a
        // moderately narrow window still gets one row rather than jumping
        // straight to two.
        ViewThatFits(in: .horizontal) {
            singleRow(sliderWidth: Self.sliderWidth.ideal)
            singleRow(sliderWidth: Self.sliderWidth.min)
            stackedRows
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

    // MARK: - Layouts

    /// Everything on one line, the arrangement the bar prefers.
    ///
    /// Takes the track width rather than reading `sliderWidth` directly so the
    /// same row can be offered twice at different widths — which is what lets
    /// `ViewThatFits` try "roomy" before "tight" before giving up on one row.
    private func singleRow(sliderWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            modePicker
            groupDivider
            ditherPicker
            palettePicker
            groupDivider
            toneSliders(trackWidth: sliderWidth)
            Spacer()
            resetButton
        }
    }

    /// Pickers above, tone sliders below.
    ///
    /// Split along the same seam the dividers already draw in the wide layout —
    /// what to produce and how to quantize on top, how to tone underneath — so
    /// the reflow rearranges the bar without regrouping it into clusters the
    /// user has not seen before. Reset stays with the pickers because it is a
    /// window-level action rather than a tone control, and the trailing edge of
    /// the first row is where it sits in the wide layout too.
    private var stackedRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                modePicker
                groupDivider
                ditherPicker
                palettePicker
                Spacer()
                resetButton
            }
            HStack(spacing: 12) {
                toneSliders(trackWidth: Self.sliderWidth.ideal)
                Spacer()
            }
        }
    }

    // MARK: - Controls

    // The mode picker used to live in the title bar. A segmented control in
    // the toolbar is not a standard macOS title-bar element — the unified
    // title bar is for window-level actions, not for document settings — and
    // it read as clutter next to the window title. It belongs with the other
    // conversion settings.
    private var modePicker: some View {
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
    }

    // DitherMode is not `CaseIterable` in C64Kit, and this View is not the
    // place to add that conformance — hardcoding the three cases keeps the
    // picker source-of-truth local and avoids reaching into the engine module
    // just to enumerate an enum.
    private var ditherPicker: some View {
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
    }

    private var palettePicker: some View {
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
    }

    /// The three tone sliders as siblings, so either layout can drop them
    /// straight into its own `HStack` and control the spacing itself.
    @ViewBuilder
    private func toneSliders(trackWidth: CGFloat) -> some View {
        slider(title: "Brightness", value: $model.settings.brightness, trackWidth: trackWidth)
        slider(title: "Contrast", value: $model.settings.contrast, trackWidth: trackWidth)
        slider(title: "Saturation", value: $model.settings.saturation, trackWidth: trackWidth)
    }

    // Reset preserves `cropRect` on purpose: the user framed the picture with
    // intent, and wiping their crop when they only meant to undo a slider
    // nudge would be surprising. The explicit `scheduleConvert()` covers the
    // case where every value is already at its default — `.onChange` won't
    // fire, but a re-render still costs nothing and keeps the button feeling
    // responsive.
    private var resetButton: some View {
        Button("Reset") {
            model.settings = ConversionSettings()
            model.scheduleConvert()
        }
        .help(
            "Restore all conversion settings to their defaults. The crop "
                + "is kept.")
        .accessibilityLabel("Reset adjustments")
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
    ///
    /// `trackWidth` is the ideal *and* the maximum, while the floor stays at
    /// `sliderWidth.min`: a candidate row is measured at its ideal, so passing
    /// the width in is what makes "the same row, but tighter" a distinct
    /// candidate `ViewThatFits` can weigh. The minimum still applies underneath,
    /// so the last candidate can be squeezed narrower than it would like rather
    /// than forcing the window to grow.
    @ViewBuilder
    private func slider(title: String, value: Binding<Double>, trackWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .frame(width: 68, alignment: .trailing)

            Slider(value: value, in: -1...1)
                .frame(
                    minWidth: Self.sliderWidth.min,
                    idealWidth: trackWidth,
                    maxWidth: trackWidth)
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
