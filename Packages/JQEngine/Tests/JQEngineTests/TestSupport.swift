import Foundation
import XCTest
@testable import JQEngine

/// What `jq -c` would print for one filter and input, collected through the
/// engine's public API the way the command line drives it: one run per input
/// value (or one run over all values with slurp), an uncaught error reported
/// and the next value tried, and an input syntax error ending the run.
struct CommandLineRun: Equatable {
    var outputs: [String] = []
    var errors: [String] = []
    var inputError: String?
}

struct RunOptions: Equatable {
    var slurp = false
    var sortKeys = false
    var ascii = false
}

enum TestRunner {
    static func run(filter: String,
                    input: String,
                    arguments: [String: JSON] = [:],
                    options: RunOptions = RunOptions(),
                    limits: JQLimits = JQLimits(timeout: 20)) throws -> CommandLineRun {
        let compiled = try JQFilter(filter, argumentNames: arguments.keys.sorted())
        let writerOptions = JSONWriter.Options(indent: nil, sortKeys: options.sortKeys, asciiOnly: options.ascii)
        var result = CommandLineRun()

        func runOne(_ value: JSON) throws {
            do {
                try compiled.run(value, arguments: arguments, limits: limits) { output in
                    result.outputs.append(JSONWriter.string(output, options: writerOptions))
                }
            } catch let error as JQRuntimeError {
                result.errors.append(commandLineText(error))
            }
        }

        do {
            if options.slurp {
                var all: [JSON] = []
                try JSONParser.forEachValue(in: input) { all.append($0) }
                try runOne(.array(all))
            } else {
                try JSONParser.forEachValue(in: input) { try runOne($0) }
            }
        } catch let error as JSONParseError {
            result.inputError = error.jqDescription
        }
        return result
    }

    /// The text after "jq: error (at <stdin>:N)" in jq's stderr.
    static func commandLineText(_ error: JQRuntimeError) -> String {
        if case .string(let message) = error.value {
            return message
        }
        return "(not a string): \(JSONWriter.string(error.value))"
    }

    /// Every output of `filter` on one JSON value, as compact JSON.
    static func outputs(_ filter: String, _ input: String = "null",
                        arguments: [String: JSON] = [:], limits: JQLimits = JQLimits(timeout: 20)) throws -> [String] {
        let value = try JSONParser.parseSingle(input)
        let compiled = try JQFilter(filter, argumentNames: arguments.keys.sorted())
        var out: [String] = []
        try compiled.run(value, arguments: arguments, limits: limits) { out.append(JSONWriter.string($0)) }
        return out
    }

    /// The error a filter raises on one JSON value.
    static func runtimeError(_ filter: String, _ input: String = "null",
                             file: StaticString = #filePath, line: UInt = #line) -> JQRuntimeError? {
        do {
            _ = try outputs(filter, input)
            XCTFail("expected a run-time error from \(filter)", file: file, line: line)
            return nil
        } catch let error as JQRuntimeError {
            return error
        } catch {
            XCTFail("expected a run-time error from \(filter), got \(error)", file: file, line: line)
            return nil
        }
    }

    /// The compile error a filter raises.
    static func compileError(_ filter: String, argumentNames: [String] = [],
                             file: StaticString = #filePath, line: UInt = #line) -> JQCompileError? {
        do {
            _ = try JQFilter(filter, argumentNames: argumentNames)
            XCTFail("expected a compile error from \(filter)", file: file, line: line)
            return nil
        } catch let error as JQCompileError {
            return error
        } catch {
            XCTFail("expected a compile error from \(filter), got \(error)", file: file, line: line)
            return nil
        }
    }

    /// Parses JSON text written in a test.
    static func json(_ text: String) -> JSON {
        try! JSONParser.parseSingle(text)
    }
}

enum FixturePaths {
    /// Tests/JQEngineTests
    static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    static let fixtures = testsDirectory.appendingPathComponent("Fixtures")

    /// The app's bundled content files, which carry expected outputs for every
    /// preset, cheat sheet example and gallery filter. They live outside this
    /// package, at App/Resources in the repository.
    static let appResources = testsDirectory
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // JQEngine
        .deletingLastPathComponent()   // Packages
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("App")
        .appendingPathComponent("Resources")
}
