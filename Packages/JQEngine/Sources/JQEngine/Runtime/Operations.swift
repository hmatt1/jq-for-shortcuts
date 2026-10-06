import Foundation

/// Value-level operations with jq 1.7.1's semantics and error messages
/// (src/jv_aux.c and src/builtin.c).
enum Ops {
    // MARK: Error text

    /// `jv_dump_string_trunc`: compact JSON cut to `bufferSize - 1` bytes, with
    /// "..." when truncated.
    static func truncatedDump(_ value: JSON, bufferSize: Int = 15) -> String {
        let text = JSONWriter.string(value)
        let bytes = Array(text.utf8)
        let limit = bufferSize - 1
        if bytes.count <= limit { return text }
        var cut = Array(bytes[0..<limit])
        if bufferSize >= 4 {
            cut[limit - 3] = UInt8(ascii: ".")
            cut[limit - 2] = UInt8(ascii: ".")
            cut[limit - 1] = UInt8(ascii: ".")
        }
        return String(decoding: cut, as: UTF8.self)
    }

    /// "number (1)", as jq's type errors describe a value.
    static func describe(_ value: JSON, bufferSize: Int = 15) -> String {
        "\(value.typeName) (\(truncatedDump(value, bufferSize: bufferSize)))"
    }

    static func typeError(_ value: JSON, _ message: String) -> JQRuntimeError {
        JQRuntimeError("\(describe(value)) \(message)", kind: .other)
    }

    static func typeError2(_ a: JSON, _ b: JSON, _ message: String) -> JQRuntimeError {
        JQRuntimeError("\(describe(a)) and \(describe(b)) \(message)", kind: .other)
    }

    // MARK: Indexing

    /// `jv_get`: `.[key]` on any value.
    static func index(_ target: JSON, _ key: JSON) throws -> JSON {
        switch (target, key) {
        case (.object(let o), .string(let k)):
            return o[k] ?? .null
        case (.array(let a), .number(let n)):
            if n.value.isNaN { return .null }
            var idx = clampToInt32(n.value)
            if idx < 0 { idx += a.count }
            if idx < 0 || idx >= a.count { return .null }
            return a[idx]
        case (.array(let a), .object(let slice)):
            let (start, end) = try parseSlice(count: a.count, slice)
            return .array(Array(a[start..<end]))
        case (.string(let s), .object(let slice)):
            let scalars = Array(s.unicodeScalars)
            let (start, end) = try parseSlice(count: scalars.count, slice)
            var out = String.UnicodeScalarView()
            out.append(contentsOf: scalars[start..<end])
            return .string(String(out))
        case (.array(let a), .array(let needle)):
            return arrayIndexes(a, needle)
        case (.null, .string), (.null, .number), (.null, .object):
            return .null
        default:
            if case .string(let k) = key, k.utf8.count < 30 {
                throw JQRuntimeError("Cannot index \(target.typeName) with string \"\(k)\"",
                                     kind: .index(target: target.typeName, key: "string"))
            }
            throw JQRuntimeError("Cannot index \(target.typeName) with \(key.typeName)",
                                 kind: .index(target: target.typeName, key: key.typeName))
        }
    }

    static func clampToInt32(_ d: Double) -> Int {
        if d.isNaN { return 0 }
        if d < Double(Int32.min) { return Int(Int32.min) }
        if d > Double(Int32.max) { return Int(Int32.max) }
        return Int(d)
    }

