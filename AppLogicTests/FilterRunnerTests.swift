import Foundation
import JQEngine
import XCTest
#if canImport(AppCore)
@testable import AppCore
#endif

/// The run pipeline every entry point shares, and the R8 messages it reports.
final class FilterRunnerTests: XCTestCase {
    func testRunReturnsResultsInOrder() async {
        let outcome = await run(".items[] | .name", #"{"items": [{"name": "a"}, {"name": "b"}]}"#)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(texts(outcome.results), [#""a""#, #""b""#])
        XCTAssertEqual(outcome.inputValueCount, 1)
    }

    func testEachInputValueRunsSeparatelyUnlessSlurped() async {
        let lines = "{\"n\": 1}\n{\"n\": 2}\n{\"n\": 3}"
        let separate = await run(".n", lines)
        XCTAssertEqual(texts(separate.results), ["1", "2", "3"])
        let slurped = await run("map(.n) | add", lines, slurp: true)
        XCTAssertEqual(texts(slurped.results), ["6"])
    }

    func testNoOutputIsNotAnError() async {
        let outcome = await run(".[] | select(. > 10)", "[1, 2, 3]")
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.results.isEmpty)
    }

    // MARK: R8 messages

    func testEmptyFilterMessage() async {
        let outcome = await run("  ", "{}")
        XCTAssertEqual(outcome.error?.message, "Enter a filter. Use . to return the input unchanged.")
    }

    func testSyntaxErrorMessage() async {
        let outcome = await run(".foo | | .bar", "{}")
        XCTAssertEqual(outcome.error?.message,
                       "Filter error at position 8: unexpected \"|\". Check for a missing value before it.")
        XCTAssertEqual(outcome.error?.highlight, SourceRange(7, 8))
    }

