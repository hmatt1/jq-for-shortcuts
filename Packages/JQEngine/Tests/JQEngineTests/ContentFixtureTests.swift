import Foundation
import XCTest
@testable import JQEngine

/// Every preset, cheat sheet example and gallery filter the app ships runs
/// on the engine and must give the output stored next to it (R9.13). The
/// expected outputs were produced by real jq 1.7.1 (Tools/refresh-content.py).
///
/// The content files belong to the app, at App/Resources in the repository;
/// these tests skip when the package is used on its own.
final class ContentFixtureTests: XCTestCase {
    private struct Example: Decodable {
        var id: String
        var filter: String
        var input: String
        /// A JSON object whose keys become `$name` variables.
        var arguments: String?
        var expected: [String]
        var debug: [String]?
    }

    private struct PresetFile: Decodable {
        struct Sample: Decodable {
            var filter: String
            var input: String
            var expected: [String]
        }

        var sample: Sample
        var presets: [Example]
    }

    private struct CheatSheetFile: Decodable {
        struct Section: Decodable {
            var title: String
            var entries: [Example]
        }

        var sections: [Section]
    }

    private struct GalleryFile: Decodable {
        struct Entry: Decodable {
            var id: String
            var filter: String
            var sampleInput: String
            var expected: [String]
        }

        var entries: [Entry]
    }

    private func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = FixturePaths.appResources.appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(name).json is not in this checkout (\(url.path))")
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    func testPlaygroundSampleAndPresets() throws {
        let file = try load("Presets", as: PresetFile.self)
        try verify(Example(id: "sample", filter: file.sample.filter, input: file.sample.input,
                           arguments: nil, expected: file.sample.expected, debug: nil))
        let required = ["pick-keys", "rename-keys", "sort-by", "group-and-count", "unique-by", "flatten",
                        "merge-objects", "extract-key", "array-to-csv"]
        XCTAssertEqual(file.presets.map(\.id), required, "R6.13 lists these presets")
        for preset in file.presets {
            try verify(preset)
        }
    }

    func testCheatSheetExamples() throws {
        let file = try load("CheatSheet", as: CheatSheetFile.self)
        let examples = file.sections.flatMap(\.entries)
        XCTAssertGreaterThan(examples.count, 50)
        XCTAssertEqual(Set(examples.map(\.id)).count, examples.count, "example ids are unique")
        for example in examples {
            try verify(example)
        }
    }

    func testGalleryFilters() throws {
        let file = try load("Gallery", as: GalleryFile.self)
        XCTAssertEqual(file.entries.count, 6, "R10 has six gallery shortcuts")
        for entry in file.entries {
            try verify(Example(id: entry.id, filter: entry.filter, input: entry.sampleInput,
                               arguments: nil, expected: entry.expected, debug: nil))
        }
    }

    private func verify(_ example: Example, file: StaticString = #filePath, line: UInt = #line) throws {
        var arguments: [String: JSON] = [:]
        if let text = example.arguments {
            guard case .object(let object) = try JSONParser.parseSingle(text) else {
                return XCTFail("\(example.id): arguments must be an object", file: file, line: line)
            }
            for (key, value) in object.entries { arguments[key] = value }
        }
        let filter = try JQFilter(example.filter, argumentNames: arguments.keys.sorted())
        var outputs: [String] = []
        var debug: [String] = []
        try JQThread.runAndWait {
            try JSONParser.forEachValue(in: example.input) { value in
                try filter.run(value, arguments: arguments, limits: JQLimits(timeout: 10), onMessage: { message in
                    if case .debug(let text) = message { debug.append(text) }
                }) { outputs.append(JSONWriter.string($0)) }
            }
        }
        XCTAssertEqual(outputs, example.expected, example.id, file: file, line: line)
        if let expectedDebug = example.debug {
            XCTAssertEqual(debug, expectedDebug, "\(example.id) debug messages", file: file, line: line)
        }
    }
}
