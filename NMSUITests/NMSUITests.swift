//
//  NMSUITests.swift
//  NMSUITests
//

import XCTest

final class NMSUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {}

    /// Replaces the Xcode-generated `testExample()`, which launched the
    /// app and asserted nothing at all — real noise, not real coverage
    /// (see DESIGN-NOTES.md's "Testing races" section for how this was
    /// found: checked directly, every line still matched the unmodified
    /// template).
    ///
    /// Leans on `MenuBarLabel`'s existing `#if DEBUG` auto-open-window
    /// behavior (`NMSApp.swift`) rather than driving the actual menu-bar
    /// status item — `MenuBarExtra` icons live outside the app's own
    /// window hierarchy and are notoriously unreliable to query via
    /// `XCUIApplication.statusItems` across macOS versions. UI tests
    /// build and run Debug by default, so that auto-open already fires
    /// on launch; this test only needs to wait for it and check real
    /// content, not drive the click itself.
    @MainActor
    func testWindowOpensWithRealContent() throws {
        let app = XCUIApplication()
        app.launch()

        // Generous timeout — the window auto-open is itself deferred one
        // run loop turn (see `MenuBarLabel`'s doc comment), and the first
        // real content only appears once the launch-time connectivity
        // round resolves.
        let networkHealthTile = app.staticTexts["Network Health"]
        XCTAssertTrue(
            networkHealthTile.waitForExistence(timeout: 10),
            "Network Health tile should appear once the auto-opened window renders real content"
        )

        // A second, independent anchor — the footer, not the tile grid —
        // so this doesn't just prove one lucky text match rendered but
        // the whole window (header through footer) came up intact.
        XCTAssertTrue(app.buttons["Quit"].exists, "footer should be present alongside the tile grid")

        app.terminate()
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
