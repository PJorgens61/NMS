# config.json — Claude notes

Read fresh on every Path Discovery run by `GlobalpingReverseTraceService
.loadConfig()` — edit this file and click "Path Discovery…" again, no
rebuild needed. Falls back to the hardcoded `defaultConfig` in that file
if this is missing/unreadable/fails to parse.

## Fields

- `probeCount` — total probes across all `locations` combined (sent as
  the request's top-level `limit`, not per-location).
- `locations` — list of Globalping "magic" strings. Each becomes its own
  `{"magic": ...}` location object, so multiple entries mix probes from
  each rather than requiring one value. Confirmed live (2026-08-06):
  `["USA", "World"]` at `probeCount: 5` returned a real 3 US / 2 DE
  split, not all-USA — `"World"` is a valid magic value for "anywhere,"
  not just a placeholder. Also confirmed live the same day:
  `["USA", "Europe", "Asia", "South America"]` at `probeCount: 5`
  returned US/DE/JP/BR (2 of the 5 individual probes failed that
  particular run — a transient trace failure, not a sign the location
  itself was invalid). Continent names work the same way as `"USA"`/
  `"World"`. Also confirmed live the same day: `probeCount: 10` at the
  same 4-region mix returned a real 10-way spread (US×3, DE×2, JP×2,
  BR×2, FI×1), all finished cleanly; `probeCount: 20` returned 9
  countries (US×5, DE×4, BR×4, JP×2, FI/SG/IN/TW/CL×1 each), 19 of 20
  finished (1 transient trace failure, same normal rate as smaller runs)
  — no sign of a Globalping free-tier cap anywhere up to 20.
- `maxAttempts`/`delaySeconds` — `fetchResult`'s poll loop (measurement
  is async; Globalping returns an ID immediately, poll until `status:
  "finished"`).
- `timeoutSeconds` — shared `URLRequest.timeoutInterval` for both the
  create and poll requests.

## Trying a location combo before committing it here

`api.globalping.io` is public and unauthenticated — cheapest way to
check what a `locations` combo actually returns before editing this
file:

```bash
curl -s -X POST https://api.globalping.io/v1/measurements \
  -H "Content-Type: application/json" \
  -d '{"type":"traceroute","target":"1.1.1.1","locations":[{"magic":"USA"},{"magic":"World"}],"limit":5}'
# poll: curl -s https://api.globalping.io/v1/measurements/<id>
```

Other magic values that work the same way as `"USA"`/`"World"`:
continent names (`"Europe"`, `"Asia"`), individual country names/codes,
city names — whatever Globalping's own magic matcher accepts. Not
verified exhaustively here; the two above are the ones actually tested
against this app.
