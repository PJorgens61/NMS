//
//  NMSUITestsLaunchTests.swift
//  NMSUITests
//

import XCTest

/// `runsForEachTargetApplicationUIConfiguration` below genuinely toggles
/// the *host Mac's* system appearance to sweep both light and dark for
/// screenshot automation — confirmed live, the hard way (real App Store
/// screenshot-automation boilerplate, unmodified since Xcode generated
/// it, but not a simulator setting: a live side effect on whoever's
/// machine runs `xcodebuild test`). Kept enabled deliberately — it's
/// real, if incidental, coverage of a genuinely open question
/// (`PUNCHLIST.md`'s "Do we need a dark mode for the app?", never
/// investigated), and the appearance change was explicitly accepted
/// rather than treated as a bug to route around.
///
/// `class func setUp()`/`tearDown()` attempt to capture and restore the
/// appearance active before this class's sweep — **known unreliable,
/// left in as best-effort rather than removed.** Confirmed live: the
/// restore needs the "Automation" TCC permission (`System Settings →
/// Privacy & Security → Automation`) for whichever process runs it, a
/// separate grant from Full Disk Access, and the test-runner process
/// (`NMSUITests-Runner`) gets a fresh identity every build — so even a
/// one-time grant likely doesn't survive a rebuild. Apple's own sweep
/// mechanism doesn't hit this wall because it uses a private,
/// pre-authorized path this code has no access to. If a run doesn't
/// restore correctly, switch back manually via Control Center or System
/// Settings — not something to keep fighting with more automation.
final class NMSUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    /// Read via System Events rather than `defaults read -g
    /// AppleInterfaceStyle` — that key is simply *absent* in light mode
    /// rather than set to any "Light" value, which would make "absent"
    /// ambiguous between "light mode" and "the read failed." System
    /// Events' `dark mode` property is a clean, always-present boolean.
    private static func isDarkModeActive() -> Bool {
        let script = "tell application \"System Events\" to tell appearance preferences to get dark mode"
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        return result.booleanValue
    }

    private static func setDarkModeActive(_ active: Bool) {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(active)"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    /// Captured once before any test in this class runs — not per-test,
    /// since the whole point is "what was true before this class's
    /// multi-configuration sweep started," which every test in the sweep
    /// shares.
    private static var appearanceBeforeSweep: Bool?

    override class func setUp() {
        super.setUp()
        appearanceBeforeSweep = isDarkModeActive()
    }

    override class func tearDown() {
        if let original = appearanceBeforeSweep {
            setDarkModeActive(original)
        }
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
