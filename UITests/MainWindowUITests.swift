import XCTest

/// Smoke tests for the main window shell.
@MainActor
final class MainWindowUITests: XCTestCase {
    func testSidebarListsTopLevelDestinations() {
        let window = launchMainWindow()

        for identifier in [
            "sidebar.devices", "sidebar.mappings", "sidebar.profiles", "sidebar.permissions", "sidebar.recovery",
        ] {
            XCTAssertTrue(window.descendants(matching: .any)[identifier].exists, "missing \(identifier)")
        }
    }

    func testSelectingPermissionsShowsPermissionOverview() {
        let window = launchMainWindow()

        window.descendants(matching: .any)["sidebar.permissions"].click()

        XCTAssertTrue(window.staticTexts["Permissions"].waitForExistence(timeout: 5))
    }

    private func launchMainWindow() -> XCUIElement {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { @MainActor in app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        return window
    }
}
