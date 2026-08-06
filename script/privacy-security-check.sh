#!/usr/bin/env bash
#
# Re-runs the checks from docs/reviews/*-privacy-security-review.md and
# *-trust-assessment.md against the current source tree, and diffs the
# output against script/privacy-security-baseline.txt -- the snapshot
# from the last time a human/AI actually read through and signed off on
# these findings. A clean diff means nothing privacy/security-relevant
# has changed since that review; any diff is exactly the delta a
# follow-up review needs to look at, not a reason to redo the whole
# thing from scratch. See docs/reviews/2026-08-03-privacy-security-
# review.md's "Suggested next step" for why this exists.
#
# Usage:
#   script/privacy-security-check.sh                    # check against baseline
#   script/privacy-security-check.sh --update-baseline   # after a review
#                                                         # confirms the new
#                                                         # output is fine
#
# Exit codes: 0 = matches baseline (or baseline just written),
#             1 = no baseline yet and none requested,
#             2 = diverges from baseline.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

BASELINE="script/privacy-security-baseline.txt"

section() { printf '## %s\n' "$1"; }

# Every check below is read-only -- greps, a couple of `find`s, one `cat`
# -- and matches a specific claim in one of the two review docs, so a
# diff here points straight at which claim needs a fresh look. `|| true`
# throughout: an expected *empty* result (e.g. no telemetry SDKs found)
# is itself the finding, not a reason for `set -e` to abort the snapshot
# before later sections run.
snapshot() {
    section "license"
    head -5 LICENSE

    section "spm-dependencies"
    find . -iname "Package.swift" -o -iname "Package.resolved"
    grep -c "XCRemoteSwiftPackageReference\|XCSwiftPackageProductDependency" \
        NMS.xcodeproj/project.pbxproj || true

    section "network-endpoints"
    grep -rhoE 'https?://[a-zA-Z0-9./_-]+' NMS --include="*.swift" | sort -u

    section "telemetry-sdks"
    grep -rniE "firebase|sentry|mixpanel|amplitude|crashlytics|segment\.io|bugsnag|appcenter" \
        NMS --include="*.swift" || true

    section "shelled-out-binaries"
    grep -rhoE '"/usr/[a-zA-Z/]+"|"/sbin/[a-zA-Z/]+"' NMS/Services --include="*.swift" \
        | sort -u

    section "shell-string-risk"
    grep -rn "bin/sh\|bash -c\|/bin/bash" NMS/ || true

    section "app-sandbox-and-entitlements"
    grep -n "ENABLE_APP_SANDBOX" NMS.xcodeproj/project.pbxproj | sort -u
    find . -iname "*.entitlements" -not -path "./.git/*"
    [[ -f NMS/NMS.entitlements ]] && cat NMS/NMS.entitlements || true

    section "oauth-signin"
    grep -rln "GoogleCloud\|OAuth\|ASWebAuthenticationSession" NMS --include="*.swift" || true

    section "hardcoded-secrets"
    grep -rniE "api_?key|secret|password|token|bearer" NMS --include="*.swift" \
        | grep -viE "keychain" || true

    section "ci-workflows"
    ls .github/workflows/*.yml | sort
}

CURRENT="$(mktemp)"
trap 'rm -f "$CURRENT"' EXIT
snapshot > "$CURRENT"

if [[ "${1:-}" == "--update-baseline" ]]; then
    cp "$CURRENT" "$BASELINE"
    printf 'Baseline updated: %s\n' "$BASELINE"
    exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
    printf 'No baseline yet -- current output:\n\n'
    cat "$CURRENT"
    printf '\nReview it, then run with --update-baseline to record it.\n'
    exit 1
fi

if diff -u "$BASELINE" "$CURRENT"; then
    printf 'No changes since the baseline captured at the last review.\n'
    exit 0
else
    printf '\nCHANGED since the last reviewed baseline (%s) -- the lines\n' "$BASELINE"
    printf 'above are what to re-check by hand before trusting this build.\n'
    exit 2
fi
