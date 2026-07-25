#!/usr/bin/env bash
#
# Build, sign, notarize, and staple a distributable NMS.app.
#
# One-time prerequisites (see README, "Signed and notarized releases"):
#
#   1. A "Developer ID Application" certificate in your login keychain.
#      Xcode > Settings > Accounts > Manage Certificates > + .
#
#   2. Notarization credentials stored under a keychain profile:
#        xcrun notarytool store-credentials "NMS-notary" \
#          --key ~/private_keys/AuthKey_XXXXXXXX.p8 \
#          --key-id XXXXXXXX --issuer XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
#
# No credential is stored in this repository. The script references only the
# profile *name*; the secrets stay in your keychain.
#
# Environment overrides: NOTARY_PROFILE, TEAM_ID, BUILD_DIR.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTARY_PROFILE="${NOTARY_PROFILE:-NMS-notary}"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"

ARCHIVE="$BUILD_DIR/NMS.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
APP="$EXPORT_DIR/NMS.app"
ZIP="$BUILD_DIR/NMS.zip"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------
# Checked up front: a missing certificate otherwise surfaces as an opaque
# xcodebuild failure several minutes into the archive.

step "Checking signing identity"
if [[ -z "${TEAM_ID:-}" ]]; then
    TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -nE 's/.*"Developer ID Application: .*\(([A-Z0-9]{10})\)".*/\1/p' \
        | head -1)"
fi
[[ -n "$TEAM_ID" ]] || fail "no 'Developer ID Application' identity in the keychain.
  Add one via Xcode > Settings > Accounts > Manage Certificates > +,
  or set TEAM_ID explicitly if you know the team but the regex missed it.
  Current identities:
$(security find-identity -v -p codesigning 2>&1 | sed 's/^/    /')"
echo "Team ID: $TEAM_ID"

step "Checking notarization credentials"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --limit 1 >/dev/null 2>&1 \
    || fail "keychain profile '$NOTARY_PROFILE' not found or not valid.
  Create it with 'xcrun notarytool store-credentials \"$NOTARY_PROFILE\" ...'
  (see the header of this script), or set NOTARY_PROFILE to an existing one."

# --- Build -----------------------------------------------------------------
# 'archive' rather than 'build': a plain build narrows to the host arch even
# with ARCHS set. See README, "Building a universal binary".

step "Archiving (universal)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"
xcodebuild archive \
    -project "$PROJECT_DIR/NMS.xcodeproj" \
    -scheme NMS \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    DEVELOPMENT_TEAM="$TEAM_ID"

step "Exporting signed app"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"

[[ -d "$APP" ]] || fail "export produced no app bundle at $APP"

step "Verifying architectures"
lipo -info "$APP/Contents/MacOS/NMS"

# --- Notarize --------------------------------------------------------------
# ditto, not zip: it preserves the bundle's symlinks and extended attributes.

step "Submitting for notarization (this takes a few minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

# Stapling writes the ticket into the bundle, so the zip must be rebuilt
# afterwards -- the one just submitted does not contain the ticket.
step "Stapling ticket"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# --- Verify ----------------------------------------------------------------
# What Gatekeeper will do on someone else's Mac, checked here instead of after
# they have already downloaded it.

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

step "Verifying Gatekeeper acceptance"
spctl -a -vvv -t install "$APP"

step "Verifying stapled ticket"
xcrun stapler validate "$APP"

printf '\nDone.\n  app: %s\n  zip: %s\n' "$APP" "$ZIP"
