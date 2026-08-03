//
//  NMSUITestsLaunchTests.swift
//  NMSUITests
//

import XCTest

/// `runsForEachTargetApplicationUIConfiguration` used to override to
/// `true` here — real App Store screenshot-automation boilerplate,
/// unmodified since Xcode generated it, that genuinely toggles the
/// *host Mac's* system appearance to sweep both light and dark
/// (confirmed live: not a simulator setting, a live side effect on
/// whoever's machine runs `xcodebuild test`). Turned off deliberately,
/// on request: disruptive to a real dev machine's actual appearance
/// during ordinary test runs, for coverage of a question
/// (`PUNCHLIST.md`'s "Do we need a dark mode for the app?") that hasn't
/// even been investigated yet. `XCTestCase`'s own default for this
/// property is already `false`, so this class no longer overrides it at
/// all — `testLaunch` now just runs once, in whatever appearance is
/// already active, no toggling either way.
final class NMSUITestsLaunchTests: XCTestCase {
    private var scratchStorePath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let scratchStorePath {
            removeIsolatedStore(at: scratchStorePath)
        }
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        scratchStorePath = app.configureIsolatedStore()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
