import XCTest

/// Helpers for driving the app from the screenshot tests. They match on the
/// accessibility identifiers and labels the app already has for VoiceOver
/// and these tests, so the tests drive the same UI a person uses.
extension XCTestCase {
    func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    /// Selects a tab. iPhone shows a tab bar; iPad can show the tabs as
    /// plain buttons at the top.
    func selectTab(_ title: String, in app: XCUIApplication) {
        let tabBarButton = app.tabBars.buttons[title]
        let button = tabBarButton.waitForExistence(timeout: 2) ? tabBarButton : app.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Tab '\(title)' not found")
        button.tap()
        settle()
    }

    /// Taps a segment of one of the Playground's pane pickers.
    func selectPane(_ title: String, in app: XCUIApplication) {
        let segment = app.segmentedControls.buttons[title].firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "Pane '\(title)' not found")
        segment.tap()
        settle()
    }

    /// Waits for any element whose label contains `text`.
    @discardableResult
    func waitForText(_ text: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "No element containing '\(text)'")
        return element
    }

    func element(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 5) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Element '\(identifier)' not found")
        return element
    }

    /// Scrolls the list until `element` can be tapped, then taps it.
    func scrollToAndTap(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.isHittable, "\(element) is not hittable after scrolling")
        element.tap()
        settle()
    }

    /// Taps the first button with the given accessibility label.
    func tapButton(labeled label: String, in app: XCUIApplication) {
        let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Button '\(label)' not found")
        button.tap()
        settle()
    }

    /// Puts the cursor at the end of a short text view's text. A tap below
    /// and to the right of the last line lands after its last character.
    func placeCursorAtEnd(of textView: XCUIElement) {
        textView.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.92)).tap()
        settle()
    }

    /// Captures the whole Simulator screen and attaches it to the result
    /// bundle under a sortable name. Tools/organize-screenshots.py extracts
    /// it after `xcresulttool export attachments`. Names never contain "_".
    func captureScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A short pause for sheet, tab and keyboard animations to finish, which
    /// polling for existence alone does not cover.
    func settle() {
        Thread.sleep(forTimeInterval: 0.8)
    }
}
