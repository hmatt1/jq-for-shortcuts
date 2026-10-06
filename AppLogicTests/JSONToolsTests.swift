import Foundation
import JQEngine
import XCTest
#if canImport(AppCore)
@testable import AppCore
#endif

/// Validate JSON, Format JSON, Get and Set Value at Path, and JSON to CSV.
final class JSONToolsTests: XCTestCase {
    private let settings = JSONTools.Settings(context: .background)

    private func data(_ text: String) -> Data { Data(text.utf8) }

    // MARK: Validate JSON (R5.8)

    func testValidJSONHasNoPosition() async throws {
        let result = try await JSONTools.validate(data(#"{"a": [1, 2]}"#), settings: settings)
        XCTAssertEqual(result, JSONTools.Validation(isValid: true, line: nil, column: nil, message: nil, valueCount: 1))
    }

    func testInvalidJSONReportsLineAndColumn() async throws {
        let result = try await JSONTools.validate(data("{\n  \"a\": [1, 2}\n}"), settings: settings)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.line, 2)
        XCTAssertEqual(result.column, 13)
        XCTAssertEqual(result.message, "Input is not valid JSON at line 2, column 13: objects must hold key: value pairs. Check the input.")
    }

    func testUnfinishedStringUsesTheR8Wording() async throws {
        let result = try await JSONTools.validate(data("{\"a\": \"abc"), settings: settings)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.message, "Input is not valid JSON at line 1, column 10: unexpected end of string. Check the input.")
    }

    func testToolTimeoutsSuggestASmallerInput() {
        let error = FilterErrorMapper.stop(.timeout(seconds: 10), timeout: (10, false), nextStep: .smallerInput, canRunInApp: false)
        XCTAssertEqual(error.message, "The action stopped after 10 seconds. Use a smaller input.")
    }

