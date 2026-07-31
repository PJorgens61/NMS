#!/usr/bin/env zsh
#
# Lists every bug report filed via NMS's footer Bug Report button, newest
# first -- build, severity, comment, and whether the screenshot it
# referenced is still on disk. Exists so a future session (Claude or
# otherwise) doesn't have to rediscover the store schema/paths by hand
# every time; see the "Bug reports" section this script is documented
# alongside in BUGS.md.
#
# Reads AppEventRecord.bugReportCaptured rows directly from the real
# store -- there's no other query interface for this data. Read-only,
# unlike save-fixture.sh: nothing here writes to or copies the real
# store, so no scratch-directory/checkpoint dance is needed.
#
# Two artifacts a report's message names but this script doesn't open:
#   - the screenshot PNG, in ~/Library/Logs/NMS/screenshots/
#   - (DEBUG builds only) a state-dump .txt with the same comment/build/
#     severity as a header, in ~/Library/Logs/NMS/state-dumps/ -- same
#     capture, a few milliseconds later, so its filename's timestamp can
#     differ from the screenshot's by a second if the two calls straddle
#     one; not worth exact-matching for that rare a case, so this only
#     confirms the screenshot (the one every build produces) exists.
#
# Usage: script/list-bug-reports.sh

set -euo pipefail

STORE=~/Library/"Application Support"/NMS/default.store
SCREENSHOTS=~/Library/Logs/NMS/screenshots

fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

[[ -f "$STORE" ]] || fail "no store found at $STORE -- has NMS been run at least once?"

count=$(sqlite3 "$STORE" "SELECT COUNT(*) FROM ZAPPEVENTRECORD WHERE ZKIND = 'bugReportCaptured';")
if [[ "$count" -eq 0 ]]; then
    printf 'No bug reports filed yet.\n'
    exit 0
fi

printf '%s bug report(s), newest first:\n\n' "$count"

sqlite3 -separator '|' "$STORE" \
  "SELECT datetime(ZOCCURREDAT + 978307200, 'unixepoch', 'localtime'), ZMESSAGE
   FROM ZAPPEVENTRECORD WHERE ZKIND = 'bugReportCaptured' ORDER BY ZOCCURREDAT DESC;" \
  | while IFS='|' read -r when message; do
      # message ends "...(NMS-<timestamp>.png)" -- pull just the filename
      # to check it's still on disk, without assuming anything else about
      # the message's shape (a comment could itself contain parentheses).
      filename=$(printf '%s' "$message" | grep -o 'NMS-[0-9-]*\.png' | tail -1)
      if [[ -n "$filename" && -f "$SCREENSHOTS/$filename" ]]; then
          marker="✓"
      elif [[ -n "$filename" ]]; then
          marker="✗ missing"
      else
          marker="?"
      fi
      printf '[%s] %s\n    %s\n\n' "$marker" "$when" "$message"
  done
