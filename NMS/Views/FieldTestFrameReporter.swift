import SwiftUI

/// Debug-only: logs a view's own on-screen frame to `ui-state.log` via
/// `UIStateLogger`, so an external script can read a row's exact position
/// instead of finding it live.
///
/// **Exists specifically to avoid a known-flaky mechanism, not as a
/// generic convenience.** The obvious way to find a UI row's position from
/// outside the app is `osascript`/System Events walking `entire contents
/// of window` and matching `AXIdentifier` — but `PUNCHLIST.md` documents
/// that exact mechanism repeatedly returning zero elements in this project
/// before, root cause never diagnosed. Since NMS is the process being
/// inspected, it can report its own frame directly instead — no external
/// Accessibility tree-walk needed for this at all. `script/
/// capture-doc-scenarios.sh` is the one reader of these log lines today.
///
/// **Not the same shape as the `GeometryReader`/`PreferenceKey` round-trip
/// this project already tried and abandoned once** (`ContentView.swift`'s
/// `tileHeight` doc comment — deemed "increasingly bespoke" for
/// reconciling independent tiles' heights). That was a measured value
/// feeding back into layout, a real round-trip. This is one-directional
/// and purely observational — measure, log a string, nothing reads it back
/// into any view's own layout — so it doesn't carry that complexity.
extension View {
    /// `id` becomes `"fieldTest.frame.\(id)"` in the log, e.g.
    /// `"fieldTest.frame.networkHealth.row.dns"`. Logs on first appearance
    /// and again on any frame change, matching `UIStateLogger`'s existing
    /// "log every write, not just changes that matter" philosophy — a
    /// script reading the file only ever wants the *latest* line anyway.
    ///
    /// Coordinates are read in the `"nmsWindow"` named coordinate space
    /// (`ContentView.body`'s own root declares it) rather than `.global`,
    /// whose exact semantics (window-relative vs. screen-relative) aren't
    /// precisely documented — a named space anchored at a known view
    /// removes that ambiguity outright.
    func reportFrameForFieldTest(_ id: String) -> some View {
        #if DEBUG
        return background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { FieldTestFrameReporter.log(id, geo.frame(in: .named("nmsWindow"))) }
                    .onChange(of: geo.frame(in: .named("nmsWindow"))) { _, frame in
                        FieldTestFrameReporter.log(id, frame)
                    }
            }
        )
        #else
        return self
        #endif
    }
}

#if DEBUG
private enum FieldTestFrameReporter {
    static func log(_ id: String, _ frame: CGRect) {
        let formatted = "x=\(frame.origin.x) y=\(frame.origin.y) width=\(frame.width) height=\(frame.height)"
        UIStateLogger.record("fieldTest.frame.\(id)", formatted)
    }
}
#endif
