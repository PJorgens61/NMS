#!/usr/bin/env zsh
#
# Exercises NMS's outage-handling paths end to end, against a throwaway
# store, in about a minute.
#
# Every one of these scenarios previously required either physically
# unplugging a cable or waiting out a real timer — the DHCP
# renewal-overdue path alone would take 21 hours to reach honestly. See
# README's "Failure injection" section and `FailureInjector`.
#
# Usage:  script/scenarios.sh
# Exit:   0 if every assertion passed, 1 otherwise.
#
# Leaves nothing behind: the real store is never opened, all debug
# defaults are removed on exit (including on failure or Ctrl-C), and the
# app is restarted normally afterwards.

set -uo pipefail

PLIST=~/Library/Preferences/Thistle.NMS.plist
SCRATCH_DIR=/tmp/nms-scenarios
SCRATCH_STORE="$SCRATCH_DIR/store.store"
REAL_STORE=~/Library/"Application Support"/NMS/default.store
SPEEDUP=30

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

# --- plumbing --------------------------------------------------------------

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

# Core Data stores dates as seconds since 2001-01-01, so every query
# needs this offset rather than a plain unix timestamp.
now_apple() { print -r -- $(( $(date +%s) - 978307200 )); }

# Events newer than $1, optionally filtered by a LIKE pattern on kind.
events_since() {
    sqlite3 "$SCRATCH_STORE" \
        "SELECT ZKIND || ' :: ' || ZMESSAGE FROM ZAPPEVENTRECORD
         WHERE ZOCCURREDAT > $1 ORDER BY ZOCCURREDAT;" 2>/dev/null
}

# assert_event <since> <grep-pattern> <description>
assert_event() {
    local since="$1" pattern="$2" description="$3"
    if events_since "$since" | grep -qE "$pattern"; then
        print -r -- "  ✓ $description"
        (( PASS++ ))
    else
        print -r -- "  ✗ $description"
        print -r -- "      expected /$pattern/, saw:"
        events_since "$since" | sed 's/^/        /' | head -8
        (( FAIL++ ))
    fi
}

# assert_absent <since> <grep-pattern> <description>
assert_absent() {
    local since="$1" pattern="$2" description="$3"
    if events_since "$since" | grep -qE "$pattern"; then
        print -r -- "  ✗ $description"
        (( FAIL++ ))
    else
        print -r -- "  ✓ $description"
        (( PASS++ ))
    fi
}

cleanup() {
    print
    print -r -- "--- cleaning up ---"
    for key in NMSStorePath NMSPollSpeedup NMSInjectFailures \
               NMSInjectInterfaceDown NMSInjectDHCPLinkLocal \
               NMSInjectDHCPRenewalOverdue NMSInjectSNMPRestart \
               NMSInjectSNMPSoftwareChange; do
        clear_key "$key"
    done
    quit_app
    rm -rf "$SCRATCH_DIR"
    launch_app
    print -r -- "real store restored, app running normally"
}
trap cleanup EXIT INT TERM

# --- setup -----------------------------------------------------------------

print -r -- "=== NMS scenarios ==="

# Seeded from the real store rather than started empty, and that's
# load-bearing: SNMPViewModel.poll() guards on a non-empty device list,
# and discovery only ever runs from the popover's Scan button — so a
# fresh store would never populate and every SNMP scenario would
# silently pass by doing nothing. Seeding also gives restart detection
# the previous uptime it compares against.
quit_app
rm -rf "$SCRATCH_DIR"
mkdir -p "$SCRATCH_DIR"
if [[ -f "$REAL_STORE" ]]; then
    cp "$REAL_STORE" "$SCRATCH_STORE"
    print -r -- "seeded scratch store from real store (read-only copy)"
else
    print -r -- "no real store found; starting empty (SNMP scenarios will be skipped)"
fi

CONNECTIVITY_SEEDED=$(sqlite3 "$SCRATCH_STORE" 'SELECT COUNT(*) FROM ZCONNECTIVITYCHECKRECORD;' 2>/dev/null || print 0)

set_key NMSStorePath "$SCRATCH_STORE"
set_key NMSPollSpeedup -int "$SPEEDUP"
launch_app

