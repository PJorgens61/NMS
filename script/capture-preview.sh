#!/usr/bin/env bash
#
# Renders NMSTests/PreviewCapture.swift's `viewToCapture` (edit that
# property to change what's rendered) to a PNG via ImageRenderer -- no
# app launch, no AppleScript, no screenshot. Built after Iron-Ham/
# XcodePreviews turned out not to apply here: it's iOS-Simulator-based,
# and NMS is macOS-only with no simulator to launch into. ImageRenderer
# needs none.
#
# Configuration crosses to the test process via a request file, not
# environment variables -- xcodebuild test doesn't forward the invoking
# shell's environment into the test host it launches (confirmed
# directly: an env-var-based first version read back empty inside the
# test).
#
# Runs the whole NMSTests target rather than -only-testing:.../captureView
# specifically -- that filter matched zero tests for reasons not run
# down (Swift Testing's -only-testing: path syntax vs. this project's
# naming, unconfirmed). Harmless: every other NMSTests test still no-ops
# in well under a second, and PreviewCaptureTests.captureView itself
# only does real work when the request file below is present.
#
# Usage: script/capture-preview.sh [output-path] [width] [height]
#   output-path  Defaults to /tmp/nms-preview.png
#   width        Defaults to 600 (matches ContentView's own window floor)
#   height       Defaults to 1400

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_PATH="${1:-/tmp/nms-preview.png}"
WIDTH="${2:-600}"
HEIGHT="${3:-1400}"
REQUEST_PATH="/tmp/nms-capture-request.json"

cat > "$REQUEST_PATH" <<JSON
{"outputPath": "$OUTPUT_PATH", "width": $WIDTH, "height": $HEIGHT}
JSON

printf '\n==> Rendering PreviewCaptureTests.viewToCapture to %s (%sx%s)\n' "$OUTPUT_PATH" "$WIDTH" "$HEIGHT"
xcodebuild test \
    -project "$PROJECT_DIR/NMS.xcodeproj" \
    -scheme NMS \
    -destination "platform=macOS" \
    -only-testing:NMSTests

rm -f "$REQUEST_PATH"

if [ -f "$OUTPUT_PATH" ]; then
    printf '\nSaved: %s\n' "$OUTPUT_PATH"
else
    printf '\nNo file written -- the capture test likely did not run or failed. Check the xcodebuild output above.\n' >&2
    exit 1
fi
