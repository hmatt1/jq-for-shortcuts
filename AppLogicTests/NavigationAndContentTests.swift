import Foundation
import JQEngine
import XCTest
#if canImport(AppCore)
@testable import AppCore
#endif

final class NavigationAndContentTests: XCTestCase {
    // MARK: Links and handoff

    func testDestinationsRoundTripThroughURLs() {
        let id = UUID()
        let destinations: [AppDestination] = [.playground, .library, .reference, .sharedInput,
                                              .clipboardRunner(savedFilterID: nil), .clipboardRunner(savedFilterID: id)]
        for destination in destinations {
            XCTAssertEqual(AppDestination(url: destination.url), destination, destination.url.absoluteString)
        }
        XCTAssertNil(AppDestination(url: URL(string: "https://example.com/playground")!))
    }

    func testPendingNavigationIsTakenOnce() {
        _ = useTemporaryContainer()
        PendingNavigation.post(.clipboardRunner(savedFilterID: nil))
        XCTAssertEqual(PendingNavigation.take(), .clipboardRunner(savedFilterID: nil))
        XCTAssertNil(PendingNavigation.take())
    }

    func testInboxHandsOverSharedInputOnce() throws {
        _ = useTemporaryContainer()
        try PlaygroundInbox.deposit(Data(#"{"shared": true}"#.utf8), name: "export.json")
        XCTAssertTrue(PlaygroundInbox.hasItem)
        let item = PlaygroundInbox.take()
        XCTAssertEqual(item?.name, "export.json")
        XCTAssertEqual(item.map { String(decoding: $0.data, as: UTF8.self) }, #"{"shared": true}"#)
        XCTAssertNil(PlaygroundInbox.take(), "the input is not kept (R2.11)")
    }

    func testInboxDropsStaleItems() throws {
        _ = useTemporaryContainer()
        try PlaygroundInbox.deposit(Data("[]".utf8), name: nil)
        XCTAssertNil(PlaygroundInbox.take(now: Date().addingTimeInterval(PlaygroundInbox.maximumAge + 60)))
        XCTAssertFalse(PlaygroundInbox.hasItem)
    }

    // MARK: Arguments helpers

    func testArgumentNames() {
        XCTAssertTrue(FilterArguments.isValidName("limit"))
        XCTAssertTrue(FilterArguments.isValidName("_x9"))
        XCTAssertFalse(FilterArguments.isValidName("9lives"))
        XCTAssertFalse(FilterArguments.isValidName("my var"))
        XCTAssertFalse(FilterArguments.isValidName("café"))
        XCTAssertFalse(FilterArguments.isValidName(""))
    }

    func testAddingAnArgumentKeepsExistingOnes() throws {
        let text = FilterArguments.adding("limit", value: .number(2), to: #"{"term": "jq"}"#)
        XCTAssertEqual(try FilterArguments.parse(text).keys.sorted(), ["limit", "term"])
        XCTAssertEqual(FilterArguments.adding("x", to: ""), "{\n  \"x\": \"\"\n}")
    }

    // MARK: Bundled content

    func testContentLibraryLoads() {
        let library = TestContent.library
        XCTAssertFalse(library.sample.filter.isEmpty)
        XCTAssertEqual(library.presets.count, 9, "R6.13")
        XCTAssertEqual(library.gallery.count, 6, "R10")
        XCTAssertGreaterThan(library.cheatSheet.flatMap(\.entries).count, 50)
        XCTAssertFalse(library.differences.isEmpty, "R4.12")
    }

    func testCheatSheetSearch() {
        let library = TestContent.library
        let matches = library.cheatSheet(matching: "gsub")
        XCTAssertFalse(matches.isEmpty)
        XCTAssertTrue(matches.flatMap(\.entries).allSatisfy {
            $0.filter.contains("gsub") || $0.title.localizedCaseInsensitiveContains("gsub")
                || $0.explanation.localizedCaseInsensitiveContains("gsub")
        })
        XCTAssertEqual(library.cheatSheet(matching: "  ").count, library.cheatSheet.count)
    }

    /// The Playground's first screen (R1.1) shows the sample's stored result.
    func testSampleProducesItsStoredResult() async {
        let sample = TestContent.library.sample
        let outcome = await run(sample.filter, sample.input, context: .playground)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(texts(outcome.results), sample.expected)
    }

    /// Every preset produces its stored output through the app's run path.
    func testPresetsRunThroughTheRunner() async {
        for preset in TestContent.library.presets {
            let outcome = await run(preset.filter, preset.input, context: .playground)
            XCTAssertNil(outcome.error, preset.id)
            XCTAssertEqual(texts(outcome.results), preset.expected, preset.id)
        }
    }
}
