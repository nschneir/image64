#!/bin/bash
#
# Assembles dist/image64.app around the release-built Image64App binary.
#
# SwiftPM cannot emit an application bundle, and this project has no
# .xcodeproj to do it instead — so the bundle is the minimum LaunchServices
# needs to treat the executable as an app: a MacOS/ payload and an Info.plist.
# The plist is what buys the menu-bar name, the About panel's identity, and
# the CFBundleDocumentTypes entry that puts image64 in Finder's "Open With"
# and lets a Dock-icon drop reach `application(_:open:)`.
#
# Unsigned and un-notarized, for local use: Gatekeeper will want a
# right-click ▸ Open the first time. There is no icon in v1 either — the
# generic one is honest for an alpha.

set -euo pipefail

# Run from the package root whatever directory the caller invoked us from.
cd "$(dirname "$0")/.."

APP="dist/image64.app"

swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

# Rebuilt from scratch each time: a stale binary or a leftover file inside a
# bundle is the kind of thing that only shows up as inexplicable runtime
# behavior much later.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH/Image64App" "$APP/Contents/MacOS/Image64App"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
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

echo "Built $APP"
