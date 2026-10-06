import Foundation

/// A starter filter that ships with the app (R6.13).
struct Preset: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var summary: String
    var filter: String
    var outputMode: OutputMode
    var input: String
    var expected: [String]
}

/// What the Playground shows on first launch (R1.1).
struct PlaygroundSample: Decodable, Hashable, Sendable {
    var filter: String
    var input: String
    var outputMode: OutputMode
    var expected: [String]
}

/// One example on the Reference tab's cheat sheet (R6.14).
struct CheatSheetEntry: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var filter: String
    var explanation: String
    var input: String
    /// A JSON object for examples that use `$name` variables.
    var arguments: String?
    var expected: [String]
    var debug: [String]?
}

struct CheatSheetSection: Decodable, Identifiable, Hashable, Sendable {
    var title: String
    var entries: [CheatSheetEntry]
    var id: String { title }
}

/// One known difference between the engine and jq 1.7 (R4.12).
struct EngineDifference: Decodable, Identifiable, Hashable, Sendable {
    var title: String
    var detail: String
    var id: String { title }
}

/// One example shortcut in the gallery (R10).
struct GalleryEntry: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var summary: String
    /// The shortcut's actions, in order.
    var steps: [String]
    var filter: String
    /// Shown under the filter when the shortcut's steps do not use it.
    var filterNote: String?
    var sampleInput: String
    var outputMode: OutputMode
    /// The values a person must change, such as a URL or field names (R10.8).
    var valuesToChange: [String]
    var expected: [String]
    /// An iCloud link to the finished shortcut, once one is published.
    var shortcutURL: URL?
}

/// Loads the bundled content: Presets.json, CheatSheet.json and Gallery.json.
struct ContentLibrary: Sendable {
    var sample: PlaygroundSample
    var presets: [Preset]
    var cheatSheet: [CheatSheetSection]
    var differences: [EngineDifference]
    var gallery: [GalleryEntry]

    static let shared = ContentLibrary(bundle: .main)

    static let fallbackSample = PlaygroundSample(
        filter: ".",
        input: "{\"hello\": \"world\"}",
        outputMode: .itemPerResult,
        expected: ["{\"hello\":\"world\"}"]
    )

    private struct PresetFile: Decodable {
        var sample: PlaygroundSample
        var presets: [Preset]
    }

    private struct CheatSheetFile: Decodable {
        var sections: [CheatSheetSection]
        var differences: [EngineDifference]
    }

    private struct GalleryFile: Decodable {
        var entries: [GalleryEntry]
    }

    init(bundle: Bundle) {
        let presetFile: PresetFile? = Self.load("Presets", from: bundle)
        let cheatFile: CheatSheetFile? = Self.load("CheatSheet", from: bundle)
        let galleryFile: GalleryFile? = Self.load("Gallery", from: bundle)
        sample = presetFile?.sample ?? Self.fallbackSample
        presets = presetFile?.presets ?? []
        cheatSheet = cheatFile?.sections ?? []
        differences = cheatFile?.differences ?? []
        gallery = galleryFile?.entries ?? []
    }

    /// Loads the content files from a folder, for tests that run outside an
    /// app bundle.
    init(directory: URL) {
        func load<T: Decodable>(_ name: String) -> T? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(name).json")) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        let presetFile: PresetFile? = load("Presets")
        let cheatFile: CheatSheetFile? = load("CheatSheet")
        let galleryFile: GalleryFile? = load("Gallery")
        self.init(sample: presetFile?.sample ?? Self.fallbackSample, presets: presetFile?.presets ?? [],
                  cheatSheet: cheatFile?.sections ?? [], differences: cheatFile?.differences ?? [],
                  gallery: galleryFile?.entries ?? [])
    }

    init(sample: PlaygroundSample, presets: [Preset], cheatSheet: [CheatSheetSection],
         differences: [EngineDifference], gallery: [GalleryEntry]) {
        self.sample = sample
        self.presets = presets
        self.cheatSheet = cheatSheet
        self.differences = differences
        self.gallery = gallery
    }

    static func load<T: Decodable>(_ name: String, from bundle: Bundle) -> T? {
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Cheat sheet sections with only the entries that match `query` in their
    /// title, filter or explanation (R6.14).
    func cheatSheet(matching query: String) -> [CheatSheetSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return cheatSheet }
        return cheatSheet.compactMap { section in
            let entries = section.entries.filter { entry in
                entry.title.localizedCaseInsensitiveContains(trimmed)
                    || entry.filter.localizedCaseInsensitiveContains(trimmed)
                    || entry.explanation.localizedCaseInsensitiveContains(trimmed)
                    || section.title.localizedCaseInsensitiveContains(trimmed)
            }
            return entries.isEmpty ? nil : CheatSheetSection(title: section.title, entries: entries)
        }
    }
}