    /// `parse_slice`: start rounds down, end rounds up, both clamped.
    static func parseSlice(count len: Int, _ slice: JSONObject) throws -> (Int, Int) {
        var startValue = slice["start"] ?? .null
        var endValue = slice["end"] ?? .null
        if case .null = startValue { startValue = .number(0) }
        if case .null = endValue { endValue = .number(len) }
        guard case .number(let s) = startValue, case .number(let e) = endValue else {
            throw JQRuntimeError("Array/string slice indices must be integers")
        }
        var dstart = s.value
        var dend = e.value
        if dstart.isNaN { dstart = 0 }
        if dstart < 0 { dstart += Double(len) }
        if dstart < 0 { dstart = 0 }
        if dstart > Double(len) { dstart = Double(len) }
        let start = dstart > Double(Int32.max) ? Int(Int32.max) : Int(dstart)
        if dend.isNaN { dend = Double(len) }
        if dend < 0 { dend += Double(len) }
        if dend < 0 { dend = Double(start) }
        var end = dend > Double(Int32.max) ? Int(Int32.max) : Int(dend)
        if end > len { end = len }
        if end < len && Double(end) < dend { end += 1 }
        if end < start { end = start }
        return (start, end)
    }

    static func sliceKey(_ from: JSON, _ to: JSON) -> JSON {
        var o = JSONObject()
        o["start"] = from
        o["end"] = to
        return .object(o)
    }

    /// `jv_array_indexes`: positions where `needle` occurs as a sub-array.
    static func arrayIndexes(_ a: [JSON], _ needle: [JSON]) -> JSON {
        var result: [JSON] = []
        if needle.isEmpty { return .array([]) }
        if a.count >= needle.count {
            for i in 0...(a.count - needle.count) {
                var match = true
                for j in needle.indices where !(a[i + j] == needle[j]) {
                    match = false
                    break
                }
                if match { result.append(.number(i)) }
            }
        }
        return .array(result)
    }

    // MARK: Arithmetic

    static func add(_ a: JSON, _ b: JSON) throws -> JSON {
        switch (a, b) {
        case (.null, _): return b
        case (_, .null): return a
        case (.number(let x), .number(let y)): return .number(x.value + y.value)
        case (.string(let x), .string(let y)): return .string(x + y)
        case (.array(let x), .array(let y)): return .array(x + y)
        case (.object(var x), .object(let y)):
            for (k, v) in y.entries { x.set(k, v) }
            return .object(x)
        default:
            throw arithmeticError(.add, a, b, "cannot be added")
        }
    }

    /// `a + b` that reuses `a`'s storage when it is uniquely owned.
    static func addInPlace(_ a: inout JSON, _ b: JSON) throws {
        switch (a, b) {
        case (.null, _):
            a = b
        case (_, .null):
            return
        case (.number(let x), .number(let y)):
            a = .number(x.value + y.value)
        case (.string, .string(let y)):
            guard case .string(var x) = a else { return }
            a = .null
            x.append(y)
            a = .string(x)
        case (.array, .array(let y)):
            guard case .array(var x) = a else { return }
            a = .null
            x.append(contentsOf: y)
            a = .array(x)
        case (.object, .object(let y)):
            guard case .object(var x) = a else { return }
            a = .null
            for (k, v) in y.entries { x.set(k, v) }
            a = .object(x)
        default:
            throw arithmeticError(.add, a, b, "cannot be added")
        }
    }

