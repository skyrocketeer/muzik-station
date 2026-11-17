import XCTest

final class OnboardingVisualTests: XCTestCase {
    func testFolderAndAudioPickersOpen() {
        let app = XCUIApplication()
        app.launchEnvironment["LOCALWAVE_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["LOCALWAVE_REFERENCE_FIXTURE"] = "1"
        app.launchEnvironment["LOCALWAVE_REFERENCE_SCREEN"] = "onboarding"
        app.launch()
        defer { app.terminate() }
        let folder = app.buttons["Choose a folder"]
        XCTAssertTrue(folder.waitForExistence(timeout: 20))
        folder.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Folder picker should open")
        cancel.tap()
        let files = app.buttons["Pick some files"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Audio picker should open")
    }

    func testReferenceOnboardingDisclosureAndLibraryContinuation() {
        let app = XCUIApplication()
        app.launchEnvironment["LOCALWAVE_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["LOCALWAVE_REFERENCE_FIXTURE"] = "1"
        app.launchEnvironment["LOCALWAVE_REFERENCE_SCREEN"] = "onboarding"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Choose a folder"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["library-mode-Albums"].exists, "Onboarding must hide the underlying library from accessibility")
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "Reference onboarding normal light"
        initial.lifetime = .keepAlways
        add(initial)
        let drive = app.buttons["Google Drive not in the list?"]
        guard reveal(drive, in: app) else { return }
        drive.tap()
        XCTAssertTrue(app.staticTexts["Install the Google Drive app, then in Files tap Browse → ⋯ → Edit and turn on Google Drive."].waitForExistence(timeout: 5))
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "Reference onboarding Drive help expanded"
        expanded.lifetime = .keepAlways
        add(expanded)
        let explore = app.buttons["Explore the library"]
        guard reveal(explore, in: app) else { return }
        explore.tap()
        XCTAssertTrue(app.buttons["library-mode-Albums"].waitForExistence(timeout: 10))
    }

}
