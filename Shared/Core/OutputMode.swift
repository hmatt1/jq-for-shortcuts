import Foundation
import JQEngine

/// How a run's results reach Shortcuts (R5).
enum OutputMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// One value per result. A single list result becomes its items.
    case itemPerResult
    /// One list that holds every result, in order.
    case jsonArray
    /// Text, one line per result: strings without quotes, other values as compact JSON.
    case rawLines
    /// Text, one line per result, each as compact JSON.
    case compactJSON
    /// Text, each result with a 2-space indent, separated by a line break.
    case prettyJSON

    var id: String { rawValue }

    var title: String {
        switch self {
        case .itemPerResult: return String(localized: "One item per result")
        case .jsonArray: return String(localized: "One JSON array")
        case .rawLines: return String(localized: "Raw text lines")
        case .compactJSON: return String(localized: "Compact JSON")
        case .prettyJSON: return String(localized: "Pretty JSON")
        }
    }

    /// Modes that hand Shortcuts a single Text value.
    var isTextMode: Bool {
        switch self {
        case .itemPerResult, .jsonArray: return false
        case .rawLines, .compactJSON, .prettyJSON: return true
        }
    }
}

/// The Shortcuts type a JSON value becomes (R5, type mapping).
enum ShortcutsValueType: String, Sendable, Equatable {
    case text
    case number
    case boolean
    case dictionary
    case list
    /// JSON null, delivered as the text `null` (Open questions, 7).
    case null

    init(_ value: JSON) {
        switch value {
        case .string: self = .text
        case .number: self = .number
        case .bool: self = .boolean
        case .object: self = .dictionary
        case .array: self = .list
        case .null: self = .null
        }
    }

    var title: String {
        switch self {
        case .text: return String(localized: "Text")
        case .number: return String(localized: "Number")
        case .boolean: return String(localized: "Boolean")
        case .dictionary: return String(localized: "Dictionary")
        case .list: return String(localized: "List")
        case .null: return String(localized: "null")
        }
    }
}

/// One value handed to Shortcuts.
struct ShortcutsItem: Sendable, Equatable {
    var type: ShortcutsValueType
    var text: String
}

/// Turns results into the values an action returns.
///
/// An App Intent returns one static type, so every value goes to Shortcuts
/// as Text: a string as itself, a number, boolean or null as its JSON text,
/// and an object or array as JSON text, which Shortcuts reads as a Dictionary
/// or List wherever an action such as Get Dictionary Value asks for one.
enum ShortcutsOutput {
    static func items(for results: [JSON], mode: OutputMode, sortKeys: Bool) -> [ShortcutsItem] {
        let compact = JSONWriter.Options(indent: nil, sortKeys: sortKeys)
        switch mode {
        case .itemPerResult:
            if results.count == 1, case .array(let elements) = results[0] {
                return elements.map { item(for: $0, options: compact) }
            }
            return results.map { item(for: $0, options: compact) }
        case .jsonArray:
            return results.map { item(for: $0, options: compact) }
        case .rawLines:
            let lines = results.map { value -> String in
                if case .string(let text) = value { return text }
                return JSONWriter.string(value, options: compact)
            }
            return [ShortcutsItem(type: .text, text: lines.joined(separator: "\n"))]
        case .compactJSON:
            let lines = results.map { JSONWriter.string($0, options: compact) }
            return [ShortcutsItem(type: .text, text: lines.joined(separator: "\n"))]
        case .prettyJSON:
            let pretty = JSONWriter.Options(indent: 2, sortKeys: sortKeys)
            let blocks = results.map { JSONWriter.string($0, options: pretty) }
            return [ShortcutsItem(type: .text, text: blocks.joined(separator: "\n"))]
        }
    }

    /// The Text values an action returns.
    static func values(for results: [JSON], mode: OutputMode, sortKeys: Bool) -> [String] {
        items(for: results, mode: mode, sortKeys: sortKeys).map(\.text)
    }

    /// A value as Shortcuts receives it in the list modes.
    static func item(for value: JSON, options: JSONWriter.Options = .compact) -> ShortcutsItem {
        if case .string(let text) = value {
            return ShortcutsItem(type: .text, text: text)
        }
        return ShortcutsItem(type: ShortcutsValueType(value), text: JSONWriter.string(value, options: options))
    }
}
