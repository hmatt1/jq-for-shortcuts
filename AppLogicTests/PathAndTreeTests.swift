import Foundation
import JQEngine
import XCTest
#if canImport(AppCore)
@testable import AppCore
#endif

/// The tree browser's paths (R6.4), wrappers (R6.5) and lazy rows (R6.6).
final class PathAndTreeTests: XCTestCase {
    func testPathExpressions() {
        XCTAssertEqual(JQPathBuilder.expression([]), ".")
        XCTAssertEqual(JQPathBuilder.expression([.key("data"), .key("items"), .index(3), .key("name")]), ".data.items[3].name")
        XCTAssertEqual(JQPathBuilder.expression([.index(0), .key("a")]), ".[0].a")
        XCTAssertEqual(JQPathBuilder.expression([.key("first name")]), #"."first name""#)
        XCTAssertEqual(JQPathBuilder.expression([.key("end")]), #"."end""#)
        XCTAssertEqual(JQPathBuilder.expression([.key("2fa")]), #"."2fa""#)
        XCTAssertEqual(JQPathBuilder.expression([.key("quote\"and\\slash")]), #"."quote\"and\\slash""#)
    }

    func testEveryPathExpressionRunsOnTheEngine() throws {
        let input = try JSONParser.parseSingle(#"{"first name": {"end": [{"2fa": true}]}}"#)
        let path = JQPathBuilder.expression([.key("first name"), .key("end"), .index(0), .key("2fa")])
        var out: [JSON] = []
        try JQFilter(path).run(input) { out.append($0) }
        XCTAssertEqual(out, [.bool(true)])
    }

    func testSuggestionsOutsideAnArrayAreJustThePath() {
        let suggestions = JQPathBuilder.suggestions(for: [.key("data"), .key("count")], value: .number(3))
        XCTAssertEqual(suggestions.map(\.expression), [".data.count"])
    }

    func testSuggestionsForAFieldOfAnArrayItem() {
        let suggestions = JQPathBuilder.suggestions(for: [.key("data"), .key("items"), .index(3), .key("name")], value: .string("b"))
        XCTAssertEqual(suggestions.map(\.kind), [.path, .everyItem, .map, .select])
        XCTAssertEqual(suggestions.map(\.expression), [
            ".data.items[3].name",
            ".data.items[].name",
            ".data.items | map(.name)",
            #".data.items[] | select(.name == "b")"#,
        ])
    }

    func testSuggestionsForAnArrayItemItself() throws {
        let item = try JSONParser.parseSingle(#"{"tags": [1], "status": "open"}"#)
        let suggestions = JQPathBuilder.suggestions(for: [.index(0)], value: item)
        XCTAssertEqual(suggestions.map(\.expression), [".[0]", ".[]", #".[] | select(.status == "open")"#])
    }

    // MARK: Tree

    func testChildrenAreBuiltOnDemand() throws {
        let value = try JSONParser.parseSingle(#"{"name": "Ada", "langs": ["en", "fr"], "address": {"city": "London"}}"#)
        let root = JSONTree.root(value)
        XCTAssertEqual(root.kind, .object(count: 3))
        let children = JSONTree.children(of: root)
        XCTAssertEqual(children.map(\.label), ["name", "langs", "address"])
        XCTAssertEqual(children.map(\.path), [".name", ".langs", ".address"])
        XCTAssertEqual(JSONTree.children(of: children[1]).map(\.path), [".langs[0]", ".langs[1]"])
        XCTAssertEqual(JSONTree.preview(children[1]), "[2 items]")
        XCTAssertEqual(JSONTree.accessibilityLabel(children[0]), #".name, "Ada""#)
    }

    func testLargeArraysAreSplitIntoRanges() {
        let value = JSON.array((0..<25_000).map { .number($0) })
        let root = JSONTree.root(value)
        let top = JSONTree.children(of: root)
        XCTAssertEqual(top.count, 3)
        XCTAssertEqual(top.map(\.label), ["[0…9999]", "[10000…19999]", "[20000…24999]"])
        let second = JSONTree.children(of: top[2])
        XCTAssertEqual(second.count, 50)
        XCTAssertEqual(second[0].label, "[20000…20099]")
        let leaves = JSONTree.children(of: second[0])
        XCTAssertEqual(leaves.count, 100)
        XCTAssertEqual(leaves[5].path, ".[20005]")
    }

    func testVisibleRowsFollowExpansion() throws {
        let value = try JSONParser.parseSingle(#"{"a": {"b": [1, 2]}, "c": 3}"#)
        let root = JSONTree.root(value)
        XCTAssertEqual(JSONTree.visibleRows(root: root, expanded: []).map(\.path), ["."])
        let rows = JSONTree.visibleRows(root: root, expanded: [".", ".a", ".a.b"])
        XCTAssertEqual(rows.map(\.path), [".", ".a", ".a.b", ".a.b[0]", ".a.b[1]", ".c"])
    }
}
