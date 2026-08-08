/// Identity of the conversion engine module.
///
/// The engine proper — palettes, quantization, cell-constraint enforcement,
/// packing, and the file writers — lands in later tasks. This exists so the
/// front ends and the test suite have something to link against.
public enum C64KitInfo {
    /// The module's name, as both front ends and the tests see it.
    public static let name = "C64Kit"
}
