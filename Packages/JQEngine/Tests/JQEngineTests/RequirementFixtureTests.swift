import Foundation
import XCTest
@testable import JQEngine

/// The design's fixture suite (R9.13): each case in Fixtures/requirements.json
/// holds a filter, an input and the expected output or failure, and names the
/// requirement it covers. Together with ConformanceTests and
/// ContentFixtureTests it covers R4, a 64-bit integer, non-ASCII text, a
/// filter with no output, run-time errors, every disabled feature, runaway
/// filters and a large input.
final class RequirementFixtureTests: XCTestCase {
    private struct FixtureFile: Decodable {
        var cases: [Fixture]
    }

    private struct Fixture: Decodable {
        struct ExpectedError: Decodable {
            var type: String
            var message: String?
            var feature: String?
            var offset: Int?
            var kind: String?
            var name: String?
        }

        var name: String
        var filter: String
        var input: String
        var outputs: [String]?
        var error: ExpectedError?
        var arguments: [String: String]?
        var slurp: Bool?
        var sortKeys: Bool?
        var timeout: Double?
        var maxCollectionSize: Int?
    }

    func testRequirementFixtures() throws {
        let url = FixturePaths.fixtures.appendingPathComponent("requirements.json")
        let file = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(file.cases.count, 40)
        for fixture in file.cases {
            try JQThread.runAndWait { self.check(fixture) }
        }
    }

    private func check(_ fixture: Fixture) {
        var arguments: [String: JSON] = [:]
        for (name, text) in fixture.arguments ?? [:] {
            arguments[name] = TestRunner.json(text)
        }
        var limits = JQLimits(timeout: fixture.timeout ?? 10)
        if let size = fixture.maxCollectionSize { limits.maxCollectionSize = size }
        let writer = JSONWriter.Options(sortKeys: fixture.sortKeys ?? false)

        var outputs: [String] = []
        var failure: Error?
        do {
            let filter = try JQFilter(fixture.filter, argumentNames: arguments.keys.sorted())
            var values: [JSON] = []
            try JSONParser.forEachValue(in: fixture.input) { values.append($0) }
            if fixture.slurp == true { values = [.array(values)] }
            for value in values {
                try filter.run(value, arguments: arguments, limits: limits) {
                    outputs.append(JSONWriter.string($0, options: writer))
                }
            }
        } catch {
            failure = error
        }

        let name = fixture.name
        if let expected = fixture.error {
            guard let failure else {
                return XCTFail("\(name): expected a \(expected.type) error, got outputs \(outputs)")
            }
            assert(failure, matches: expected, name: name)
            if let expectedOutputs = fixture.outputs {
                XCTAssertEqual(outputs, expectedOutputs, name)
            }
        } else {
            if let failure, !(failure is JQHalt) {
                return XCTFail("\(name): unexpected error \(failure)")
            }
            XCTAssertEqual(outputs, fixture.outputs ?? [], name)
        }
    }

    private func assert(_ failure: Error, matches expected: Fixture.ExpectedError, name: String) {
        switch expected.type {
        case "compile":
            guard let error = failure as? JQCompileError else { return XCTFail("\(name): \(failure)") }
            if let offset = expected.offset { XCTAssertEqual(error.range.start, offset, name) }
            if expected.kind == "emptyFilter" { XCTAssertEqual(error.kind, .emptyFilter, name) }
            if expected.kind == "undefinedVariable" { XCTAssertEqual(error.kind, .undefinedVariable(expected.name ?? ""), name) }
        case "disabled":
            guard let error = failure as? JQCompileError else { return XCTFail("\(name): \(failure)") }
            XCTAssertEqual(error.kind, .disabledFeature(expected.feature ?? ""), name)
        case "runtime":
            guard let error = failure as? JQRuntimeError else { return XCTFail("\(name): \(failure)") }
            if let message = expected.message { XCTAssertEqual(error.message, message, name) }
        case "halt":
            guard let halt = failure as? JQHalt else { return XCTFail("\(name): \(failure)") }
            XCTAssertEqual(halt.message, expected.message.map(JSON.string), name)
        case "input":
            XCTAssertTrue(failure is JSONParseError, "\(name): \(failure)")
        case "timeout":
            guard case .timeout = failure as? JQStopReason else { return XCTFail("\(name): \(failure)") }
        case "memory":
            guard case .memoryLimit = failure as? JQStopReason else { return XCTFail("\(name): \(failure)") }
        case "recursion":
            XCTAssertEqual(failure as? JQStopReason, .recursionLimit, name)
        default:
            XCTFail("\(name): unknown expected error type \(expected.type)")
        }
    }

    /// R9.13's large input, built here instead of stored: 100,000 objects,
    /// about 6 MB of JSON, grouped and counted like the data export job.
    func testLargeInputIsFilteredWithinTheTimeout() throws {
        var text = "["
        text.reserveCapacity(7_000_000)
        for i in 0..<100_000 {
            if i > 0 { text += "," }
            text += #"{"artist":"Artist \#(i % 50)","track":"Track \#(i)","ms":\#(i % 300_000)}"#
        }
        text += "]"
        XCTAssertGreaterThan(text.utf8.count, 5_000_000)

        let started = Date()
        let outputs = try JQThread.runAndWait { () -> [String] in
            let input = try JSONParser.parseAll(text)
            let filter = try JQFilter("group_by(.artist) | map({artist: .[0].artist, plays: length}) | sort_by(-.plays) | length, (map(.plays) | add)")
            var out: [String] = []
            try filter.run(input[0], limits: JQLimits(timeout: 10)) { out.append(JSONWriter.string($0)) }
            return out
        }
        XCTAssertEqual(outputs, ["50", "100000"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}
