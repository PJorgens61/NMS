#!/usr/bin/env zsh
#
# Phase 1 of the field-test documentation capture system: injects a
# DNS-only failure via FailureInjector, then captures a tightly cropped
# screenshot of the DNS row showing that failed state.
#
# Why not the obvious osascript/System-Events "entire contents of window"
# element lookup (documented in CLAUDE.md's "Driving the live app via
# Accessibility" section): PUNCHLIST.md documents that exact mechanism
# repeatedly returning zero elements in this project before, root cause
# never diagnosed. Since NMS is the process being inspected, it reports its
# own row frames directly instead, via `reportFrameForFieldTest` (see
# NMS/Views/FieldTestFrameReporter.swift) writing to ui-state.log --  no
# external Accessibility tree-walk needed for that part. System
# Events/osascript is still used for the one thing CLAUDE.md documents as
# actually reliable: the window's own position/size.
#
# screencapture -R takes raw *point* coordinates (matching AX
# position/size units) and auto-scales to Retina pixels on its own --
# confirmed directly against a real window before writing this (600pt wide
# window -> 1200px PNG), so no manual pixel-scale multiplication happens
# here.
#
# Runs against a throwaway store (see NMSApp.swift's NMSStorePath doc
# comment for why this is load-bearing, not optional) -- the real store and
# real event history are never touched.
#
# Output goes to script/doc-captures/ (gitignored): the crop contains the
# real DNS server IP from this network, since sanitization doesn't exist
# yet. Never commit or share anything from that directory as-is.
#
# Refuses to run at all unless the current network is explicitly marked
# public for capture (KnownNetwork.isPublicForCapture, defaults false for
# every network). This is a separate safety layer from the "don't commit
# doc-captures/" rule above -- that one protects against accidentally
# publishing what got captured; this one protects against accidentally
# *capturing* real data from a network that was never meant to be
# documented (a client site, a friend's place) in the first place. Mark a
# network public first:
#   sqlite3 ~/Library/"Application Support"/NMS/default.store \
#     "UPDATE ZKNOWNNETWORK SET ZISPUBLICFORCAPTURE = 1 WHERE ZFINGERPRINT = '<fingerprint>';"
#
# Usage: script/capture-doc-scenarios.sh

set -uo pipefail

PLIST=~/Library/Preferences/Thistle.NMS.plist
SCRATCH_DIR=/tmp/nms-doc-capture
SCRATCH_STORE="$SCRATCH_DIR/store.store"
REAL_STORE=~/Library/"Application Support"/NMS/default.store
UI_STATE_LOG=~/Library/Logs/NMS/ui-state.log
SPEEDUP=30
PAD_PT=8

# Empirically measured, not assumed -- macOS's standard window title bar
# sits above the SwiftUI content view that `reportFrameForFieldTest`'s
# "nmsWindow" coordinate space is anchored to, so `position of window`
# (which reports the outer frame, title bar included) needs this offset
# added before it lines up with a row's logged, content-relative Y. If a
# crop is consistently shifted up/down by a fixed amount, recalibrate this
# first -- see the verification step in the field-test plan for how it was
# derived.
TITLE_BAR_HEIGHT_PT=28

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/script/doc-captures"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

# --- plumbing, copied from scenarios.sh -------------------------------------

app_path() {
    local built
    built="$(xcodebuild -project "$PROJECT_DIR/NMS.xcodeproj" -scheme NMS \
        -configuration Debug -showBuildSettings 2>/dev/null \
        | awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $2}')"
    print -r -- "$built/NMS.app"
}

quit_app() { pkill -f "NMS.app/Contents/MacOS/NMS" 2>/dev/null; sleep 1; }
launch_app() { open "$(app_path)"; sleep 3; }
set_key()   { defaults write "$PLIST" "$1" "${@:2}"; }
clear_key() { defaults delete "$PLIST" "$1" 2>/dev/null; }

# --- new helpers -------------------------------------------------------------

# Refuses to proceed unless the current network is explicitly marked
# public. Reads the *real* store, not the scratch one -- the scratch store
# starts empty every run and has no KnownNetwork rows of its own, and the
# whole point is gating on this Mac's actual, currently-recognized network,
# not a throwaway copy. Uses the most-recently-seen row as "the current
# network": NMS updates lastSeenAt on every recognition round while
# running, so for a script invoked right now against the live real store,
# that's a reliable proxy without needing to duplicate this app's own
# router-MAC/subnet detection logic here.
check_network_is_public() {
    [[ -f "$REAL_STORE" ]] || fail "no real store found at $REAL_STORE -- launch NMS at least once first"
    local fingerprint is_public
    fingerprint="$(sqlite3 "$REAL_STORE" "SELECT ZFINGERPRINT FROM ZKNOWNNETWORK ORDER BY ZLASTSEENAT DESC LIMIT 1;" 2>/dev/null)"
    [[ -n "$fingerprint" ]] || fail "no known network found in $REAL_STORE -- is NMS running, and has it recognized this network yet?"
    is_public="$(sqlite3 "$REAL_STORE" "SELECT ZISPUBLICFORCAPTURE FROM ZKNOWNNETWORK WHERE ZFINGERPRINT = '$fingerprint';" 2>/dev/null)"
    if [[ "$is_public" != "1" ]]; then
        fail "current network ($fingerprint) isn't marked public for capture -- defaults to private, per KnownNetwork.isPublicForCapture. Mark it explicitly first:
  sqlite3 \"$REAL_STORE\" \"UPDATE ZKNOWNNETWORK SET ZISPUBLICFORCAPTURE = 1 WHERE ZFINGERPRINT = '$fingerprint';\""
    fi
    print -r -- "network $fingerprint is marked public for capture -- proceeding"
}

