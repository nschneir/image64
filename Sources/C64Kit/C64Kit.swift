/// Identity of the conversion engine module.
///
/// The engine proper — palettes, quantization, cell-constraint enforcement,
/// packing, and the file writers — lands in later tasks. This exists so the
/// front ends and the test suite have something to link against.
public enum C64KitInfo {
    /// The module's name, as both front ends and the tests see it.
    public static let name = "C64Kit"

    /// The version image64 ships as — the single source of truth for it.
    ///
    /// Everything that reports a version derives from this line: the CLI's
    /// `--version`, the App's About panel when there is no Info.plist to read,
    /// and `CFBundleShortVersionString` in a locally packaged bundle, which
    /// `scripts/make-app.sh` stamps from `scripts/version.sh` — a `sed` over
    /// this very declaration. That last one is why the line's *shape* matters
    /// and not just its value: reformatting it across lines, or renaming the
    /// property, silently breaks the extraction. `VersionTests` runs the real
    /// script and compares, so such a change fails the suite rather than
    /// shipping a bundle that misreports itself.
    ///
    /// A tagged release still overrides the bundle's copy — `release.yml`
    /// passes the tag with its `v` stripped — so this governs unversioned and
    /// local builds. Bumping it is therefore step one of a release, and pushing
    /// the matching tag is step two; the two disagreeing means the tag wins in
    /// the bundle while `--version` keeps saying this.
    public static let version = "1.0.0"
}
