import XCTest

/// Smoke tests for the main window shell.
final class MainWindowUITests: XCTestCase {
    private var app: XCUIApplication?

    override func setUp() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        self.app = app
    }

    override func tearDown() {
        app?.terminate()
        app = nil
    }

    func testSidebarListsTopLevelDestinations() throws {
        let window = try XCTUnwrap(app).windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        for identifier in ["sidebar.devices", "sidebar.profiles", "sidebar.permissions"] {
            XCTAssertTrue(window.descendants(matching: .any)[identifier].exists, "missing \(identifier)")
        }
    }

    func testSelectingPermissionsShowsPermissionOverview() throws {
        let window = try XCTUnwrap(app).windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        window.descendants(matching: .any)["sidebar.permissions"].click()

        XCTAssertTrue(window.staticTexts["Permissions"].waitForExistence(timeout: 5))
    }
}
