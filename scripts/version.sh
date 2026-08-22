#!/bin/bash
#
# Prints the version image64 ships as.
#
# There is exactly one copy of that string, `C64KitInfo.version` in
# Sources/C64Kit/C64Kit.swift, because the Swift front ends can read a Swift
# constant and a shell script cannot. So the shell derives it instead: this
# script is the one place that knows how to get the value out of the source,
# and `make-app.sh` calls it rather than carrying a default of its own.
#
# Kept separate from make-app.sh so the extraction is testable without running
# a two-architecture release build — `VersionTests` executes this script and
# compares its output to the constant, which is what stops the sed expression
# from rotting away from the declaration it parses.

set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE="Sources/C64Kit/C64Kit.swift"

# Anchored on the full declaration, not just the value: a looser pattern would
# happily match a mention of `version` in the doc comment above it.
VERSION="$(sed -n 's/^ *public static let version = "\([^"]*\)".*/\1/p' "$SOURCE")"

if [ -z "$VERSION" ]; then
	echo "error: no 'public static let version = \"…\"' found in $SOURCE" >&2
	echo "       (renamed or reformatted? scripts/version.sh parses that line)" >&2
	exit 1
fi

echo "$VERSION"
