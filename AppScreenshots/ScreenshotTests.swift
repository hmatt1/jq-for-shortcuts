import XCTest

/// Captures the App Store screenshots listed in AppStore/screenshots.md.
/// Every test starts from the app's own first-launch state: the Playground
/// opens with the bundled sample (R1.1), so a fresh Simulator needs no setup.
final class ScreenshotTests: XCTestCase {
    /// A result of the sample filter on the sample input.
    private let sampleResult = "Dune by Frank Herbert"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Shot 1: the Playground at first launch, with the sample input, the
    /// sample filter and its results.
    func testPlayground() {
        let app = launchApp()
        waitForText(sampleResult, in: app)
        captureScreenshot(named: "01-playground")
    }

    /// Shot 2: the tree browser, with the list and its first item expanded.
    func testTreeBrowser() {
        let app = launchApp()
        waitForText(sampleResult, in: app)
        selectPane("Tree", in: app)
        element("treeBrowser", in: app)
        tapButton(labeled: "Expand", in: app)
        tapButton(labeled: "Expand", in: app)
        captureScreenshot(named: "02-tree")
    }

    /// Shot 3: an error under the filter, with its position underlined and
    /// the hint (R8.2). The cheat sheet's `.name` example becomes `.names[]`.
    func testErrorHint() {
        let app = launchApp()
        selectTab("Reference", in: app)
        scrollToAndTap(element("run-field", in: app), in: app)

        let editor = element("filterEditor", in: app)
        placeCursorAtEnd(of: editor)
        editor.typeText("s[]")
        element("filterError", in: app)
        settle()
        captureScreenshot(named: "03-error")
    }

    /// Shot 4: the Library after saving the sample filter, with the Presets
    /// below it (R1.3, R6.12, R6.13).
    func testLibrary() {
        let app = launchApp()
        waitForText(sampleResult, in: app)
        element("saveFilter", in: app).tap()

        let name = element("saveFilterName", in: app)
        name.tap()
        name.typeText("In-stock titles")
        element("confirmSave", in: app).tap()

        // The first save offers the example gallery once (R1.5).
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) {
            notNow.tap()
        }
        settle()

        selectTab("Library", in: app)
        element("savedFilter-In-stock titles", in: app)
        captureScreenshot(named: "04-library")
    }

    /// Shot 5: an example shortcut from the gallery (R10).
    func testGallery() {
        let app = launchApp()
        selectTab("Library", in: app)
        scrollToAndTap(element("openGallery", in: app), in: app)
        element("gallery-latest-release", in: app).tap()
        settle()
        captureScreenshot(named: "05-gallery")
    }

    /// Shot 6: the cheat sheet (R6.14).
    func testReference() {
        let app = launchApp()
        selectTab("Reference", in: app)
        element("run-identity", in: app)
        captureScreenshot(named: "06-reference")
    }
}