    static func subtract(_ a: JSON, _ b: JSON) throws -> JSON {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return .number(x.value - y.value)
        case (.array(let x), .array(let y)):
            return .array(x.filter { item in !y.contains(where: { $0 == item }) })
        default:
            throw arithmeticError(.subtract, a, b, "cannot be subtracted")
        }
    }

    static func multiply(_ a: JSON, _ b: JSON, ctx: Context?) throws -> JSON {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return .number(x.value * y.value)
        case (.string(let s), .number(let n)), (.number(let n), .string(let s)):
            let d = n.value
            if d < 0 || d.isNaN { return .null }
            let count = d >= Double(Int32.max) ? Int(Int32.max) : Int(d)
            if count == 0 { return .string("") }
            try ctx?.checkSize(s.utf8.count &* count)
            return .string(String(repeating: s, count: count))
        case (.object(let x), .object(let y)):
            return .object(deepMerge(x, y))
        default:
            throw arithmeticError(.multiply, a, b, "cannot be multiplied")
        }
    }

    static func deepMerge(_ a: JSONObject, _ b: JSONObject) -> JSONObject {
        var result = a
        for (k, v) in b.entries {
            if case .object(let bv) = v, case .object(let av)? = result[k] {
                result.set(k, .object(deepMerge(av, bv)))
            } else {
                result.set(k, v)
            }
        }
        return result
    }

    static func divide(_ a: JSON, _ b: JSON) throws -> JSON {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            if y.value == 0 {
                throw JQRuntimeError("\(describe(a)) and \(describe(b)) cannot be divided because the divisor is zero",
                                     kind: .divideByZero)
            }
            return .number(x.value / y.value)
        case (.string(let x), .string(let y)):
            return splitString(x, by: y)
        default:
            throw arithmeticError(.divide, a, b, "cannot be divided")
        }
    }

    static func modulo(_ a: JSON, _ b: JSON) throws -> JSON {
        guard case .number(let x) = a, case .number(let y) = b else {
            throw arithmeticError(.modulo, a, b, "cannot be divided (remainder)")
        }
        if x.value.isNaN || y.value.isNaN { return .number(.nan) }
        let bi = toIntMax(y.value)
        if bi == 0 {
            throw JQRuntimeError("\(describe(a)) and \(describe(b)) cannot be divided (remainder) because the divisor is zero",
                                 kind: .divideByZero)
        }
        if bi == -1 { return .number(0) }
        return .number(Double(toIntMax(x.value) % bi))
    }

    /// jq's `dtoi`: saturating double to intmax_t.
    static func toIntMax(_ d: Double) -> Int64 {
        if d < -9.223372036854775808e18 { return Int64.min }
        if -d < -9.223372036854775808e18 { return Int64.max }
        return Int64(d)
    }

    private static func arithmeticError(_ op: BinaryOperator, _ a: JSON, _ b: JSON, _ text: String) -> JQRuntimeError {
        JQRuntimeError("\(describe(a)) and \(describe(b)) \(text)",
                       kind: .arithmetic(operation: op, lhs: a.typeName, rhs: b.typeName))
    }

    static func negate(_ v: JSON) throws -> JSON {
        guard case .number(let n) = v else {
            throw JQRuntimeError("\(describe(v)) cannot be negated", kind: .negate(type: v.typeName))
        }
        return .number(-n.value)
    }

    static func binary(_ op: BinaryOperator, _ a: JSON, _ b: JSON, ctx: Context?) throws -> JSON {
        switch op {
        case .add: return try add(a, b)
        case .subtract: return try subtract(a, b)
        case .multiply: return try multiply(a, b, ctx: ctx)
        case .divide: return try divide(a, b)
        case .modulo: return try modulo(a, b)
        case .equal: return .bool(a == b)
        case .notEqual: return .bool(!(a == b))
        case .less: return .bool(JSON.compare(a, b) < 0)
        case .lessOrEqual: return .bool(JSON.compare(a, b) <= 0)
        case .greater: return .bool(JSON.compare(a, b) > 0)
        case .greaterOrEqual: return .bool(JSON.compare(a, b) >= 0)
        }
    }

    // MARK: Strings

    /// `jv_string_split`, byte-wise; an empty separator splits into characters.
    static func splitString(_ s: String, by sep: String) -> JSON {
        if s.isEmpty { return .array([]) }
        if sep.isEmpty {
            return .array(s.unicodeScalars.map { .string(String($0)) })
        }
        let hay = Array(s.utf8)
        let needle = Array(sep.utf8)
        var parts: [JSON] = []
        var start = 0
        var i = 0
        while i + needle.count <= hay.count {
            if hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle {
                parts.append(.string(String(decoding: hay[start..<i], as: UTF8.self)))
                i += needle.count
                start = i
            } else {
                i += 1
            }
        }
        parts.append(.string(String(decoding: hay[start..<hay.count], as: UTF8.self)))
        return .array(parts)
    }

    /// `_strindices`: byte offsets of every occurrence, overlapping allowed.
    static func stringIndexes(_ s: String, _ needle: String) -> JSON {
        let hay = Array(s.utf8)
        let n = Array(needle.utf8)
        var result: [JSON] = []
        if n.isEmpty { return .array([]) }
        if hay.count >= n.count {
            for i in 0...(hay.count - n.count) where hay[i] == n[0] {
                if Array(hay[i..<(i + n.count)]) == n {
                    result.append(.number(i))
                }
            }
        }
        return .array(result)
    }

    // MARK: Containment

    /// `jv_contains`.
    static func contains(_ a: JSON, _ b: JSON) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)):
            for (k, v) in y.entries {
                guard let av = x[k], contains(av, v) else { return false }
            }
            return true
        case (.array(let x), .array(let y)):
            for bv in y where !x.contains(where: { contains($0, bv) }) {
                return false
            }
            return true
        case (.string(let x), .string(let y)):
            if y.isEmpty { return true }
            let hay = Array(x.utf8)
            let n = Array(y.utf8)
            if n.count > hay.count { return false }
            for i in 0...(hay.count - n.count) where hay[i] == n[0] {
                if Array(hay[i..<(i + n.count)]) == n { return true }
            }
            return false
        default:
            return a.kind == b.kind && a == b
        }
    }

    // MARK: Keys

    static func keys(_ v: JSON, sorted: Bool) throws -> JSON {
        switch v {
        case .object(let o):
            return .array((sorted ? o.sortedKeys : o.keys).map { .string($0) })
        case .array(let a):
            return .array((0..<a.count).map { .number($0) })
        default:
            throw typeError(v, "has no keys")
        }
    }

    static func has(_ t: JSON, _ k: JSON) throws -> Bool {
        switch (t, k) {
        case (.null, _):
            return false
        case (.object(let o), .string(let key)):
            return o.contains(key)
        case (.array(let a), .number(let n)):
            if n.value.isNaN { return false }
            let i = Int(n.value)
            return i >= 0 && i < a.count
        default:
            throw JQRuntimeError("Cannot check whether \(t.typeName) has a \(k.typeName) key")
        }
    }

    static func length(_ v: JSON) throws -> JSON {
        switch v {
        case .array(let a): return .number(a.count)
        case .object(let o): return .number(o.count)
        case .string(let s): return .number(s.unicodeScalars.count)
        case .number(let n): return .number(abs(n.value))
        case .null: return .number(0)
        case .bool:
            throw JQRuntimeError("\(describe(v)) has no length", kind: .length(type: v.typeName))
        }
    }

    // MARK: Sorting

    /// Stable sort by precomputed keys, as `jv_sort` does.
    static func sortedBy(_ values: [JSON], keys: [JSON]) -> [JSON] {
        let order = keys.indices.sorted { i, j in
            let r = JSON.compare(keys[i], keys[j])
            return r != 0 ? r < 0 : i < j
        }
        return order.map { values[$0] }
    }

    /// `jv_group`: sort by key, then group runs of equal keys.
    static func groupedBy(_ values: [JSON], keys: [JSON]) -> [JSON] {
        let order = keys.indices.sorted { i, j in
            let r = JSON.compare(keys[i], keys[j])
            return r != 0 ? r < 0 : i < j
        }
        var groups: [JSON] = []
        var current: [JSON] = []
        var currentKey: JSON?
        for i in order {
            if let ck = currentKey, JSON.compare(ck, keys[i]) == 0 {
                current.append(values[i])
            } else {
                if currentKey != nil { groups.append(.array(current)) }
                current = [values[i]]
                currentKey = keys[i]
            }
        }
        if currentKey != nil { groups.append(.array(current)) }
        return groups
    }

    /// `minmax_by`: first minimum, last maximum.
    static func minMaxBy(_ values: JSON, _ keys: JSON, isMin: Bool) throws -> JSON {
        guard case .array(let v) = values, case .array(let k) = keys else {
            throw typeError2(values, keys, "cannot be iterated over")
        }
        guard v.count == k.count else { throw typeError2(values, keys, "have wrong length") }
        if v.isEmpty { return .null }
        var best = v[0]
        var bestKey = k[0]
        for i in 1..<v.count {
            let cmp = JSON.compare(k[i], bestKey)
            if (cmp < 0) == isMin {
                best = v[i]
                bestKey = k[i]
            }
        }
        return best
    }

    // MARK: Paths

    /// `jv_getpath`.
    static func getPath(_ root: JSON, _ path: JSON) throws -> JSON {
        guard case .array(let components) = path else {
            throw JQRuntimeError("Path must be specified as an array")
        }
        var current = root
        for c in components {
            if case .null = current { return .null }
            current = try index(current, c)
        }
        return current
    }

    /// `jv_setpath`, mutating `root` in place when it is uniquely owned.
    static func setPath(_ root: inout JSON, _ path: ArraySlice<JSON>, _ value: JSON) throws {
        guard let key = path.first else {
            root = value
            return
        }
        let rest = path.dropFirst()
        if case .object = key {
            // Slice assignment.
            var sub = try index(root, key)
            try setPath(&sub, rest, value)
            try setSlice(&root, key, sub)
            return
        }
        switch (root, key) {
        case (.object, .string(let k)), (.null, .string(let k)):
            var object: JSONObject
            if case .object(let o) = root { object = o } else { object = JSONObject() }
            root = .null
            if let position = object.position(of: k) {
                var child = object.takeValue(at: position)
                try setPath(&child, rest, value)
                object.setValue(at: position, child)
            } else {
                var child = JSON.null
                try setPath(&child, rest, value)
                object.set(k, child)
            }
            root = .object(object)
        case (.array, .number(let n)), (.null, .number(let n)):
            if n.value.isNaN {
                throw JQRuntimeError("Cannot set array element at NaN index")
            }
            var array: [JSON]
            if case .array(let a) = root { array = a } else { array = [] }
            root = .null
            var idx = clampToInt32(n.value)
            if idx < 0 {
                idx += array.count
                if idx < 0 {
                    throw JQRuntimeError("Out of bounds negative array index")
                }
            }
            if idx >= array.count {
                if idx > 100_000_000 {
                    throw JQStopReason.memoryLimit(bytes: UInt64(idx))
                }
                array.append(contentsOf: repeatElement(JSON.null, count: idx - array.count + 1))
            }
            var child = array[idx]
            array[idx] = .null
            try setPath(&child, rest, value)
            array[idx] = child
            root = .array(array)
        default:
            // Fails with jq's message for the specific combination.
            _ = try index(root, key)
            throw JQRuntimeError("Cannot update field at \(key.typeName) index of \(root.typeName)")
        }
    }

    static func setPath(_ root: JSON, _ path: JSON, _ value: JSON) throws -> JSON {
        guard case .array(let components) = path else {
            throw JQRuntimeError("Path must be specified as an array")
        }
        var copy = root
        try setPath(&copy, components[...], value)
        return copy
    }

    /// `jv_set` with a slice key.
    private static func setSlice(_ root: inout JSON, _ key: JSON, _ value: JSON) throws {
        guard case .object(let slice) = key else { return }
        switch root {
        case .array, .null:
            var array: [JSON] = []
            if case .array(let a) = root { array = a }
            let (start, end) = try parseSlice(count: array.count, slice)
            guard case .array(let insert) = value else {
                throw JQRuntimeError("A slice of an array can only be assigned another array")
            }
            array.replaceSubrange(start..<end, with: insert)
            root = .array(array)
        case .string:
            throw JQRuntimeError("Cannot update string slices")
        default:
            throw JQRuntimeError("Cannot update field at object index of \(root.typeName)")
        }
    }

    /// `jv_delpaths`.
    static func deletePaths(_ root: JSON, _ paths: JSON) throws -> JSON {
        guard case .array(var list) = paths else {
            throw JQRuntimeError("Paths must be specified as an array")
        }
        list = sortedBy(list, keys: list)
        for p in list {
            guard case .array = p else {
                throw JQRuntimeError("Path must be specified as array, not \(p.typeName)")
            }
        }
        if list.isEmpty { return root }
        if case .array(let first) = list[0], first.isEmpty { return .null }
        let arrays = list.map { $0.arrayValue ?? [] }
        return try deleteSorted(root, arrays[...], start: 0)
    }

    private static func deleteSorted(_ object: JSON, _ paths: ArraySlice<[JSON]>, start: Int) throws -> JSON {
        var object = object
        var deleteKeys: [JSON] = []
        var i = paths.startIndex
        while i < paths.endIndex {
            let key = paths[i][start]
            var j = i
            while j < paths.endIndex && paths[j][start] == key { j += 1 }
            let deleteWhole = paths[i].count == start + 1
            if deleteWhole {
                deleteKeys.append(key)
            } else {
                let sub = try index(object, key)
                if case .null = sub {
                    // Nothing to delete below a missing key.
                } else {
                    let newSub = try deleteSorted(sub, paths[i..<j], start: start + 1)
                    try setPath(&object, [key][...], newSub)
                }
            }
            i = j
        }
        return try deleteKeys.isEmpty ? object : deleteKeysFrom(object, deleteKeys)
    }

    /// `jv_dels`: removes keys (all from one container level).
    private static func deleteKeysFrom(_ t: JSON, _ keys: [JSON]) throws -> JSON {
        switch t {
        case .null:
            return t
        case .array(let array):
            var negative: [Int] = []
            var nonNegative: [Int] = []
            var ranges: [(Int, Int)] = []
            for key in keys {
                switch key {
                case .number(let n):
                    if n.value < 0 { negative.append(Int(n.value)) } else { nonNegative.append(Int(n.value)) }
                case .object(let slice):
                    ranges.append(try parseSlice(count: array.count, slice))
                default:
                    throw JQRuntimeError("Cannot delete \(key.typeName) element of array")
                }
            }
            var drop = Set<Int>()
            for n in negative where array.count + n >= 0 { drop.insert(array.count + n) }
            for n in nonNegative { drop.insert(n) }
            var out: [JSON] = []
            out.reserveCapacity(array.count)
            for (i, element) in array.enumerated() {
                if drop.contains(i) { continue }
                if ranges.contains(where: { $0.0 <= i && i < $0.1 }) { continue }
                out.append(element)
            }
            return .array(out)
        case .object(var object):
            var names: [String] = []
            for key in keys {
                guard case .string(let name) = key else {
                    throw JQRuntimeError("Cannot delete \(key.typeName) field of object")
                }
                names.append(name)
            }
            object.removeAll(keys: names)
            return .object(object)
        default:
            throw JQRuntimeError("Cannot delete fields from \(t.typeName)")
        }
    }

    // MARK: Conversions

    static func toString(_ v: JSON) -> String {
        if case .string(let s) = v { return s }
        return JSONWriter.string(v)
    }

    static func toNumber(_ v: JSON) throws -> JSON {
        switch v {
        case .number:
            return v
        case .string(let s):
            let parsed: JSON
            do {
                parsed = try JSONParser.parseSingle(s)
            } catch let error as JSONParseError {
                throw JQRuntimeError(error.message)
            }
            if case .number = parsed { return parsed }
            throw typeError(v, "cannot be parsed as a number")
        default:
            throw typeError(v, "cannot be parsed as a number")
        }
    }
}
