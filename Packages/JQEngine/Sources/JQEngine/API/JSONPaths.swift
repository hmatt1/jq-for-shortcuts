import Foundation

extension JSON {
    /// The value at `path`, read the way jq's `getpath` reads it: a missing
    /// key or index gives null. Throws when a step cannot index the value it
    /// meets, such as a key into an array.
    public func value(at path: [JSON]) throws -> JSON {
        try Ops.getPath(self, .array(path))
    }

    /// A copy with `newValue` at `path`, written the way jq's `setpath`
    /// writes it: missing objects and arrays along the way are created, and
    /// arrays are padded with null.
    public func setting(_ newValue: JSON, at path: [JSON]) throws -> JSON {
        var copy = self
        try Ops.setPath(&copy, path[...], newValue)
        return copy
    }

    /// Whether every step of `path` exists: each key is present in its
    /// object and each index is inside its array. A key whose value is null
    /// exists; a key that is absent does not, although `value(at:)` returns
    /// null for both.
    public func containsPath(_ path: [JSON]) -> Bool {
        var current = self
        for component in path {
            switch (current, component) {
            case (.object(let object), .string(let key)):
                guard let next = object[key] else { return false }
                current = next
            case (.array(let items), .number(let number)):
                guard number.value.isFinite else { return false }
                var index = Int(number.value.rounded(.down))
                if index < 0 { index += items.count }
                guard index >= 0, index < items.count else { return false }
                current = items[index]
            case (.array, .object), (.string, .object):
                guard let next = try? Ops.index(current, component) else { return false }
                current = next
            default:
                return false
            }
        }
        return true
    }
}
