#!/usr/bin/env bash
#
# Max test tier: everything -- NMSTests, NMSUITests, and script/scenarios.sh.
# For a complex change (view model wiring, the persistent store, SaaS/UI
# behavior) or before building a release for distribution (script/release.sh
# runs this tier itself as a preflight step -- see that script).
#
# script/scenarios.sh needs a real network and takes about a minute; the two
# xcodebuild suites together take about the same. Budget a couple of minutes
# total, not the sub-second cost of test-quick.sh.
#
# Usage: script/test-max.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

step() { printf '\n==> %s\n' "$1"; }

step "xcodebuild tests (NMSTests + NMSUITests)"
xcodebuild test \
    -project "$PROJECT_DIR/NMS.xcodeproj" \
    -scheme NMS \
    -destination "platform=macOS"

step "Live scenarios (script/scenarios.sh)"
"$PROJECT_DIR/script/scenarios.sh"

printf '\nDone. Both xcodebuild suites and the live scenario script passed.\n'
