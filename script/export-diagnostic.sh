#!/usr/bin/env zsh
#
# Dumps recent network diagnostic history to one JSON file -- so a real
# problem can be handed to Claude directly, instead of a fresh round of
# ad hoc `sqlite3` queries against the store each time.
#
# **Always private.** This produces no public-sharing path: no
# sanitization exists yet, so the output contains real identifiers (IPs,
# router MAC via the network fingerprint, SNMP descriptors). It's meant
# for pasting into your own Claude conversation, not for posting
# anywhere. Deliberately does not check KnownNetwork.isPublicForCapture --
# that flag answers "is documentation capture allowed on this network,"
# a different question from "understand what's currently broken on
# whatever network I'm on right now." Gating diagnosis behind a
# documentation flag would be actively unhelpful.
#
# Reads the real store directly and never through app code, same as
# save-fixture.sh/scenarios.sh -- so this needs no #if DEBUG gating the
# way UIStateLogger does. That convention exists because ~/Library/Logs/
# is sysdiagnose-swept; this script writes wherever it's told to instead.
#
# Precedent: StoreInspector.swift did something similar (dump every table
# to a plain-text summary: row count, time span, newest rows) until it
# was deleted in the single-window rebuild (commit 4e4e83a). Its
# row-count-plus-newest-rows shape is worth keeping even though the
# implementation is gone -- see each section's totalCount/recent split
# below.
#
# Usage: script/export-diagnostic.sh

set -euo pipefail

REAL_STORE=~/Library/"Application Support"/NMS/default.store
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/script/diagnostic-exports"
LIMIT=50

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

[[ -f "$REAL_STORE" ]] || fail "no real store found at $REAL_STORE -- launch NMS at least once first"

# Runs a SQL query in JSON mode, returning a JSON array (sqlite3's
# .mode json always wraps SELECT results in an array, even for one row).
# Dot-commands like `.mode` only take effect when fed via stdin -- passed
# as a trailing positional argument instead, sqlite3 doesn't parse them
# the same way (confirmed directly: "extra argument" on the first real
# run of this script).
run_json() {
    sqlite3 "$REAL_STORE" <<SQL
.mode json
$1
SQL
}

count_of() {
    sqlite3 "$REAL_STORE" "SELECT COUNT(*) FROM $1;"
}

# section <name> <table> <select-columns-with-aliases> <order-by-column>
# Builds {"totalCount": N, "recent": [...]} for a capped table.
section() {
    local name="$1" table="$2" columns="$3" order_col="$4"
    local total recent
    total="$(count_of "$table")"
    recent="$(run_json "SELECT $columns FROM $table ORDER BY $order_col DESC LIMIT $LIMIT;")"
    jq -n --arg name "$name" --argjson total "$total" --argjson recent "$recent" \
        '{($name): {totalCount: $total, recent: $recent}}'
}

mkdir -p "$OUTPUT_DIR"

step "Reading current network"
NETWORK="$(run_json "SELECT ZFINGERPRINT as fingerprint, ZLABEL as label,
    datetime(ZFIRSTSEENAT + 978307200,'unixepoch','localtime') as firstSeenAt,
    datetime(ZLASTSEENAT + 978307200,'unixepoch','localtime') as lastSeenAt,
    ZTIMESSEEN as timesSeen, ZCONFIRMEDEDGEHOPNUMBER as confirmedEdgeHopNumber,
    ZISPUBLICFORCAPTURE as isPublicForCapture
    FROM ZKNOWNNETWORK ORDER BY ZLASTSEENAT DESC LIMIT 1;" | jq '.[0] // {}')"

step "Reading Events"
EVENTS="$(section events ZAPPEVENTRECORD \
    "ZKIND as kind, ZMESSAGE as message,
     datetime(ZOCCURREDAT + 978307200,'unixepoch','localtime') as occurredAt,
     ZNETWORKFINGERPRINT as networkFingerprint, ZURL as url" \
    ZOCCURREDAT)"

step "Reading connectivity checks"
CONNECTIVITY="$(section connectivityChecks ZCONNECTIVITYCHECKRECORD \
    "ZLABEL as label, ZTARGET as target, ZSUCCESS as success, ZLATENCYMS as latencyMs,
     datetime(ZCHECKEDAT + 978307200,'unixepoch','localtime') as checkedAt,
     ZCORRELATEDWITHCHANGE as correlatedWithChange, ZSYSTEMLOAD as systemLoad" \
    ZCHECKEDAT)"

