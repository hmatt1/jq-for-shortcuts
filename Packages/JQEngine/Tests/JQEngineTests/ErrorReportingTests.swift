import Foundation
import XCTest
@testable import JQEngine

/// Errors carry what the app needs for design R8: the kind of problem, where
/// it is in the filter, and for run-time errors the expression whose value
/// caused it.
final class ErrorReportingTests: XCTestCase {
    // MARK: Compile errors

    func testEmptyFilter() {
        let error = TestRunner.compileError("   \n ")
        XCTAssertEqual(error?.kind, .emptyFilter)
    }

    func testOperatorWithoutValueReportsItsPosition() throws {
        let filter = ".foo | | .bar"
        let error = try XCTUnwrap(TestRunner.compileError(filter))
        XCTAssertEqual(error.kind, .missingValueBefore("|"))
        XCTAssertEqual(error.range.start, 7)
        XCTAssertEqual(error.range.text(in: filter), "|")
    }

    func testUnclosedBracketPointsAtTheOpeningBracket() throws {
        let filter = "[.a, .b"
        let error = try XCTUnwrap(TestRunner.compileError(filter))
        guard case .unclosed(let what, let opening) = error.kind else {
            return XCTFail("expected an unclosed-bracket error, got \(error.kind)")
        }
        XCTAssertEqual(what, "[")
        XCTAssertEqual(opening.start, 0)
    }