# Fail fast if the app isn't actually running against the scratch store.
# Without this the suite can report green while doing nothing at all:
# every `assert_absent` passes vacuously when no events exist, so a
# launch failure reads as a partially-successful run rather than an
# error. Found exactly that way — running this script from a copied
# location broke the app path, the app never started, and four
# assertions still "passed".
#
# Checks for *new* rows rather than any rows: the scratch store is
# seeded from the real one, so it already contains plenty.
sleep 4
CONNECTIVITY_AFTER=$(sqlite3 "$SCRATCH_STORE" 'SELECT COUNT(*) FROM ZCONNECTIVITYCHECKRECORD;' 2>/dev/null || print 0)
if (( CONNECTIVITY_AFTER <= CONNECTIVITY_SEEDED )); then
    print -r -- "ERROR: no new connectivity rows after launch (${CONNECTIVITY_SEEDED} -> ${CONNECTIVITY_AFTER})."
    print -r -- "       The app isn't running, or isn't using $SCRATCH_STORE."
    print -r -- "       Check: grep App.store ~/Library/Logs/NMS/ui-state.log"
    exit 1
fi

print -r -- "running at ${SPEEDUP}x — connectivity ~1s, SNMP ~2s, DHCP ~10s"
print

# --- scenario 1: connectivity failure and recovery --------------------------

print -r -- "1. connectivity failure -> recovery"
T=$(now_apple)
set_key NMSInjectFailures -array Router DNS
sleep 5
assert_event "$T" 'routerUnreachable .*\[injected\]' "Router failure logged and labelled"
assert_event "$T" 'dnsUnreachable .*\[injected\]'    "DNS failure logged and labelled"
assert_absent "$T" 'httpUnreachable'                  "HTTP left healthy (injection is selective)"

# Cleared in place, not by relaunching: logTransitions compares against
# the previous round's in-memory results, which reset at launch, so a
# restart would log no recovery at all.
T2=$(now_apple)
clear_key NMSInjectFailures
sleep 5
assert_event "$T2" 'routerReachable'  "Router recovery logged"
assert_absent "$T2" 'routerReachable :: \[injected\]' "recovery not labelled (it really did recover)"

# --- scenario 2: DHCP APIPA fallback ---------------------------------------

print
print -r -- "2. DHCP link-local (APIPA) fallback"
T=$(now_apple)
set_key NMSInjectDHCPLinkLocal -bool YES
sleep 14
assert_event "$T" 'dhcpFellBackToLinkLocal .*\[injected\]' "APIPA fallback logged and labelled"
clear_key NMSInjectDHCPLinkLocal

# --- scenario 3: DHCP renewal overdue --------------------------------------

print
print -r -- "3. DHCP renewal overdue (T2 passed)"
T=$(now_apple)
set_key NMSInjectDHCPRenewalOverdue -bool YES
sleep 14
assert_event "$T" 'dhcpRenewalOverdue .*\[injected\]' "renewal-overdue logged and labelled"
clear_key NMSInjectDHCPRenewalOverdue

# --- scenario 4: SNMP restart, software change, and both --------------------

if sqlite3 "$SCRATCH_STORE" "SELECT COUNT(*) FROM ZSNMPDEVICERECORD;" 2>/dev/null | grep -qv '^0$'; then
    print
    print -r -- "4. SNMP restart / software change"
    T=$(now_apple)
    set_key NMSInjectSNMPRestart -array Switch AP2
    set_key NMSInjectSNMPSoftwareChange -array AP1 AP2
    sleep 8
    assert_event "$T" 'snmpDeviceRestarted .*\[injected\] Switch'          "restart alone -> restarted unexpectedly"
    assert_event "$T" 'snmpDeviceSoftwareChanged .*\[injected\] AP1'       "descriptor alone -> software changed"
    # The branch neither key reaches on its own: an uptime reset that
    # arrives *with* a descriptor change is the explained case, so it
    # must not be reported as the alarming bare restart.
    assert_event "$T" 'snmpDeviceSoftwareChanged .*AP2 restarted after software change' \
        "restart + descriptor -> restarted after software change"
    assert_absent "$T" 'snmpDeviceRestarted .*AP2' "AP2 not reported as a bare restart"
    clear_key NMSInjectSNMPRestart
    clear_key NMSInjectSNMPSoftwareChange
else
    print
    print -r -- "4. SNMP — skipped (no devices in store)"
fi

# --- result ----------------------------------------------------------------

print
print -r -- "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
