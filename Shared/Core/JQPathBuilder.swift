import Foundation
import JQEngine

/// Builds jq path expressions such as `.data.items[3].name` for the tree
/// browser (R6.4) and the wrappers it offers for array items (R6.5).
enum JQPathBuilder {
    enum Component: Hashable, Sendable {
        case key(String)
        case index(Int)
    }

    /// jq keywords. jq 1.7 accepts `.end` and friends, but quoting them keeps
    /// the path readable and valid in every jq version.
    private static let keywords: Set<String> = [
        "def", "as", "if", "then", "elif", "else", "end", "reduce", "foreach", "try", "catch",
        "label", "import", "include", "module", "and", "or", "not", "__loc__",
    ]

    /// The expression that selects the value at `components`.
    static func expression(_ components: [Component]) -> String {
        guard !components.isEmpty else { return "." }
        var result = ""
        for component in components {
            switch component {
            case .key(let key):
                result += isPlainIdentifier(key) ? "." + key : "." + stringLiteral(key)
            case .index(let index):
                if result.isEmpty { result = "." }
                result += "[\(index)]"
            }
        }
        return result
    }

    /// True when `key` can follow a dot without quotes.
    static func isPlainIdentifier(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, !keywords.contains(key) else { return false }
        guard first == "_" || ("a"..."z").contains(first) || ("A"..."Z").contains(first) else { return false }
        return key.unicodeScalars.allSatisfy {
            $0 == "_" || ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }

    /// `text` as a jq string literal. JSON escaping is valid jq, and a
    /// backslash is always doubled, so the text cannot start an interpolation.
    static func stringLiteral(_ text: String) -> String {
        JSONWriter.string(.string(text))
    }

    /// A jq literal for a scalar value, for `select(... == value)`.
    static func literal(_ value: JSON) -> String? {
        switch value {
        case .string, .number, .bool, .null: return JSONWriter.string(value)
        case .array, .object: return nil
        }
    }

    // MARK: Suggestions for a tapped node

    struct Suggestion: Hashable, Sendable, Identifiable {
        enum Kind: Hashable, Sendable {
            /// The exact path.
            case path
            /// The same field of every item: `.items[].name`.
            case everyItem
            /// The field of every item, collected into a list: `.items | map(.name)`.
            case map
            /// The items whose field has this value: `.items[] | select(.name == "b")`.
            case select
        }

        var kind: Kind
        var expression: String
        var id: String { expression }

        var title: String {
            switch kind {
            case .path: return String(localized: "This value")
            case .everyItem: return String(localized: "Every item (.[])")
            case .map: return String(localized: "Every item as a list (map)")
            case .select: return String(localized: "Items that match (select)")
            }
        }
    }

    /// What tapping the node at `components` can insert. Inside an array the
    /// list also offers the wrappers `.[]`, `map` and `select` (R6.5), built
    /// around the innermost array on the path.
    static func suggestions(for components: [Component], value: JSON) -> [Suggestion] {
        var suggestions = [Suggestion(kind: .path, expression: expression(components))]
        guard let arrayPosition = components.lastIndex(where: {
            if case .index = $0 { return true }
            return false
        }) else {
            return suggestions
        }
        let base = Array(components[..<arrayPosition])
        let rest = Array(components[(arrayPosition + 1)...])
        let baseExpression = expression(base)
        let restExpression = rest.isEmpty ? "." : expression(rest)
        let iterate = baseExpression == "." ? ".[]" : baseExpression + "[]"

        suggestions.append(Suggestion(kind: .everyItem, expression: rest.isEmpty ? iterate : iterate + restExpression))
        if !rest.isEmpty {
            let mapExpression = baseExpression == "." ? "map(\(restExpression))" : "\(baseExpression) | map(\(restExpression))"
            suggestions.append(Suggestion(kind: .map, expression: mapExpression))
        }
        if let condition = selectCondition(rest: rest, restExpression: restExpression, value: value) {
            suggestions.append(Suggestion(kind: .select, expression: "\(iterate) | select(\(condition))"))
        }
        return suggestions
    }

    /// `.name == "b"` for a scalar field of an item, or the first scalar
    /// field of an object item.
    private static func selectCondition(rest: [Component], restExpression: String, value: JSON) -> String? {
        if !rest.isEmpty {
            guard let literal = literal(value) else { return nil }
            return "\(restExpression) == \(literal)"
        }
        switch value {
        case .object(let object):
            for (key, field) in object.entries {
                if let literal = literal(field) {
                    return "\(expression([.key(key)])) == \(literal)"
                }
            }
            return nil
        default:
            return literal(value).map { ". == \($0)" }
        }
    }
}
