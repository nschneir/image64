#!/bin/bash
#
# Assembles dist/image64.app around the release-built Image64App binary.
#
# SwiftPM cannot emit an application bundle, and this project has no
# .xcodeproj to do it instead — so the bundle is the minimum LaunchServices
# needs to treat the executable as an app: a MacOS/ payload and an Info.plist.
# The plist is what buys the menu-bar name, the About panel's identity (name,
# version, and the NSHumanReadableCopyright line that Finder's Get Info shows
# too — deliberately just "MIT license.", matching `displayCopyright` in the app;
# LICENSE.md is where holder and year live), and the CFBundleDocumentTypes entry
# that puts image64 in Finder's "Open With" and lets a Dock-icon drop reach
# `application(_:open:)`.
#
# Unsigned and un-notarized, for local use: Gatekeeper will want a
# right-click ▸ Open the first time.
#
# The icon comes from assets/icon/AppIcon.icns — a real image64 conversion,
# see assets/icon/README.md. It is a build input, not a generated file, so it
# is copied rather than rebuilt here.
#
# Usage: scripts/make-app.sh [version]
#
# The optional version is what the bundle claims it is. It goes into
# CFBundleShortVersionString (what Finder and the About panel show) and
# CFBundleVersion (the build number LaunchServices and Gatekeeper expect to
# exist; there is no separate build counter in this project, so the two are the
# same string). `.github/workflows/release.yml` passes the pushed tag with its
# leading `v` stripped, so a `v0.2.0` release ships a bundle that says 0.2.0
# instead of a hardcoded literal. A bare local run gets the development
# default below, which is also the fallback the About panel uses under
# `swift run Image64App` where there is no bundle to read at all.

set -euo pipefail

# Run from the package root whatever directory the caller invoked us from.
cd "$(dirname "$0")/.."

APP="dist/image64.app"
VERSION="${1:-1.0.0}"

# Universal so one downloaded .app runs on both Apple Silicon and Intel Macs
# still supported by the macOS 14 floor. A single-arch build on an arm64 runner
# would hand an Intel user an opaque "app is damaged"-class failure. Two-arch
# builds do not land in `--show-bin-path`'s usual `.build/release`: SwiftPM
# routes them through its Xcode-style layout at .build/apple/Products/Release,
# which is what `--show-bin-path` reports back when the same --arch flags are
# passed, so the path is asked for rather than assumed.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN_PATH="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

# Rebuilt from scratch each time: a stale binary or a leftover file inside a
# bundle is the kind of thing that only shows up as inexplicable runtime
# behavior much later.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Image64App" "$APP/Contents/MacOS/Image64App"

# CFBundleIconFile below names this file, so a missing icns would ship a bundle
# that silently falls back to the generic executable icon. Fail loudly instead.
test -f assets/icon/AppIcon.icns || {
	echo "error: assets/icon/AppIcon.icns is missing" >&2
	exit 1
}
cp assets/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Unquoted heredoc delimiter so ${VERSION} expands. Nothing else in this plist
# body is a shell metacharacter — no `$`, no backticks, no `\` — so the only
# substitution that happens is the intended one. Keep it that way if you add
# keys: a literal `$` here would need escaping.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>image64</string>
	<key>CFBundleDisplayName</key>
	<string>image64</string>
	<key>CFBundleIdentifier</key>
	<string>dev.image64.app</string>
	<key>CFBundleExecutable</key>
	<string>Image64App</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>NSHumanReadableCopyright</key>
	<string>MIT license.</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.image</string>
			</array>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
		</dict>
	</array>
</dict>
</plist>
PLIST

echo "Built $APP (version ${VERSION})"