    func testRuntimeErrorMessageNamesTheValue() async {
        let outcome = await run(".items[] | .name", #"{"items": null}"#)
        XCTAssertEqual(outcome.error?.message,
                       "Filter failed: cannot iterate over null. `.items` was null. Use `.items[]?` to skip a missing list.")
    }

    func testRuntimeErrorKeepsEarlierResultsForThePlayground() async {
        let outcome = await run(".[] | .name", #"[{"name": "a"}, 5]"#)
        XCTAssertEqual(texts(outcome.results), [#""a""#])
        XCTAssertEqual(outcome.error?.message,
                       "Filter failed: cannot index a number with \"name\". The value has no keys or items. Check the path before this step.")
    }

    func testAddingTextToANumberHasAHint() async {
        let outcome = await run(".name + 1", #"{"name": "Ada"}"#)
        XCTAssertEqual(outcome.error?.message,
                       "Filter failed: string (\"Ada\") and number (1) cannot be added. Convert one side first, for example with tostring or tonumber.")
    }

    func testIndexingAListByNameSuggestsIteration() async {
        let outcome = await run(".items.name", #"{"items": [{"name": "a"}]}"#)
        XCTAssertEqual(outcome.error?.message,
                       "Filter failed: cannot index a list with \"name\". `.items` was a list. Go through its items first, for example `.items[].name`.")
    }

    func testInvalidInputMessage() async {
        let outcome = await run(".", "{\n  \"a\": [1, 2}\n}")
        XCTAssertEqual(outcome.error?.message,
                       "Input is not valid JSON at line 2, column 13: objects must hold key: value pairs. Check the input.")
    }

    func testEmptyInputGivesNoResults() async {
        let outcome = await run(".", "   ")
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.results, [])
        let slurped = await run("length", "", slurp: true)
        XCTAssertNil(slurped.error)
        XCTAssertEqual(texts(slurped.results), ["0"])
    }

    func testDisabledFeatureMessage() async {
        let outcome = await run("$ENV.HOME", "{}")
        XCTAssertEqual(outcome.error?.message,
                       "The filter uses $ENV, which this app turns off. Remove it, or pass the value in Arguments.")
        let input = await run("[inputs]", "{}")
        XCTAssertEqual(input.error?.message,
                       "The filter uses inputs, which this app turns off. Remove it, or turn on Slurp to get every input value at once.")
    }

    func testUndefinedVariableMessage() async {
        let outcome = await run(".items[:$limit]", "{}")
        XCTAssertEqual(outcome.error?.message,
                       "The filter uses $limit, but Arguments has no value named limit. Add it to Arguments.")
    }

    func testUnknownFunctionSuggestsAName() async {
        let outcome = await run("map(slect(.a))", "[]")
        XCTAssertEqual(outcome.error?.message,
                       "Filter error at position 5: slect/1 is not a known function. Did you mean select?")
    }

    func testCurlyQuotesExplainTheFix() async {
        let outcome = await run("select(.a == \u{201C}x\u{201D})", "{}")
        XCTAssertEqual(outcome.error?.message,
                       "Filter error at position 14: \u{201C} is a curly quote. Replace it with a straight quote (\"), or turn off Smart Punctuation.")
    }

    func testUnclosedBracketPointsAtTheOpening() async {
        let outcome = await run("map({name: .a)", "[]")
        XCTAssertEqual(outcome.error?.message, "Filter error at position 5: \"{\" is never closed. Add the closing }.")
    }

    // MARK: Arguments (R2.7 to R2.10)

    func testArgumentsBecomeVariablesWithTheirTypes() async {
        let outcome = await run("[$text, $number, $flag, $list, $object]", "null",
                                arguments: #"{"text": "hi", "number": 42, "flag": true, "list": [1, 2], "object": {"k": "v"}}"#)
        XCTAssertEqual(texts(outcome.results), [#"["hi",42,true,[1,2],{"k":"v"}]"#])
    }

    func testInvalidArgumentNameMessage() async {
        let outcome = await run(".", "{}", arguments: #"{"my var": 1}"#)
        XCTAssertEqual(outcome.error?.message,
                       "Argument \"my var\" is not a valid name. Use letters, digits, and underscores, and start with a letter or underscore.")
    }

    func testArgumentsMustBeADictionary() async {
        let list = await run(".", "{}", arguments: "[1, 2]")
        XCTAssertEqual(list.error, .argumentsNotDictionary(found: "a list"))
        let text = await run(".", "{}", arguments: "limit=2")
        XCTAssertEqual(text.error, .argumentsNotDictionary(found: "text that is not JSON"))
    }

    func testEmptyArgumentsAreNoArguments() async {
        let outcome = await run(".", "1", arguments: "  ")
        XCTAssertNil(outcome.error)
    }

    func testSavedArgumentsAreDefaultsTheActionCanReplace() async throws {
        let merged = try FilterArguments.merging(#"{"limit": 2}"#, onto: #"{"limit": 5, "term": "a"}"#)
        let outcome = await run("[$limit, $term]", "null", arguments: merged)
        XCTAssertEqual(texts(outcome.results), [#"[2,"a"]"#])

        XCTAssertEqual(try FilterArguments.merging(nil, onto: #"{"limit": 5}"#).flatMap { try FilterArguments.parse($0)["limit"] },
                       try JSONParser.parseSingle("5"))
        XCTAssertEqual(try FilterArguments.merging(#"{"a": 1}"#, onto: "not json"), #"{"a": 1}"#)
        XCTAssertThrowsError(try FilterArguments.merging("[1]", onto: #"{"limit": 5}"#))
    }

    // MARK: Limits (R2.6, R4.8, R9.6, R9.10)

    func testInputOverTheBackgroundLimitPointsToRunInApp() async {
        let big = Data(count: 82 * RunLimits.megabyte)
        let outcome = await FilterRunner.run(FilterRequest(filter: ".", input: big, context: .background, canRunInApp: true))
        XCTAssertEqual(outcome.error?.message,
                       "The input is 82 MB, over the 50 MB background limit. Turn on Run in app, or use a smaller input.")
    }

    func testTimeoutStopsTheRunAndReturnsNoResults() async {
        let outcome = await run("1, [range(1e12)]", "null", timeout: 2)
        XCTAssertEqual(outcome.error?.message,
                       "Filter stopped after 2 seconds. Narrow the filter or the input, or raise Timeout.")
        XCTAssertTrue(outcome.results.isEmpty)
    }

    func testBackgroundRunsAreCappedBelowTheSystemLimit() {
        let effective = RunLimits.effectiveTimeout(requested: 60, context: .background)
        XCTAssertEqual(effective.seconds, RunLimits.backgroundTimeCap)
        XCTAssertTrue(effective.capped)
        XCTAssertEqual(RunLimits.effectiveTimeout(requested: 60, context: .foreground).seconds, 60)
        XCTAssertEqual(RunLimits.effectiveTimeout(requested: 0, context: .foreground).seconds, 1)
    }

    func testCappedTimeoutMessageSuggestsRunInApp() {
        let error = FilterErrorMapper.stop(.timeout(seconds: 25), timeout: (25, true), nextStep: .raiseTimeout, canRunInApp: true)
        XCTAssertEqual(error.message,
                       "Filter stopped after 25 seconds, the longest a run can take in the background. Turn on Run in app, or narrow the filter or the input.")
    }

    func testCancellingTheTaskStopsTheRun() async {
        let started = Date()
        let task = Task { await self.run("range(1e12) | empty", "null", timeout: 60) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome.error, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2 + 0.5)
    }

    func testPlaygroundResultLimitTruncatesQuietly() async {
        let outcome = await run("range(100)", "null", context: .playground, resultLimit: 10)
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.truncated)
        XCTAssertEqual(outcome.results.count, 10)
    }

    // MARK: halt, debug (R4.9, R4.10)

    func testHaltKeepsResultsAndHaltErrorBecomesTheMessage() async {
        let halted = await run(".[] | if . == 3 then halt else . end", "[1, 2, 3, 4]")
        XCTAssertNil(halted.error)
        XCTAssertTrue(halted.halted)
        XCTAssertEqual(texts(halted.results), ["1", "2"])

        let failed = await run(#""Not today\n" | halt_error"#, "null")
        XCTAssertEqual(failed.error?.message, "Not today")
    }

    func testDebugMessagesAreCollectedOnlyWhenAsked() async {
        let collected = await run(".a | debug", #"{"a": 1}"#, collectMessages: true)
        XCTAssertEqual(collected.messages, [.debug(#"["DEBUG:",1]"#)])
        let ignored = await run(".a | debug", #"{"a": 1}"#)
        XCTAssertTrue(ignored.messages.isEmpty)
    }
}
