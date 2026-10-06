import Foundation
import JQEngine

/// Turns the values Shortcuts hands an action into the JSON text a run reads
/// (R2.1 to R2.4).
enum InputAssembler {
    /// One value is used as it is, and may hold several JSON values (R2.3).
    /// Several values, from a Shortcuts list, become one JSON array (R2.2): a
    /// value that holds exactly one JSON value goes in as that value, and any
    /// other text goes in as a string.
    static func assemble(_ parts: [Data]) throws -> Data {
        guard !parts.isEmpty else { throw FilterError.emptyInput }
        if parts.count == 1 { return parts[0] }
        var output = Data("[".utf8)
        for (index, part) in parts.enumerated() {
            if index > 0 { output.append(UInt8(ascii: ",")) }
            output.append(element(for: part))
        }
        output.append(UInt8(ascii: "]"))
        return output
    }

    private static func element(for part: Data) -> Data {
        var data = part
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        if let values = try? JSONParser.parseAll(data), values.count == 1 {
            return data
        }
        let text = String(decoding: data, as: UTF8.self)
        return Data(JSONWriter.string(.string(text)).utf8)
    }

    /// A Shortcuts value as one JSON value, for Set Value at Path: JSON as it
    /// is, and any other text as a string.
    static func jsonValue(from parts: [Data]) throws -> JSON {
        let data = try assemble(parts)
        if let values = try? JSONParser.parseAll(data), values.count == 1 {
            return values[0]
        }
        var text = data
        if text.starts(with: [0xEF, 0xBB, 0xBF]) { text.removeFirst(3) }
        return .string(String(decoding: text, as: UTF8.self))
    }

    /// Converts a property list (binary or XML), which some apps use to hand
    /// over dictionaries, to JSON. Other data comes back unchanged.
    static func normalizePropertyList(_ data: Data) -> Data {
        let isBinary = data.starts(with: Array("bplist00".utf8))
        let isXML = data.prefix(256).range(of: Data("<plist".utf8)) != nil
        guard isBinary || isXML,
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              JSONSerialization.isValidJSONObject(object),
              let json = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        else {
            return data
        }
        return json
    }
}
