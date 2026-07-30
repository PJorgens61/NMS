#!/usr/bin/env zsh
#
# Snapshots the real, live NMS store into script/fixtures/populated.store
# -- a realistic, populated fixture (known networks, SNMP devices, DHCP
# history) for tests that need pre-existing state rather than building it
# up from scratch. Complements script/scenarios.sh, which always starts
# from an empty scratch store; this is for the opposite case.
#
# Never touches the real store in place -- copies it (base file + WAL +
# shared-memory index) to a scratch location first, checkpoints the copy
# there to fold the WAL into one clean file, then moves just that file
# into script/fixtures/. The real store is only ever read from.
#
# script/fixtures/ is gitignored, deliberately: it contains real personal
# network data (MAC addresses, device hostnames, router info), and this
# repo is public. Re-run this any time you want a fresher/richer fixture
# -- e.g. after some real SNMP devices, DHCP history, or known networks
# have accumulated from normal use.
#
# Usage: script/save-fixture.sh

set -euo pipefail

REAL_STORE_DIR=~/Library/"Application Support"/NMS
REAL_STORE="$REAL_STORE_DIR/default.store"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES_DIR="$PROJECT_DIR/script/fixtures"
FIXTURE="$FIXTURES_DIR/populated.store"
SCRATCH_DIR="$(mktemp -d)"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }
cleanup() { rm -rf "$SCRATCH_DIR"; }
trap cleanup EXIT

[[ -f "$REAL_STORE" ]] || fail "no real store found at $REAL_STORE -- launch NMS at least once first"

step "Copying the real store to a scratch location"
cp "$REAL_STORE" "$SCRATCH_DIR/populated.store"
[[ -f "$REAL_STORE-wal" ]] && cp "$REAL_STORE-wal" "$SCRATCH_DIR/populated.store-wal"
[[ -f "$REAL_STORE-shm" ]] && cp "$REAL_STORE-shm" "$SCRATCH_DIR/populated.store-shm"

step "Checkpointing the copy (folds the WAL into one clean file)"
sqlite3 "$SCRATCH_DIR/populated.store" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null

step "Saving as the fixture"
mkdir -p "$FIXTURES_DIR"
cp "$SCRATCH_DIR/populated.store" "$FIXTURE"

step "Fixture contents"
sqlite3 "$FIXTURE" "SELECT 'KnownNetwork: ' || COUNT(*) FROM ZKNOWNNETWORK;"
sqlite3 "$FIXTURE" "SELECT 'SNMPDeviceRecord: ' || COUNT(*) FROM ZSNMPDEVICERECORD;"
sqlite3 "$FIXTURE" "SELECT 'DHCPLeaseRecord: ' || COUNT(*) FROM ZDHCPLEASERECORD;"
sqlite3 "$FIXTURE" "SELECT 'AppEventRecord: ' || COUNT(*) FROM ZAPPEVENTRECORD;"

printf '\nSaved to %s\n' "$FIXTURE"