step "Reading SNMP devices"
# No LIMIT -- small table (one row per discovered device, not per poll),
# and every device is relevant context, not just the newest few.
SNMP_TOTAL="$(count_of ZSNMPDEVICERECORD)"
SNMP_ROWS="$(run_json "SELECT ZIPADDRESS as ipAddress, ZSYSDESCR as sysDescr, ZSYSNAME as sysName,
    ZUPTIMETICKS as uptimeTicks, ZCOMMUNITY as community,
    datetime(ZFIRSTSEENAT + 978307200,'unixepoch','localtime') as firstSeenAt,
    datetime(ZLASTSEENAT + 978307200,'unixepoch','localtime') as lastSeenAt,
    ZNETWORKFINGERPRINT as networkFingerprint, ZWEBURL as webURL, ZHOSTNAME as hostname
    FROM ZSNMPDEVICERECORD ORDER BY ZLASTSEENAT DESC;")"
SNMP="$(jq -n --argjson total "$SNMP_TOTAL" --argjson rows "$SNMP_ROWS" '{snmpDevices: {totalCount: $total, recent: $rows}}')"

step "Reading DHCP leases"
# ZDNSSERVERS is a BLOB (SwiftData's [String] encoding) -- not human
# readable as plain SQL text, so it's skipped here. The Events log
# already narrates DHCP changes in plain text separately.
DHCP="$(section dhcpLeases ZDHCPLEASERECORD \
    "ZINTERFACENAME as interfaceName, ZSERVERIDENTIFIER as serverIdentifier,
     ZASSIGNEDADDRESS as assignedAddress, ZSUBNETMASK as subnetMask,
     ZBROADCASTADDRESS as broadcastAddress, ZROUTER as router,
     ZDOMAINNAME as domainName, ZLEASESECONDS as leaseSeconds,
     ZT1SECONDS as t1Seconds, ZT2SECONDS as t2Seconds, ZTRANSACTIONID as transactionID,
     datetime(ZOBSERVEDAT + 978307200,'unixepoch','localtime') as observedAt,
     datetime(ZFIRSTOBSERVEDAT + 978307200,'unixepoch','localtime') as firstObservedAt,
     ZNETWORKFINGERPRINT as networkFingerprint" \
    ZOBSERVEDAT)"

step "Reading Network Quality (RPM) history"
NETQUAL="$(section networkQuality ZNETWORKQUALITYRECORD \
    "ZDOWNLOADMBPS as downloadMbps, ZUPLOADMBPS as uploadMbps,
     datetime(ZTESTEDAT + 978307200,'unixepoch','localtime') as testedAt,
     ZDOWNLOADRESPONSIVENESSRPM as downloadResponsivenessRPM,
     ZUPLOADRESPONSIVENESSRPM as uploadResponsivenessRPM,
     ZCOMBINEDRESPONSIVENESSRPM as combinedResponsivenessRPM,
     ZBASERTTMS as baseRTTMs, ZDOWNLOADBYTESTRANSFERRED as downloadBytesTransferred,
     ZUPLOADBYTESTRANSFERRED as uploadBytesTransferred, ZSOURCE as source,
     ZNETWORKFINGERPRINT as networkFingerprint" \
    ZTESTEDAT)"

step "Reading public IP history"
PUBLICIP="$(section publicIP ZPUBLICIPRECORD \
    "ZIPADDRESS as ipAddress, datetime(ZOBSERVEDAT + 978307200,'unixepoch','localtime') as observedAt" \
    ZOBSERVEDAT)"

step "Reading provider edge history"
PROVIDEREDGE="$(section providerEdge ZPROVIDEREDGERECORD \
    "ZADDRESS as address, ZHOSTNAME as hostname,
     datetime(ZOBSERVEDAT + 978307200,'unixepoch','localtime') as observedAt,
     ZNETWORKFINGERPRINT as networkFingerprint" \
    ZOBSERVEDAT)"

step "Assembling export"
OUTPUT_FILE="$OUTPUT_DIR/diagnostic-$(date +%Y%m%d-%H%M%S).json"
jq -n \
    --arg exportedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg privacy "PRIVATE — contains real network identifiers (IPs, router MAC via the network fingerprint, SNMP descriptors). Do not post or share this file publicly." \
    --argjson network "$NETWORK" \
    --argjson events "$EVENTS" \
    --argjson connectivity "$CONNECTIVITY" \
    --argjson snmp "$SNMP" \
    --argjson dhcp "$DHCP" \
    --argjson netqual "$NETQUAL" \
    --argjson publicip "$PUBLICIP" \
    --argjson provideredge "$PROVIDEREDGE" \
    '{exportedAt: $exportedAt, privacy: $privacy, network: $network}
     + $events + $connectivity + $snmp + $dhcp + $netqual + $publicip + $provideredge' \
    > "$OUTPUT_FILE"

print
print -r -- "Saved to $OUTPUT_FILE"
print -r -- "PRIVATE — contains real network identifiers. Do not post or share this file publicly."
