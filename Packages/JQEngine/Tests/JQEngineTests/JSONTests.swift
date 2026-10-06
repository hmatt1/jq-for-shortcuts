import Foundation
import XCTest
@testable import JQEngine

final class JSONTests: XCTestCase {
    // MARK: Parsing

    func testSeveralValuesSeparatedByWhitespace() throws {
        let values = try JSONParser.parseAll("{\"a\": 1}\n{\"a\": 2} 3\t\"x\"")
        XCTAssertEqual(values.map { JSONWriter.string($0) }, [#"{"a":1}"#, #"{"a":2}"#, "3", #""x""#])
    }

    func testByteOrderMarkIsIgnored() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"a": "bom"}"#.utf8)
        let values = try JSONParser.parseAll(data)
        XCTAssertEqual(values.map { JSONWriter.string($0) }, [#"{"a":"bom"}"#])
    }

    func testStreamingStopsAtTheFirstSyntaxErrorAfterEarlierValues() {
        var seen: [String] = []
        XCTAssertThrowsError(try JSONParser.forEachValue(in: "1 2 [3,") { seen.append(JSONWriter.string($0)) }) { error in
            XCTAssertTrue(error is JSONParseError)
        }
        XCTAssertEqual(seen, ["1", "2"])
    }

    func testSyntaxErrorPosition() throws {
        let text = "{\n  \"a\": [1, 2}\n}"
        XCTAssertThrowsError(try JSONParser.parseAll(text)) { error in
            guard let error = error as? JSONParseError else { return XCTFail("\(error)") }
            XCTAssertEqual(error.kind, .keyValuePairs)
            XCTAssertEqual(error.line, 2)
            XCTAssertEqual(error.characterColumn, 13)
            XCTAssertEqual(error.offset, 14)
            XCTAssertEqual(error.jqDescription, "Objects must consist of key:value pairs at line 2, column 13")
        }
    }

    func testUnfinishedInputIsReportedAtTheEnd() {
        XCTAssertThrowsError(try JSONParser.parseAll(#"{"a": "#)) { error in
            let error = error as? JSONParseError
            XCTAssertEqual(error?.atEOF, true)
            XCTAssertEqual(error?.kind, .unfinished)
        }
    }

    func testNestingLimitMatchesJQ() throws {
        XCTAssertNoThrow(try JSONParser.parseAll(String(repeating: "[", count: 256) + String(repeating: "]", count: 256)))
        XCTAssertThrowsError(try JSONParser.parseAll(String(repeating: "[", count: 257) + String(repeating: "]", count: 257)))
    }

    func testNonASCIIAndEscapes() throws {
        let value = try JSONParser.parseSingle(#""Chlo\u00e9 😀 東京 \ud83d\ude00\n""#)
        XCTAssertEqual(value.stringValue, "Chloé 😀 東京 😀\n")
    }

    // MARK: Numbers (R4.5)

    func testIntegerLiteralsKeepTheirDigits() throws {
        let value = try JSONParser.parseSingle(#"{"id": 1234567890123456789, "price": 1.000, "big": 100000000000000000000}"#)
        XCTAssertEqual(JSONWriter.string(value), #"{"id":1234567890123456789,"price":1.000,"big":100000000000000000000}"#)
    }

    func testArithmeticConvertsToDouble() throws {
        XCTAssertEqual(try TestRunner.outputs(".id + 1", #"{"id": 1234567890123456789}"#), ["1234567890123456800"])
        XCTAssertEqual(try TestRunner.outputs(".id", #"{"id": 1234567890123456789}"#), ["1234567890123456789"])
    }

    func testComputedNumbersPrintLikeJQ() {
        let cases: [(Double, String)] = [
            (1e17, "1e+17"), (0.1 + 0.2, "0.30000000000000004"), (1e-5, "1e-05"),
            (1.5, "1.5"), (-0.0, "-0"), (1e300 * 1e10, "1.7976931348623157e+308"), (100, "100"),
            (123456789012, "123456789012"), (3.0, "3"),
        ]
        for (value, text) in cases {
            XCTAssertEqual(JSONWriter.string(.number(value)), text, "\(value)")
        }
        XCTAssertEqual(JSONWriter.string(.number(.nan)), "null")
    }

    func testLiteralForms() throws {
        let cases: [(String, String)] = [
            ("1E2", "1E+2"), ("0.00001", "0.00001"), ("1e-7", "1E-7"), ("1e1000", "1E+1000"), ("-0", "-0"),
            ("100000000000000000001", "100000000000000000001"),
        ]
        for (literal, printed) in cases {
            XCTAssertEqual(JSONWriter.string(try JSONParser.parseSingle(literal)), printed, literal)
        }
    }

    // MARK: Writing

    func testPrettyOutputUsesTwoSpaces() throws {
        let value = try JSONParser.parseSingle(#"{"a":[1,{"b":null}],"c":{}}"#)
        XCTAssertEqual(JSONWriter.string(value, options: .pretty), """
        {
          "a": [
            1,
            {
              "b": null
            }
          ],
          "c": {}
        }
        """)
    }

    func testSortKeysSortsEveryObject() throws {
        let value = try JSONParser.parseSingle(#"{"b": {"y": 1, "x": 2}, "a": 0}"#)
        XCTAssertEqual(JSONWriter.string(value, options: JSONWriter.Options(sortKeys: true)), #"{"a":0,"b":{"x":2,"y":1}}"#)
        XCTAssertEqual(JSONWriter.string(value), #"{"b":{"y":1,"x":2},"a":0}"#, "insertion order without sort keys (R4.6)")
    }

    func testNonASCIIIsNotEscaped() throws {
        let value = JSON.string("Chloé 😀 東京")
        XCTAssertEqual(JSONWriter.string(value), "\"Chloé 😀 東京\"")
        XCTAssertEqual(JSONWriter.string(value, options: JSONWriter.Options(asciiOnly: true)),
                       #""Chlo\u00e9 \ud83d\ude00 \u6771\u4eac""#)
    }

    func testControlCharactersAreEscapedLikeJQ() {
        XCTAssertEqual(JSONWriter.string(.string("a\u{1}\u{7f}\t\"\\")), #""a\u0001\u007f\t\"\\""#)
    }

    func testDeepValuesPrintAPlaceholderPastJQsDepth() throws {
        let value = try JQThread.runAndWait {
            try TestRunner.outputs("reduce range(300) as $i (0; [.]) | tojson | length")
        }
        XCTAssertEqual(value.count, 1)
        let text = try JQThread.runAndWait {
            try TestRunner.outputs("reduce range(300) as $i (0; [.]) | tojson")
        }
        XCTAssertTrue(text[0].contains("<skipped: too deep>"))
    }

    // MARK: Equality and order

    func testEqualityAndOrderingFollowJQ() throws {
        XCTAssertEqual(try TestRunner.outputs("[null, false, true, 0, \"\", [], {}] | sort == .", "null"), ["true"])
        XCTAssertEqual(TestRunner.json("1.0"), TestRunner.json("1"))
        XCTAssertEqual(TestRunner.json(#"{"a":1,"b":2}"#), TestRunner.json(#"{"b":2,"a":1}"#))
    }
}
