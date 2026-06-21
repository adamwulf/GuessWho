import XCTest

/// Smoke-level UI tests for the People / Organizations / Events tab UI.
///
/// These tests assume the simulator has Contacts permission granted for the
/// app and that the runtime ships with the default address-book seed
/// (Anna Haro, Daniel Higgins, Hank Zakroff, John Appleseed, Kate Bell,
/// David Taylor) — the seed every simulator runtime has shipped with for
/// years. If you wipe the address book or run on a runtime with a
/// different seed, the `contactRowAppears` assertion will fail; replace
/// the literal with a name present in your seed.
final class GuessWhoUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    // MARK: - Tabs

    func test_threeTabsArePresent() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["People"].waitForExistence(timeout: 5)
            || app.staticTexts["People"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["Organizations"].exists
            || app.staticTexts["Organizations"].exists)
        XCTAssertTrue(app.buttons["Events"].exists
            || app.staticTexts["Events"].exists)
    }

    func test_peopleTabIsDefault() {
        let app = launchApp()
        // The People navigation bar title should be visible immediately
        // after launch — People is the leading tab.
        XCTAssertTrue(app.navigationBars["People"].waitForExistence(timeout: 5))
    }

    func test_switchingToOrganizationsTabShowsOrganizationsTitle() {
        let app = launchApp()
        let orgsTab = app.buttons["Organizations"].firstMatch
        XCTAssertTrue(orgsTab.waitForExistence(timeout: 5))
        orgsTab.tap()
        XCTAssertTrue(app.navigationBars["Organizations"].waitForExistence(timeout: 5))
    }

    func test_eventsTabShowsComingSoonPlaceholder() {
        let app = launchApp()
        let eventsTab = app.buttons["Events"].firstMatch
        XCTAssertTrue(eventsTab.waitForExistence(timeout: 5))
        eventsTab.tap()
        XCTAssertTrue(app.staticTexts["Events Coming Soon"].waitForExistence(timeout: 5))
    }

    // MARK: - Search

    func test_searchFieldFiltersPeopleList() {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["People"].waitForExistence(timeout: 5))

        // Some simulator runtimes hide the search field behind a swipe-down
        // gesture; nudge it into view if needed.
        let firstRow = app.cells.firstMatch
        if firstRow.exists {
            firstRow.swipeDown()
        }

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("Kate")

        // After filtering, Kate Bell should remain visible; Anna Haro should
        // not. Using staticTexts because the row's primary label is a Text
        // view — XCUI surfaces it as a static text.
        XCTAssertTrue(app.staticTexts["Kate Bell"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Anna Haro"].exists)
    }

    func test_searchClearShowsAllAgain() {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["People"].waitForExistence(timeout: 5))

        let firstRow = app.cells.firstMatch
        if firstRow.exists {
            firstRow.swipeDown()
        }

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("Kate")
        XCTAssertTrue(app.staticTexts["Kate Bell"].waitForExistence(timeout: 3))

        let clearButton = searchField.buttons["Clear text"]
        if clearButton.exists {
            clearButton.tap()
        } else {
            // Older OS variant: select all + delete
            searchField.press(forDuration: 0.6)
            app.menuItems["Select All"].tap()
            searchField.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        XCTAssertTrue(app.staticTexts["Anna Haro"].waitForExistence(timeout: 5))
    }

    // MARK: - Navigation

    func test_tappingPersonShowsDetailScreen() {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["People"].waitForExistence(timeout: 5))

        let kateCell = app.staticTexts["Kate Bell"].firstMatch
        XCTAssertTrue(kateCell.waitForExistence(timeout: 5))
        kateCell.tap()

        // Detail view's nav title equals the contact's display name.
        XCTAssertTrue(app.navigationBars["Kate Bell"].waitForExistence(timeout: 5))
    }
}
