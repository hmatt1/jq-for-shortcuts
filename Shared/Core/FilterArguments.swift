import Foundation
import JQEngine

/// Arguments pass values into a filter as `$name` variables (R2.7 to R2.10).
/// They arrive as JSON object text: Shortcuts turns a Dictionary into that
/// text, and the Playground's Arguments editor holds it directly.
enum FilterArguments {
    /// R2.8: names a jq variable can have.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || isASCIILetter(first) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { $0 == "_" || isASCIILetter($0) || ("0"..."9").contains($0) }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// The arguments in `text`, keyed by variable name. Empty text means no
    /// arguments. Each value keeps its JSON type (R2.9).
    static func parse(_ text: String?) throws -> [String: JSON] {
        guard let text, !text.allSatisfy(\.isWhitespace) else { return [:] }
        let value: JSON
        do {
            value = try JSONParser.parseSingle(text)
        } catch {
            throw FilterError.argumentsNotDictionary(found: String(localized: "text that is not JSON"))
        }
        guard case .object(let object) = value else {
            throw FilterError.argumentsNotDictionary(found: FilterError.describeType(value.typeName))
        }
        var arguments: [String: JSON] = [:]
        for (name, argument) in object.entries {
            guard isValidName(name) else {
                throw FilterError.invalidArgumentName(name)
            }
            arguments[name] = argument
        }
        return arguments
    }

    /// Arguments saved with a filter, with `overrides` on top, key by key. Run
    /// Saved Filter uses this so a filter runs as it did in the Playground,
    /// and the action can still replace any value. Saved arguments that do
    /// not parse are left out; invalid `overrides` throw as usual.
    static func merging(_ overrides: String?, onto saved: String?) throws -> String? {
        let added = try parse(overrides)
        guard let saved, let defaults = try? parse(saved), !defaults.isEmpty else {
            return overrides
        }
        var object = JSONObject()
        for (name, value) in defaults.sorted(by: { $0.key < $1.key }) {
            object[name] = value
        }
        for (name, value) in added.sorted(by: { $0.key < $1.key }) {
            object[name] = value
        }
        return JSONWriter.string(.object(object))
    }

    /// `text` with one more argument, for the Playground's "Add to Arguments"
    /// button. Keeps the existing keys in order.
    static func adding(_ name: String, value: JSON = .string(""), to text: String) -> String {
        var object = JSONObject()
        if let existing = try? JSONParser.parseSingle(text), case .object(let current) = existing {
            object = current
        }
        if !object.contains(name) {
            object[name] = value
        }
        return JSONWriter.string(.object(object), options: .pretty)
    }
}