# Sets WIN_X WIN_Y WIN_W WIN_H (points, outer frame including title bar).
window_geometry() {
    local raw
    raw="$(osascript -e 'tell application "System Events" to tell process "NMS" to return (position of window "NMS") & (size of window "NMS")')"
    IFS=', ' read -r WIN_X WIN_Y WIN_W WIN_H <<< "$raw"
    [[ -n "$WIN_H" ]] || fail "couldn't read NMS window geometry -- is it running and frontmost?"
}

# Sets ROW_X ROW_Y ROW_W ROW_H (points, relative to the "nmsWindow"
# coordinate space -- i.e. relative to the content view, title bar
# excluded).
#
# Unions every logged frame for this id, rather than reading just the
# newest line -- confirmed directly (not assumed) that a `GridRow`
# distributes `.background(GeometryReader)` to each of its cells
# individually rather than giving one frame spanning the whole row: a
# single row logs five separate small frames (dot, label, icon, chart,
# detail) under the same id, not one. Taking only the last line often
# picked up just the 8x8 status dot. The union of every logged frame for
# an id reconstructs the true row bounds regardless of which cell(s)
# happened to log last, and is safe against later partial re-logs (e.g.
# just the trailing detail column re-firing on a window resize) since a
# union only grows or holds steady as more subset frames are folded in.
read_logged_frame() {
    local id="$1"
    local minx miny maxx2 maxy2
    local first=1
    while IFS= read -r line; do
        local value="${line##*| }"
        local x="${${(s: :)value}[1]#x=}"
        local y="${${(s: :)value}[2]#y=}"
        local w="${${(s: :)value}[3]#width=}"
        local h="${${(s: :)value}[4]#height=}"
        local x2=$(( x + w ))
        local y2=$(( y + h ))
        if (( first )); then
            minx=$x; miny=$y; maxx2=$x2; maxy2=$y2
            first=0
        else
            (( x < minx )) && minx=$x
            (( y < miny )) && miny=$y
            (( x2 > maxx2 )) && maxx2=$x2
            (( y2 > maxy2 )) && maxy2=$y2
        fi
    done < <(grep -F " | fieldTest.frame.${id} | " "$UI_STATE_LOG" 2>/dev/null)
    (( first )) && fail "no logged frame for '$id' in $UI_STATE_LOG -- did the row render, and is this a DEBUG build?"
    ROW_X=$minx
    ROW_Y=$miny
    ROW_W=$(( maxx2 - minx ))
    ROW_H=$(( maxy2 - miny ))
}

# crop_row <field-test-id> <output-path>
crop_row() {
    local id="$1" out_path="$2"
    window_geometry
    read_logged_frame "$id"

    local x=$(( WIN_X + ROW_X - PAD_PT ))
    local y=$(( WIN_Y + TITLE_BAR_HEIGHT_PT + ROW_Y - PAD_PT ))
    local w=$(( ROW_W + PAD_PT * 2 ))
    local h=$(( ROW_H + PAD_PT * 2 ))

    # Clamp to the window's own bounds -- padding must not bleed past a
    # tile edge into whatever's behind/around the window.
    (( x < WIN_X )) && x=$WIN_X
    (( y < WIN_Y + TITLE_BAR_HEIGHT_PT )) && y=$(( WIN_Y + TITLE_BAR_HEIGHT_PT ))
    local max_x=$(( WIN_X + WIN_W ))
    local max_y=$(( WIN_Y + WIN_H ))
    (( x + w > max_x )) && w=$(( max_x - x ))
    (( y + h > max_y )) && h=$(( max_y - y ))

    screencapture -x -R"${x},${y},${w},${h}" "$out_path"
}

cleanup() {
    step "Cleaning up"
    for key in NMSStorePath NMSPollSpeedup NMSInjectFailures; do
        clear_key "$key"
    done
    quit_app
    rm -rf "$SCRATCH_DIR"
    launch_app
    print -r -- "real store restored, app running normally"
}
trap cleanup EXIT INT TERM

# --- body ---------------------------------------------------------------

step "Checking whether this network is marked public for capture"
check_network_is_public

mkdir -p "$OUTPUT_DIR"

step "Preparing scratch store"
quit_app
rm -rf "$SCRATCH_DIR"
mkdir -p "$SCRATCH_DIR"
# Started empty, deliberately -- unlike scenarios.sh's SNMP scenarios, a
# DNS check needs no pre-existing rows, and starting empty means zero real
# personal data ever touches the scratch store at all.

step "Launching against the scratch store, accelerated"
set_key NMSStorePath "$SCRATCH_STORE"
set_key NMSPollSpeedup -int "$SPEEDUP"
launch_app

step "Injecting DNS-only failure"
set_key NMSInjectFailures -array DNS
sleep 5

step "Capturing the DNS row"
crop_row "networkHealth.row.dns" "$OUTPUT_DIR/dns-failure.png"

print
print -r -- "Saved to $OUTPUT_DIR/dns-failure.png"
print -r -- "Contains this network's real DNS server IP -- do not commit or share as-is (no sanitization pass exists yet)."
