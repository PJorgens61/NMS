#!/usr/bin/env bash
#
# Quick test tier: NMSTests only -- pure logic, no network, no SwiftData
# container, no @MainActor view model construction, no app launch. Runs in
# well under a second regardless of machine or network conditions.
#
# For a simple change (a doc comment, a punchlist entry, a one-line logic
# fix well inside a single function): this is enough. For anything touching
# view model wiring, the persistent store, or SaaS/UI behavior, use
# test-max.sh instead -- this tier deliberately can't catch those.
#
# Usage: script/test-quick.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

printf '\n==> Quick tests (NMSTests only)\n'
xcodebuild test \
    -project "$PROJECT_DIR/NMS.xcodeproj" \
    -scheme NMS \
    -destination "platform=macOS" \
    -only-testing:NMSTests

printf '\nDone.\n'
