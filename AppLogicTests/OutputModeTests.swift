import Foundation
import JQEngine
import XCTest
#if canImport(AppCore)
@testable import AppCore
#endif

/// R5: what each output mode hands Shortcuts.
final class OutputModeTests: XCTestCase {
    private func results(_ texts: [String]) -> [JSON] {
        texts.map { try! JSONParser.parseSingle($0) }
    }

    func testOneItemPerResultKeepsEachResultsType() {
        let items = ShortcutsOutput.items(for: results([#""text""#, "42", "true", #"{"a":1}"#, "[1]", "null"]),
                                          mode: .itemPerResult, sortKeys: false)
        XCTAssertEqual(items.map(\.type), [.text, .number, .boolean, .dictionary, .list, .null])
        XCTAssertEqual(items.map(\.text), ["text", "42", "true", #"{"a":1}"#, "[1]", "null"])
    }

    func testOneItemPerResultSplitsASingleListIntoItems() {
        let items = ShortcutsOutput.items(for: results([#"[{"name":"a"},{"name":"b"}]"#]), mode: .itemPerResult, sortKeys: false)
        XCTAssertEqual(items.map(\.type), [.dictionary, .dictionary])
        XCTAssertEqual(items.map(\.text), [#"{"name":"a"}"#, #"{"name":"b"}"#])
    }

    func testOneJSONArrayHoldsEveryResult() {
        let single = ShortcutsOutput.values(for: results(["[1,2]"]), mode: .jsonArray, sortKeys: false)
        XCTAssertEqual(single, ["[1,2]"], "one result gives a list with one item")
        let many = ShortcutsOutput.values(for: results(["1", #""b""#]), mode: .jsonArray, sortKeys: false)
        XCTAssertEqual(many, ["1", "b"])
    }

    func testRawTextLines() {
        let values = ShortcutsOutput.values(for: results([#""Ada""#, "3", #"{"a":"x"}"#]), mode: .rawLines, sortKeys: false)
        XCTAssertEqual(values, ["Ada\n3\n{\"a\":\"x\"}"])
    }

    func testCompactAndPrettyJSON() {
        let input = results([#""Ada""#, #"{"b":1,"a":[2]}"#])
        XCTAssertEqual(ShortcutsOutput.values(for: input, mode: .compactJSON, sortKeys: false),
                       ["\"Ada\"\n{\"b\":1,\"a\":[2]}"])
        XCTAssertEqual(ShortcutsOutput.values(for: input, mode: .prettyJSON, sortKeys: true),
                       ["\"Ada\"\n{\n  \"a\": [\n    2\n  ],\n  \"b\": 1\n}"])
    }

    func testSortKeysAppliesToEveryMode() {
        let input = results([#"{"b":{"y":1,"x":2},"a":0}"#])
        XCTAssertEqual(ShortcutsOutput.values(for: input, mode: .jsonArray, sortKeys: true), [#"{"a":0,"b":{"x":2,"y":1}}"#])
        XCTAssertEqual(ShortcutsOutput.values(for: input, mode: .jsonArray, sortKeys: false), [#"{"b":{"y":1,"x":2},"a":0}"#])
    }

    func testNoOutputIsAnEmptyListOrEmptyText() {
        XCTAssertEqual(ShortcutsOutput.values(for: [], mode: .itemPerResult, sortKeys: false), [])
        XCTAssertEqual(ShortcutsOutput.values(for: [], mode: .jsonArray, sortKeys: false), [])
        XCTAssertEqual(ShortcutsOutput.values(for: [], mode: .rawLines, sortKeys: false), [""])
        XCTAssertEqual(ShortcutsOutput.values(for: [], mode: .prettyJSON, sortKeys: false), [""])
    }

    func testNonASCIIStaysUnescaped() {
        XCTAssertEqual(ShortcutsOutput.values(for: results([#"{"city":"Zürich 東京"}"#]), mode: .jsonArray, sortKeys: false),
                       ["{\"city\":\"Zürich 東京\"}"])
    }

    func testBigIntegersKeepTheirDigits() {
        XCTAssertEqual(ShortcutsOutput.values(for: results(["1234567890123456789"]), mode: .itemPerResult, sortKeys: false),
                       ["1234567890123456789"])
    }

    func testOutputModeDecodesUnknownValuesAsTheDefault() throws {
        let json = #"{"id":"6D1F1B4A-5D0B-4C70-9A5B-2B6C1E0F3A11","name":"x","filter":".","outputMode":"spreadsheet"}"#
        let decoded = try JSONDecoder().decode(SavedFilter.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.outputMode, .itemPerResult)
    }
}
