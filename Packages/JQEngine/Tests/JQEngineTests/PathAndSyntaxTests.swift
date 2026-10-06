import Foundation
import XCTest
@testable import JQEngine

/// The public path API behind Get Value at Path and Set Value at Path, and
/// the highlighter behind the filter editor.
final class PathAndSyntaxTests: XCTestCase {
    private let document = TestRunner.json(#"{"data": {"items": [{"name": "a"}, {"name": "b"}, {"name": null}]}, "n": 1}"#)

    // MARK: Paths

    private func paths(_ expression: String, in value: JSON) throws -> [String] {
        let filter = try JQFilter(expression)
        var out: [String] = []
        try filter.runPaths(value) { out.append(JSONWriter.string(.array($0))) }
        return out
    }

    func testPathsOfASimpleExpression() throws {
        XCTAssertEqual(try paths(".data.items[1].name", in: document), [#"["data","items",1,"name"]"#])
        XCTAssertEqual(try paths(".", in: document), ["[]"])
    }

    func testPathsOfAnExpressionThatSelectsSeveralLocations() throws {
        XCTAssertEqual(try paths(".data.items[].name", in: document),
                       [#"["data","items",0,"name"]"#, #"["data","items",1,"name"]"#, #"["data","items",2,"name"]"#])
        XCTAssertEqual(try paths(".data.items[] | select(.name == \"b\")", in: document), [#"["data","items",1]"#])
    }

    func testPathsOfMissingKeysAreStillPaths() throws {
        XCTAssertEqual(try paths(".missing.deeper", in: document), [#"["missing","deeper"]"#])
    }

    func testNonPathExpressionsFail() throws {
        XCTAssertThrowsError(try paths(".n + 1", in: document)) { error in
            XCTAssertEqual((error as? JQRuntimeError)?.kind, .invalidPath)
        }
    }

    func testValueAtPath() throws {
        XCTAssertEqual(try document.value(at: [.string("data"), .string("items"), .number(1), .string("name")]), .string("b"))
        XCTAssertEqual(try document.value(at: [.string("nope")]), .null)
        XCTAssertThrowsError(try document.value(at: [.string("data"), .string("items"), .string("name")]))
    }

    func testSettingAValueCreatesMissingContainers() throws {
        let updated = try JSON.null.setting(.string("x"), at: [.string("a"), .number(2), .string("b")])
        XCTAssertEqual(JSONWriter.string(updated), #"{"a":[null,null,{"b":"x"}]}"#)
        let changed = try document.setting(.number(42), at: [.string("n")])
        XCTAssertEqual(try changed.value(at: [.string("n")]), .number(42))
    }

    func testContainsPathTellsMissingFromNull() {
        XCTAssertTrue(document.containsPath([.string("data"), .string("items"), .number(2), .string("name")]))
        XCTAssertFalse(document.containsPath([.string("data"), .string("items"), .number(3)]))
        XCTAssertTrue(document.containsPath([.string("data"), .string("items"), .number(-1)]))
        XCTAssertFalse(document.containsPath([.string("data"), .string("missing")]))
        XCTAssertFalse(document.containsPath([.string("n"), .string("x")]))
        XCTAssertTrue(document.containsPath([]))
    }

    // MARK: Highlighting

    private func kinds(_ source: String) -> [(JQSyntaxToken.Kind, String)] {
        JQSyntaxHighlighter.analyze(source).tokens.map { ($0.kind, $0.range.text(in: source)) }
    }

    func testTokenKinds() {
        let tokens = kinds(#"def f($x): .a[0] | select(.b == true) // @csv; $x # done"#)
        let expected: [(JQSyntaxToken.Kind, String)] = [
            (.keyword, "def"), (.function, "f"), (.bracket, "("), (.variable, "$x"), (.bracket, ")"),
            (.operator, ":"), (.field, ".a"), (.bracket, "["), (.number, "0"), (.bracket, "]"),
            (.operator, "|"), (.function, "select"), (.bracket, "("), (.field, ".b"), (.operator, "=="),
            (.literal, "true"), (.bracket, ")"), (.operator, "//"), (.format, "@csv"), (.operator, ";"),
            (.variable, "$x"), (.comment, "# done"),
        ]
        XCTAssertEqual(tokens.map { $0.1 }, expected.map { $0.1 })
        XCTAssertEqual(tokens.map { $0.0 }, expected.map { $0.0 })
    }

    func testStringInterpolationIsSplitIntoParts() {
        let tokens = kinds(#""\(.name) is \(.age + 1)""#)
        XCTAssertEqual(tokens.map { $0.1 }, [#"""#, #"\("#, ".name", ")", " is ", #"\("#, ".age", "+", "1", ")", #"""#])
        XCTAssertEqual(tokens.map { $0.0 }, [.string, .interpolation, .field, .interpolation, .string,
                                              .interpolation, .field, .operator, .number, .interpolation, .string])
    }

    func testUnterminatedStringAndCurlyQuotesAreInvalid() {
        XCTAssertEqual(kinds(#".a | "open"#).last?.0, .invalid)
        XCTAssertEqual(kinds("select(.a == \u{201C}x\u{201D})").filter { $0.0 == .invalid }.map { $0.1 },
                       ["\u{201C}", "\u{201D}"])
    }

    func testBracketPairs() {
        let source = "map({a: .b[0]})"
        let analysis = JQSyntaxHighlighter.analyze(source)
        XCTAssertEqual(analysis.brackets, [
            JQBracketPair(open: 3, close: 14), JQBracketPair(open: 4, close: 13), JQBracketPair(open: 10, close: 12),
        ])
        // The cursor just after the closing brace finds its pair.
        XCTAssertEqual(analysis.bracketPair(near: 14), JQBracketPair(open: 4, close: 13))
    }

    func testUnmatchedBracketsHaveNoPartner() {
        let analysis = JQSyntaxHighlighter.analyze("[.a, (.b]")
        XCTAssertTrue(analysis.brackets.contains(JQBracketPair(open: 0, close: nil)))
        XCTAssertTrue(analysis.brackets.contains(JQBracketPair(open: nil, close: 8)))
    }

    func testInterpolationParenthesesPair() {
        let source = #""x\(.a)""#
        let analysis = JQSyntaxHighlighter.analyze(source)
        XCTAssertEqual(analysis.brackets, [JQBracketPair(open: 3, close: 6)])
    }
}
