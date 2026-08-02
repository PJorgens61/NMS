# NMS — notes for Claude

Full project context lives in `README.md` (what this is), `DESIGN-NOTES.md`
(why things are built the way they are — read before changing anything
that looks odd, it's very likely deliberate), `PUNCHLIST.md` (open work),
and `BUGS.md`. This file is only for things that are specifically about
*how an agent* should work with this repo, not general project docs.

## Testing

- `script/test-quick.sh` — unit tests only, seconds. Run after any change.
- `script/test-max.sh` — unit tests + UI tests + live network scenarios,
  a couple of minutes. Run before considering a change to shared/view-model
  wiring done.
- `script/build-and-run.sh --run` — builds and launches the real app.
  Refuses to launch over an already-running instance; quit it first
  (`osascript -e 'tell application "NMS" to quit'`).

## Driving the live app via Accessibility (macOS UI scripting)

Every interactive button and toggle in the app has a stable
`.accessibilityIdentifier` (dot-namespaced, e.g. `footer.networks`,
`snmpDevices.scan`, `knownNetworks.review.<fingerprint>`,
`preferences.saas.service.<name>`) — grep `NMS/Views/*.swift` for
`accessibilityIdentifier` for the full current list. **Use these, not
screen coordinates and not the visible button text or `.accessibilityLabel`**
— labels are written for VoiceOver clarity and don't always match the
visible text (e.g. the "Networks…" button's label is "Known Networks"),
so a lookup by label or text is fragile in exactly the way the identifier
isn't.

Two real gotchas discovered the hard way, both worth knowing before you
spend time rediscovering them:

1. **`button "X" of window "Y"` (direct name lookup) does not reliably
   find buttons nested inside SwiftUI's view hierarchy.** Walk the tree
   instead:

   ```applescript
   tell application "System Events"
       tell process "NMS"
           tell window "NMS"
               repeat with el in (entire contents)
                   try
                       if role of el is "AXButton" then
                           if (value of attribute "AXIdentifier" of el) is "footer.networks" then
                               click el
                           end if
                       end if
                   end try
               end repeat
           end tell
       end tell
   end tell
   ```

2. **A `.sheet(item:)` (e.g. Network Review, presented from Known
   Networks) is not included in its presenting window's `entire contents`.**
   If a button lives in a sheet, target the SHEET, not the window that
   presented it — same repeat-loop pattern, but:

   ```applescript
   tell window "Known Networks" to entire contents  -- won't find the sheet's buttons
   -- instead, once the sheet is open, coordinate-click resolves it as:
   --   "button 1 of group 1 of sheet 1 of window Known Networks ..."
   -- so search sheet 1 of that window specifically if a tree-walk is needed.
   ```

   In practice a one-off coordinate click (get the window's `position`/
   `size` via System Events, `screencapture -R` that region, read the
   PNG, compute the point) is often faster than fighting the sheet's
   AX tree for a single click.

## Screenshots

Always capture a specific window's bounds, never the full screen —
`screencapture -x` alone captures every window on the display, including
unrelated apps and other content that may be sensitive or just noise:

```bash
POS_SIZE=$(osascript -e 'tell application "System Events" to tell process "NMS" to return (position of window 1) & (size of window 1)')
# then: screencapture -x -R<x>,<y>,<w>,<h> out.png
```

Screenshots are 2x (Retina) pixel dimensions relative to the point
coordinates you captured with — divide by 2 before converting a pixel
position you read off the image back into a point for `click at {x,y}`.

## Permissions

Accessibility and Screen Recording are required for the above and are
already granted to this environment's shell process — if either starts
failing, that's what to check first (System Settings → Privacy &
Security).
