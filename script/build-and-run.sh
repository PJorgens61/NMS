#!/usr/bin/env zsh
#
# Pull the latest NMS source and build it locally -- the standard way to
# keep a second Mac (e.g. a MacBook) in sync via git, rather than sharing
# a built .app across machines (see README/DESIGN-NOTES.md for why that's
# risky: code signing resets on transfer, and an iCloud-synced .app caused
# a real sync-conflict/wedged-process incident in this project's history).
#
# Usage: script/build-and-run.sh [--run]
#   --run   Also launch the built app after a successful build. Refuses
#           to launch over an already-running instance.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

step "Pulling latest from origin/main"
git -C "$PROJECT_DIR" pull origin main

step "Building (Debug)"
xcodebuild \
    -project "$PROJECT_DIR/NMS.xcodeproj" \
    -scheme NMS \
    -configuration Debug \
    -destination "platform=macOS" \
    build

step "Locating built app"
BUILT_PRODUCTS_DIR="$(xcodebuild \
    -project "$PROJECT_DIR/NMS.xcodeproj" \
    -scheme NMS \
    -configuration Debug \
    -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $2}')"
APP="$BUILT_PRODUCTS_DIR/NMS.app"
[[ -d "$APP" ]] || fail "no app bundle found at $APP"

# The stamp `BuildInfoService` reads (see DEV-SETUP.md's "Verifying
# you're running what you think you're running") lives in the built
# Info.plist, not in this script's own process -- reading it back here,
# right after the build that should have just written it, is a cheap
# self-check that the "Stamp build info" phase actually ran. A mismatch
# would mean the build phase silently failed to run or failed to write,
# which is exactly the class of gap that let a two-day-old binary go
# unnoticed before that stamp existed at all.
STAMPED_HASH="$(/usr/bin/plutil -extract NMSGitHash raw "$APP/Contents/Info.plist" 2>/dev/null || true)"
CURRENT_HASH="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
if [[ -z "$STAMPED_HASH" ]]; then
    printf 'warning: built app has no NMSGitHash stamp -- BuildInfoService will report "unknown"\n' >&2
elif [[ "$STAMPED_HASH" != "$CURRENT_HASH" ]]; then
    printf 'warning: built app is stamped %s but HEAD is %s -- rebuild before trusting the footer\n' "$STAMPED_HASH" "$CURRENT_HASH" >&2
else
    printf 'Build stamp confirmed: %s\n' "$STAMPED_HASH"
fi

if [[ "${1:-}" == "--run" ]]; then
    step "Checking for a running instance"
    if pgrep -f "NMS.app/Contents/MacOS/NMS" >/dev/null 2>&1; then
        fail "NMS is already running -- quit it first (or stop it from Xcode's debugger, if it's attached there)."
    fi

    step "Launching"
    open "$APP"
fi

printf '\nDone.\n'
