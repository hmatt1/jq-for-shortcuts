import Foundation
import XCTest
@testable import JQEngine

/// Runs every case in Fixtures/jq-1.7.1.json and compares the engine's output
/// with real jq 1.7.1's, byte for byte, including error text. The fixtures
/// come from jq's own test suite plus this project's edge-case and
/// real-world corpora; Scripts/generate-fixtures.py regenerates them.
final class ConformanceTests: XCTestCase {
    private struct FixtureFile: Decodable {
        var jq: String
        var cases: [Fixture]
    }

    private struct Fixture: Decodable {
        struct Options: Decodable {
            var slurp: Bool?
            var sortKeys: Bool?
            var ascii: Bool?
        }

        var id: String
        var filter: String
        var input: String
        var options: Options?
        /// Each argument as JSON text, as `--argjson` takes it.
        var arguments: [String: String]?
        var outputs: [String]?
        var errors: [String]?
        var inputError: String?
        var compileError: Bool?
    }

    func testEngineMatchesJQ171() throws {
        let url = FixturePaths.fixtures.appendingPathComponent("jq-1.7.1.json")
        let file = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(file.jq, JQ.compatibleVersion)
        XCTAssertGreaterThan(file.cases.count, 1000)

        // Debug builds use much larger stack frames than release builds, so
        // deep-recursion fixtures need the same large stack the app uses.
        let failures: [String] = try JQThread.runAndWait {
            var failures: [String] = []
            for fixture in file.cases {
                if let problem = self.check(fixture) {
                    failures.append("\(fixture.id)  \(fixture.filter)\n    \(problem)")
                }
            }
            return failures
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count) of \(file.cases.count) fixtures differ from jq 1.7.1:\n"
                    + failures.prefix(40).joined(separator: "\n"))
        }
    }

    private func check(_ fixture: Fixture) -> String? {
        var arguments: [String: JSON] = [:]
        for (name, text) in fixture.arguments ?? [:] {
            guard let value = try? JSONParser.parseSingle(text) else { return "bad argument \(name)" }
            arguments[name] = value
        }
        let options = RunOptions(
            slurp: fixture.options?.slurp ?? false,
            sortKeys: fixture.options?.sortKeys ?? false,
            ascii: fixture.options?.ascii ?? false
        )

        let actual: CommandLineRun
        do {
            actual = try TestRunner.run(filter: fixture.filter, input: fixture.input,
                                        arguments: arguments, options: options)
        } catch let error as JQCompileError {
            return fixture.compileError == true ? nil : "compile error: \(error.message)"
        } catch {
            return "stopped: \(error)"
        }
        if fixture.compileError == true {
            return "compiled, but jq rejects this filter"
        }
        let expected = CommandLineRun(
            outputs: fixture.outputs ?? [],
            errors: fixture.errors ?? [],
            inputError: fixture.inputError
        )
        guard actual != expected else { return nil }
        return "expected \(expected)\n    got      \(actual)"
    }
}
