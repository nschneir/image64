#!/bin/bash
#
# The coverage gate: ≥95% line coverage over Sources/C64Kit + Sources/Image64CLI.
#
# Prints the per-file table and the TOTAL line, then exits non-zero if the TOTAL
# line coverage is below the threshold — so this is the gate itself, not a report
# about it.
#
# Scope. `Sources/Image64App` is excluded: SwiftUI view bodies don't execute
# under XCTest, and the app's testable logic (Debouncer, CropInteraction,
# CropGeometry) lives in C64Kit by design. The two source directories are named
# as arguments to `llvm-cov report`, which is also what keeps swift-argument-
# parser's own sources — vendored under .build/checkouts, not ours to test — out
# of the ratio.
#
# CLI coverage. `Tests/CLITests` spawns the real `image64` binary, so its
# counters are written by a child process rather than by the test binary. They
# still land in the report: SwiftPM points LLVM_PROFILE_FILE at
# .build/debug/codecov with a per-process pattern, the spawned binary inherits
# it, and `swift test` merges every .profraw in that directory into
# default.profdata. The check below fails loudly if a future toolchain stops
# doing that, rather than letting the CLI quietly report 0%.
#
# DEVELOPER_DIR is honored if the environment sets it (some machines need a full
# Xcode for xcrun) and is never hardcoded here.
set -euo pipefail

THRESHOLD=95

cd "$(dirname "$0")/.."

swift test --enable-code-coverage

BUILD_DIR=".build/debug"

PROFDATA="$BUILD_DIR/codecov/default.profdata"
if [ ! -f "$PROFDATA" ]; then
    echo "error: no coverage profile at $PROFDATA" >&2
    exit 1
fi

TEST_BINARY="$BUILD_DIR/image64PackageTests.xctest/Contents/MacOS/image64PackageTests"
if [ ! -f "$TEST_BINARY" ]; then
    echo "error: no test binary at $TEST_BINARY" >&2
    exit 1
fi

REPORT=$(
    xcrun llvm-cov report \
        "$TEST_BINARY" \
        -instr-profile "$PROFDATA" \
        -ignore-filename-regex '(Tests|Image64App)/' \
        -use-color=false \
        Sources/C64Kit Sources/Image64CLI
)
echo "$REPORT"

# Sanity check before the gate: a CLI reporting no coverage at all means the
# child-process profiles went missing, not that the tests stopped running.
CLI_COVER=$(echo "$REPORT" | awk '/Image64CLI\/ConvertCommand.swift/ { gsub("%", "", $10); print $10 }')
if [ -z "$CLI_COVER" ] || [ "${CLI_COVER%%.*}" -eq 0 ]; then
    echo "error: Image64CLI reported no line coverage — the spawned binary's" >&2
    echo "       .profraw files did not reach $PROFDATA" >&2
    exit 1
fi

# Field 10 of the TOTAL row is the line-coverage percentage: filename, then
# regions/missed/cover, functions/missed/executed, lines/missed/cover.
TOTAL=$(echo "$REPORT" | awk '/^TOTAL/ { gsub("%", "", $10); print $10 }')
if [ -z "$TOTAL" ]; then
    echo "error: could not read the TOTAL line coverage from the report" >&2
    exit 1
fi

if awk -v total="$TOTAL" -v gate="$THRESHOLD" 'BEGIN { exit !(total < gate) }'; then
    echo "FAIL: line coverage $TOTAL% is below the $THRESHOLD% gate" >&2
    exit 1
fi

echo "PASS: line coverage $TOTAL% meets the $THRESHOLD% gate"