    func testUnterminatedString() throws {
        let error = try XCTUnwrap(TestRunner.compileError(#".name | "hello"#))
        XCTAssertEqual(error.kind, .unterminatedString)
        XCTAssertEqual(error.range.start, 8)
    }

    func testCurlyQuotesAreNamed() throws {
        let filter = ".[] | select(.name == \u{201C}Ada\u{201D})"
        let error = try XCTUnwrap(TestRunner.compileError(filter))
        guard case .curlyQuote = error.kind else {
            return XCTFail("expected a curly quote error, got \(error.kind)")
        }
    }

    func testUnknownFunctionSuggestsTheClosestName() throws {
        let error = try XCTUnwrap(TestRunner.compileError(".[] | slect(.a)"))
        guard case .undefinedFunction(let name, let arity, let suggestion) = error.kind else {
            return XCTFail("expected an undefined function error, got \(error.kind)")
        }
        XCTAssertEqual(name, "slect")
        XCTAssertEqual(arity, 1)
        XCTAssertEqual(suggestion, "select")
    }

    func testWrongArityNamesTheRightOne() throws {
        let error = try XCTUnwrap(TestRunner.compileError("map"))
        guard case .undefinedFunction(_, _, let suggestion) = error.kind else {
            return XCTFail("expected an undefined function error, got \(error.kind)")
        }
        XCTAssertEqual(suggestion, "map/1")
    }

    func testUndefinedVariable() throws {
        let filter = ".items[:$limit]"
        let error = try XCTUnwrap(TestRunner.compileError(filter))
        XCTAssertEqual(error.kind, .undefinedVariable("limit"))
        XCTAssertEqual(error.range.text(in: filter), "$limit")
    }

    func testArgumentNamesDefineVariables() throws {
        let filter = try JQFilter(".items[:$limit] | length", argumentNames: ["limit"])
        var out: [JSON] = []
        try filter.run(TestRunner.json(#"{"items":[1,2,3,4]}"#), arguments: ["limit": .number(2)]) { out.append($0) }
        XCTAssertEqual(out.map { JSONWriter.string($0) }, ["2"])
    }

    func testDefinitionsWithoutAProgram() throws {
        let error = try XCTUnwrap(TestRunner.compileError("def f: 1;"))
        XCTAssertEqual(error.kind, .topLevelProgramNotGiven)
    }

    // MARK: Disabled features (R4.7, R9.7)

    func testEveryDisabledFeatureFailsToCompileWithItsName() throws {
        let cases: [(String, String)] = [
            ("env.HOME", "env"),
            ("$ENV.HOME", "$ENV"),
            ("[., input]", "input"),
            ("[inputs]", "inputs"),
            ("input_filename", "input_filename"),
            (#"include "lib"; ."#, "include"),
            (#"import "lib" as lib; ."#, "import"),
            (#"import "data" as $d; ."#, "import"),
            (#""lib" | modulemeta"#, "modulemeta"),
            ("get_search_list", "get_search_list"),
            ("get_prog_origin", "get_prog_origin"),
            ("get_jq_origin", "get_jq_origin"),
        ]
        for (filter, feature) in cases {
            let error = try XCTUnwrap(TestRunner.compileError(filter), filter)
            XCTAssertEqual(error.kind, .disabledFeature(feature), filter)
        }
    }

    func testDisabledFeaturesCannotBeReachedThroughOtherSpellings() {
        // A user definition can shadow the name, but nothing reaches the
        // removed builtin itself.
        XCTAssertEqual(try TestRunner.outputs("def env: {}; env"), ["{}"])
        XCTAssertNotNil(TestRunner.compileError("def f: env; f"))
        XCTAssertNotNil(TestRunner.compileError("[builtins[] | select(startswith(\"env\"))] | env"))
        XCTAssertEqual(try TestRunner.outputs(#"[builtins[] | select(. == "env/0" or . == "input/0")]"#), ["[]"])
    }

    // MARK: Run-time errors

    func testIterationErrorNamesTheExpressionThatWasNull() throws {
        let filter = ".items[] | .name"
        let error = try XCTUnwrap(TestRunner.runtimeError(filter, #"{"items": null}"#))
        XCTAssertEqual(error.message, "Cannot iterate over null (null)")
        XCTAssertEqual(error.kind, .iterate(type: "null"))
        XCTAssertEqual(error.range?.text(in: filter), ".items[]")
        XCTAssertEqual(error.subjectRange?.text(in: filter), ".items")
    }

    func testIndexErrorNamesTheKey() throws {
        let filter = ".[] | .name"
        let error = try XCTUnwrap(TestRunner.runtimeError(filter, #"[{"name": "a"}, 5]"#))
        XCTAssertEqual(error.message, #"Cannot index number with string "name""#)
        XCTAssertEqual(error.kind, .index(target: "number", key: "string"))
        XCTAssertEqual(error.range?.text(in: filter), ".name")
    }

    func testArithmeticErrorNamesTheOperatorAndTypes() throws {
        let filter = #".name + 1"#
        let error = try XCTUnwrap(TestRunner.runtimeError(filter, #"{"name": "Ada"}"#))
        XCTAssertEqual(error.message, #"string ("Ada") and number (1) cannot be added"#)
        XCTAssertEqual(error.kind, .arithmetic(operation: .add, lhs: "string", rhs: "number"))
        XCTAssertEqual(error.range?.text(in: filter), ".name + 1")
    }

    func testCustomErrorKeepsItsValue() throws {
        let error = try XCTUnwrap(TestRunner.runtimeError(#"error({code: 7})"#))
        XCTAssertEqual(error.kind, .custom)
        XCTAssertEqual(JSONWriter.string(error.value), #"{"code":7}"#)
        XCTAssertEqual(error.jqDescription, #"{"code":7} (not a string)"#)
    }

    func testResultsBeforeAnErrorAreDelivered() throws {
        let filter = try JQFilter(".[] | .name")
        var out: [String] = []
        XCTAssertThrowsError(try filter.run(TestRunner.json(#"[{"name": "a"}, 5]"#)) { out.append(JSONWriter.string($0)) })
        XCTAssertEqual(out, [#""a""#])
    }

    func testTryCatchHandlesErrors() throws {
        XCTAssertEqual(try TestRunner.outputs(#".[] | try error("bad \(.)") catch ."#, "[1, 2]"),
                       [#""bad 1""#, #""bad 2""#])
        XCTAssertEqual(try TestRunner.outputs("[.items[]?]", "{}"), ["[]"])
    }

    // MARK: Halt (R4.10)

    func testHaltKeepsEarlierResults() throws {
        let filter = try JQFilter(".[] | if . == 3 then halt else . end")
        var out: [String] = []
        XCTAssertThrowsError(try filter.run(TestRunner.json("[1, 2, 3, 4]")) { out.append(JSONWriter.string($0)) }) { error in
            let halt = error as? JQHalt
            XCTAssertEqual(halt?.exitCode, 0)
            XCTAssertNil(halt?.message)
        }
        XCTAssertEqual(out, ["1", "2"])
    }

    func testHaltErrorCarriesItsMessage() throws {
        let filter = try JQFilter(#""stop here" | halt_error"#)
        XCTAssertThrowsError(try filter.run(.null) { _ in }) { error in
            let halt = error as? JQHalt
            XCTAssertEqual(halt?.exitCode, 5)
            XCTAssertEqual(halt?.message, .string("stop here"))
        }
    }

    // MARK: Debug and stderr (R4.9)

    func testDebugAndStderrMessagesGoToTheMessageHandler() throws {
        let filter = try JQFilter(#".langs | debug | length | stderr"#)
        var messages: [JQMessage] = []
        var out: [String] = []
        try filter.run(TestRunner.json(#"{"langs": ["en", "fr"]}"#), onMessage: { messages.append($0) }) {
            out.append(JSONWriter.string($0))
        }
        XCTAssertEqual(out, ["2"])
        XCTAssertEqual(messages, [.debug(#"["DEBUG:",["en","fr"]]"#), .stderr("2")])
    }

    // MARK: Source ranges

    func testCharacterOffsetsCountCharactersNotBytes() {
        let filter = #""café" | .x"#
        let byteOffset = Array(filter.utf8).firstIndex(of: UInt8(ascii: "|"))!
        XCTAssertEqual(SourceRange.characterOffset(in: filter, utf8Offset: byteOffset), 7)
        XCTAssertEqual(SourceRange(byteOffset, byteOffset + 1).utf16Range(in: filter), 7..<8)
    }
}