    func testEmptyInputIsNotValid() async throws {
        let result = try await JSONTools.validate(data("  "), settings: settings)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.message, FilterError.emptyInput.message)
    }

    // MARK: Format JSON

    func testFormatPrettyAndCompact() async throws {
        let text = #"{"b": [1, {"c": null}], "a": "x"}"#
        let pretty = try await JSONTools.format(data(text), pretty: true, sortKeys: false, settings: settings)
        XCTAssertEqual(pretty, "{\n  \"b\": [\n    1,\n    {\n      \"c\": null\n    }\n  ],\n  \"a\": \"x\"\n}")
        let compact = try await JSONTools.format(data(text), pretty: false, sortKeys: true, settings: settings)
        XCTAssertEqual(compact, #"{"a":"x","b":[1,{"c":null}]}"#)
    }

    func testFormatReportsInvalidInput() async {
        do {
            _ = try await JSONTools.format(data("[1, 2"), pretty: true, sortKeys: false, settings: settings)
            XCTFail("expected an error")
        } catch let error as FilterError {
            guard case .invalidInput = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: Get Value at Path (R3.5)

    private let document = #"{"data": {"items": [{"name": "a"}, {"name": "b", "tag": null}]}}"#

    func testGetValueAtAPath() async throws {
        let values = try await JSONTools.values(atPath: ".data.items[1].name", in: data(document), ifMissing: .stop, settings: settings)
        XCTAssertEqual(texts(values), [#""b""#])
    }

    func testGetValuesAtEveryMatchingLocation() async throws {
        let values = try await JSONTools.values(atPath: ".data.items[].name", in: data(document), ifMissing: .stop, settings: settings)
        XCTAssertEqual(texts(values), [#""a""#, #""b""#])
    }

    func testANullValueIsNotMissing() async throws {
        let values = try await JSONTools.values(atPath: ".data.items[1].tag", in: data(document), ifMissing: .stop, settings: settings)
        XCTAssertEqual(texts(values), ["null"])
    }

    func testMissingValueStopsOrReturnsNothing() async throws {
        do {
            _ = try await JSONTools.values(atPath: ".data.items[3].name", in: data(document), ifMissing: .stop, settings: settings)
            XCTFail("expected an error")
        } catch let error as FilterError {
            XCTAssertEqual(error.message, "There is no value at .data.items[3].name. Check the path, or set If Missing to Return Nothing.")
        }
        let nothing = try await JSONTools.values(atPath: ".data.items[3].name", in: data(document), ifMissing: .returnNothing,
                                                 settings: settings)
        XCTAssertTrue(nothing.isEmpty)
    }

    func testPathSyntaxAndNonPathErrors() async {
        do {
            _ = try await JSONTools.values(atPath: ".data | | .x", in: data(document), ifMissing: .stop, settings: settings)
            XCTFail("expected an error")
        } catch let error as FilterError {
            XCTAssertEqual(error.message, "Path error at position 9: unexpected \"|\". Check for a missing value before it.")
        } catch {
            XCTFail("\(error)")
        }
        do {
            _ = try await JSONTools.values(atPath: ".data.items | length", in: data(document), ifMissing: .stop, settings: settings)
            XCTFail("expected an error")
        } catch let error as FilterError {
            XCTAssertEqual(error, .notAPath(path: ".data.items | length"))
        } catch {
            XCTFail("\(error)")
        }
        do {
            _ = try await JSONTools.values(atPath: "empty", in: data(document), ifMissing: .stop, settings: settings)
            XCTFail("expected an error")
        } catch let error as FilterError {
            XCTAssertEqual(error, .pathSelectsNothing)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testPathRunTimeErrorsNameThePath() async {
        do {
            _ = try await JSONTools.values(atPath: ".data.items.name", in: data(document), ifMissing: .stop, settings: settings)
            XCTFail("expected an error")
        } catch let error as FilterError {
            guard case .pathFailed = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.message.hasPrefix("Path failed: cannot index a list with \"name\"."), error.message)
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: Set Value at Path (R3.6)

    func testSetValueCreatesMissingObjectsAndArrays() async throws {
        let updated = try await JSONTools.settingValue(.string("x"), atPath: ".a.list[2].b", in: data("{}"), settings: settings)
        XCTAssertEqual(texts(updated), [#"{"a":{"list":[null,null,{"b":"x"}]}}"#])
    }

    func testSetValueAtEveryMatchingLocation() async throws {
        let updated = try await JSONTools.settingValue(.bool(true), atPath: ".data.items[].seen", in: data(document), settings: settings)
        XCTAssertEqual(texts(updated), [#"{"data":{"items":[{"name":"a","seen":true},{"name":"b","tag":null,"seen":true}]}}"#])
    }

    func testValueFromShortcutsKeepsJSONTypes() throws {
        XCTAssertEqual(try InputAssembler.jsonValue(from: [Data("42".utf8)]), .number(42))
        XCTAssertEqual(try InputAssembler.jsonValue(from: [Data("hello".utf8)]), .string("hello"))
        XCTAssertEqual(texts([try InputAssembler.jsonValue(from: [Data(#"{"k": [1]}"#.utf8)])]), [#"{"k":[1]}"#])
    }

    // MARK: JSON to CSV (R3.7, R5.9)

    private let people = #"[{"name": "Ana", "city": "Lisbon", "age": 31}, {"name": "Ben \"B\"", "age": 27, "tags": ["x"]}]"#

    func testCSVUsesTheFirstObjectsKeysByDefault() async throws {
        let csv = try await JSONTools.table(from: data(people), columns: nil, delimiter: .comma, includeHeader: true, settings: settings)
        XCTAssertEqual(csv, "\"name\",\"city\",\"age\"\n\"Ana\",\"Lisbon\",31\n\"Ben \"\"B\"\"\",,27\n")
    }

    func testCSVWithChosenColumnsAndNestedValues() async throws {
        let csv = try await JSONTools.table(from: data(people), columns: ["tags", "name"], delimiter: .comma, includeHeader: false,
                                            settings: settings)
        XCTAssertEqual(csv, ",\"Ana\"\n\"[\"\"x\"\"]\",\"Ben \"\"B\"\"\"\n")
    }

    func testTSVEscapesTabsAndNewlines() async throws {
        let tsv = try await JSONTools.table(from: data(#"[{"a": "x\ty", "b": "line1\nline2"}]"#), columns: nil, delimiter: .tab,
                                            includeHeader: true, settings: settings)
        XCTAssertEqual(tsv, "a\tb\nx\\ty\tline1\\nline2\n")
    }

    func testCSVNeedsAListOrObject() async {
        do {
            _ = try await JSONTools.table(from: data("42"), columns: nil, delimiter: .comma, includeHeader: true, settings: settings)
            XCTFail("expected an error")
        } catch let error as FilterError {
            XCTAssertEqual(error.message, "JSON to CSV needs a list of objects, but the input is a number. Pass an array of objects.")
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: Input assembly (R2.2)

    func testSeveralShortcutsValuesBecomeOneArray() throws {
        let parts = [Data(#"{"a": 1}"#.utf8), Data("plain text".utf8), Data("[1, 2]".utf8)]
        let assembled = try InputAssembler.assemble(parts)
        XCTAssertEqual(texts(try JSONParser.parseAll(assembled)), [#"[{"a":1},"plain text",[1,2]]"#])
    }

    func testOneValueIsUsedAsItIs() throws {
        let lines = Data("{\"a\": 1}\n{\"a\": 2}".utf8)
        XCTAssertEqual(try InputAssembler.assemble([lines]), lines)
    }

    func testPropertyListsBecomeJSON() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["name": "Ada"], format: .xml, options: 0)
        let json = InputAssembler.normalizePropertyList(plist)
        XCTAssertEqual(texts(try JSONParser.parseAll(json)), [#"{"name":"Ada"}"#])
    }
}
