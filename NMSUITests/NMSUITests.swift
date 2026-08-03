//
//  NMSUITests.swift
//  NMSUITests
//

import XCTest

final class NMSUITests: XCTestCase {
    private var scratchStorePath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let scratchStorePath {
            removeIsolatedStore(at: scratchStorePath)
        }
    }

    /// Replaces the Xcode-generated `testExample()`, which launched the
    /// app and asserted nothing at all — real noise, not real coverage
    /// (see DESIGN-NOTES.md's "Testing races" section for how this was
    /// found: checked directly, every line still matched the unmodified
    /// template).
    ///
    /// The window is the app's one main scene now (see the "rebuild NMS
    /// as a traditional single-window app" work in `PUNCHLIST.md`) — no
    /// menu-bar popover to open first, so this just launches and waits
    /// for real content to render.
    @MainActor
    func testWindowOpensWithRealContent() throws {
        let app = XCUIApplication()
        scratchStorePath = app.configureIsolatedStore()
        app.launch()

        // Generous timeout — the first real content only appears once
        // the launch-time connectivity round resolves. "Network," not
        // "Network Health" — renamed when Network Health and Info
        // merged into one tile (see `PUNCHLIST.md`'s "Network Health
        // and Info tiles" entry).
        let networkTile = app.staticTexts["Network"]
        XCTAssertTrue(
            networkTile.waitForExistence(timeout: 10),
            "Network tile should appear once the window renders real content"
        )

        // A second, independent anchor — the footer, not the tile grid —
        // so this doesn't just prove one lucky text match rendered but
        // the whole window (header through footer) came up intact.
        XCTAssertTrue(app.buttons["Quit"].exists, "footer should be present alongside the tile grid")

        app.terminate()
    }

    @MainActor
    func testLaunchPerformance() throws {
        let app = XCUIApplication()
        scratchStorePath = app.configureIsolatedStore()
        // This measures how long it takes to launch your application.
        // Reuses the same isolated app/store across every `measure`
        // iteration — each relaunch reads `launchArguments` fresh, so
        // one scratch path for the whole test is correct, not a leak.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }
}
