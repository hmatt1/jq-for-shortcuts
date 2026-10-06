import Foundation

/// A JSON value with jq 1.7 semantics.
///
/// Strings compare and hash by their UTF-8 bytes (jq never normalizes Unicode),
/// objects keep insertion order, and numbers remember the literal they were
/// parsed from so an unchanged 64-bit ID prints with its original digits.
public enum JSON: Sendable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    public static let `true` = JSON.bool(true)
    public static let `false` = JSON.bool(false)

    public static func number(_ value: Double) -> JSON {
        .number(JSONNumber(value))
    }

    public static func number(_ value: Int) -> JSON {
        .number(JSONNumber(Double(value)))
    }

    public var kind: JSONKind {
        switch self {
        case .null: return .null
        case .bool(let b): return b ? .true : .false
        case .number: return .number
        case .string: return .string
        case .array: return .array
        case .object: return .object
        }
    }

    /// The name jq's `type` builtin reports.
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// jq treats only `false` and `null` as false.
    @inline(__always)
    public var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        default: return true
        }
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n.value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var arrayValue: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// jq's type order: null < false < true < number < string < array < object.
public enum JSONKind: Int, Comparable, Sendable {
    case null = 1
    case `false` = 2
    case `true` = 3
    case number = 4
    case string = 5
    case array = 6
    case object = 7

    public static func < (lhs: JSONKind, rhs: JSONKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Numbers

/// A JSON number: an IEEE double plus, for numbers that came from a literal,
/// the canonical decimal text jq 1.7 prints for them.
public struct JSONNumber: Sendable {
    public let value: Double
    /// decNumber's to-scientific-string form of the original literal, or nil
    /// for numbers produced by arithmetic.
    public let literal: String?
    /// True when two literals must be compared as decimals because a double
    /// cannot tell them apart (more than 15 significant digits, or out of
    /// double range).
    let needsDecimalComparison: Bool

    public init(_ value: Double) {
        self.value = value
        self.literal = nil
        self.needsDecimalComparison = false
    }

    init(value: Double, literal: String?, needsDecimalComparison: Bool) {
        self.value = value
        self.literal = literal
        self.needsDecimalComparison = needsDecimalComparison
    }

    /// Parses a numeric literal the way jq 1.7 does (decNumber syntax). Returns
    /// nil when the text is not a number.
    public init?(literal text: Substring) {
        guard let parsed = DecimalLiteral(text) else { return nil }
        self = parsed.makeNumber()
    }

    public init?(literal text: String) {
        self.init(literal: Substring(text))
    }

    public var isInteger: Bool {
        value.isFinite && value == value.rounded(.towardZero)
    }

    /// The value as an Int when it is integral and in range.
    public var intValue: Int? {
        guard value.isFinite, value == value.rounded(.towardZero),
              value >= -9.2e18, value <= 9.2e18 else { return nil }
        return Int(value)
    }

    /// The exact text jq prints for this number.
    public var jqText: String {
        if value.isNaN { return "null" }
        if let literal { return literal }
        return NumberFormat.jqFormat(value)
    }
}

// MARK: - Objects

/// An insertion-ordered JSON object with byte-wise key semantics.
public struct JSONObject: Sendable {
    public private(set) var keys: [String]
    public private(set) var values: [JSON]
    private var index: [ByteKey: Int]?

    private static let indexThreshold = 8

    public init() {
        keys = []
        values = []
        index = nil
    }

    public init(minimumCapacity: Int) {
        keys = []
        values = []
        keys.reserveCapacity(minimumCapacity)
        values.reserveCapacity(minimumCapacity)
        index = nil
    }

    /// Builds an object from pairs; a repeated key keeps its first position and
    /// takes its last value, as jq's parser does.
    public init<S: Sequence>(_ pairs: S) where S.Element == (String, JSON) {
        self.init()
        for (k, v) in pairs { self[k] = v }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public subscript(key: String) -> JSON? {
        get {
            guard let i = position(of: key) else { return nil }
            return values[i]
        }
        set {
            if let newValue {
                set(key, newValue)
            } else {
                remove(key)
            }
        }
    }

    public func position(of key: String) -> Int? {
        if let index {
            return index[ByteKey(key)]
        }
        for i in keys.indices where ByteString.equal(keys[i], key) {
            return i
        }
        return nil
    }

    public func contains(_ key: String) -> Bool {
        position(of: key) != nil
    }

    public mutating func set(_ key: String, _ value: JSON) {
        if let i = position(of: key) {
            values[i] = value
            return
        }
        keys.append(key)
        values.append(value)
        if index != nil {
            index![ByteKey(key)] = keys.count - 1
        } else if keys.count > Self.indexThreshold {
            rebuildIndex()
        }
    }

    /// Replaces the value at an existing position without touching the key.
    public mutating func setValue(at position: Int, _ value: JSON) {
        values[position] = value
    }

    /// Moves the value at `position` out, leaving null, so a caller can mutate
    /// it without a copy and put it back with `setValue(at:_:)`.
    mutating func takeValue(at position: Int) -> JSON {
        let v = values[position]
        values[position] = .null
        return v
    }

    @discardableResult
    public mutating func remove(_ key: String) -> JSON? {
        guard let i = position(of: key) else { return nil }
        let old = values[i]
        keys.remove(at: i)
        values.remove(at: i)
        if keys.count > Self.indexThreshold {
            rebuildIndex()
        } else {
            index = nil
        }
        return old
    }

    /// Removes many keys at once in O(n).
    public mutating func removeAll(keys toRemove: [String]) {
        guard !toRemove.isEmpty else { return }
        var drop = Set<ByteKey>()
        for k in toRemove { drop.insert(ByteKey(k)) }
        var newKeys: [String] = []
        var newValues: [JSON] = []
        newKeys.reserveCapacity(keys.count)
        newValues.reserveCapacity(keys.count)
        for i in keys.indices where !drop.contains(ByteKey(keys[i])) {
            newKeys.append(keys[i])
            newValues.append(values[i])
        }
        keys = newKeys
        values = newValues
        if keys.count > Self.indexThreshold { rebuildIndex() } else { index = nil }
    }

    /// Keys sorted by their UTF-8 bytes, as jq's `keys` returns them.
    public var sortedKeys: [String] {
        keys.sorted { ByteString.compare($0, $1) < 0 }
    }

    /// (key, value) pairs in insertion order.
    public var entries: Zip2Sequence<[String], [JSON]> {
        zip(keys, values)
    }

    private mutating func rebuildIndex() {
        var dict = [ByteKey: Int](minimumCapacity: keys.count)
        for (i, k) in keys.enumerated() { dict[ByteKey(k)] = i }
        index = dict
    }
}

// MARK: - Byte-wise strings

/// A dictionary key that hashes and compares a String by its UTF-8 bytes.
struct ByteKey: Hashable, Sendable {
    let string: String

    init(_ string: String) {
        self.string = string
    }

    static func == (lhs: ByteKey, rhs: ByteKey) -> Bool {
        ByteString.equal(lhs.string, rhs.string)
    }

    func hash(into hasher: inout Hasher) {
        var s = string
        s.withUTF8 { buffer in
            hasher.combine(bytes: UnsafeRawBufferPointer(buffer))
        }
    }
}

/// UTF-8 byte comparisons, matching jq's memcmp-based string semantics.
enum ByteString {
    @inline(__always)
    static func equal(_ a: String, _ b: String) -> Bool {
        let ca = a.utf8.count
        if ca != b.utf8.count { return false }
        if ca == 0 { return true }
        var a = a
        var b = b
        return a.withUTF8 { pa in
            b.withUTF8 { pb in
                memcmp(pa.baseAddress!, pb.baseAddress!, ca) == 0
            }
        }
    }

    /// Negative, zero, or positive, like memcmp followed by a length compare.
    static func compare(_ a: String, _ b: String) -> Int {
        var a = a
        var b = b
        return a.withUTF8 { pa in
            b.withUTF8 { pb in
                let n = min(pa.count, pb.count)
                if n > 0 {
                    let r = memcmp(pa.baseAddress!, pb.baseAddress!, n)
                    if r != 0 { return Int(r) }
                }
                return pa.count - pb.count
            }
        }
    }

    static func hasPrefix(_ s: String, _ prefix: String) -> Bool {
        let n = prefix.utf8.count
        if n == 0 { return true }
        if s.utf8.count < n { return false }
        var s = s
        var p = prefix
        return s.withUTF8 { ps in
            p.withUTF8 { pp in memcmp(ps.baseAddress!, pp.baseAddress!, n) == 0 }
        }
    }

    static func hasSuffix(_ s: String, _ suffix: String) -> Bool {
        let n = suffix.utf8.count
        if n == 0 { return true }
        let total = s.utf8.count
        if total < n { return false }
        var s = s
        var p = suffix
        return s.withUTF8 { ps in
            p.withUTF8 { pp in memcmp(ps.baseAddress! + (total - n), pp.baseAddress!, n) == 0 }
        }
    }
}

// MARK: - Equality and ordering

extension JSON: Equatable {
    /// jq equality: numbers compare by value, objects ignore key order, strings
    /// compare by bytes.
    public static func == (lhs: JSON, rhs: JSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.number(let a), .number(let b)):
            return JSONNumber.compare(a, b, nanAsNull: false) == 0
        case (.string(let a), .string(let b)):
            return ByteString.equal(a, b)
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            for i in a.indices where !(a[i] == b[i]) { return false }
            return true
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for (k, v) in a.entries {
                guard let other = b[k], other == v else { return false }
            }
            return true
        default:
            return false
        }
    }
}

extension JSONNumber {
    /// Compares two numbers. With `nanAsNull`, NaN sorts as if it were null
    /// (jq's `jv_cmp`); without it NaN is unequal to everything (jq's
    /// `jv_equal`).
    static func compare(_ a: JSONNumber, _ b: JSONNumber, nanAsNull: Bool) -> Int {
        if a.value.isNaN || b.value.isNaN {
            if !nanAsNull {
                return 1
            }
            if a.value.isNaN && b.value.isNaN { return -1 }
            return a.value.isNaN ? -1 : 1
        }
        if let la = a.literal, let lb = b.literal,
           a.needsDecimalComparison || b.needsDecimalComparison,
           let da = DecimalLiteral(Substring(la)), let db = DecimalLiteral(Substring(lb)) {
            return DecimalLiteral.compare(da, db)
        }
        if a.value < b.value { return -1 }
        if a.value == b.value { return 0 }
        return 1
    }
}

extension JSON {
    /// jq's total order (`jv_cmp`), used by sort, min, max, unique, group_by
    /// and the comparison operators.
    public static func compare(_ lhs: JSON, _ rhs: JSON) -> Int {
        let lk = lhs.comparisonKind
        let rk = rhs.comparisonKind
        if lk != rk { return lk.rawValue - rk.rawValue }
        switch (lhs, rhs) {
        case (.number(let a), .number(let b)):
            return JSONNumber.compare(a, b, nanAsNull: true)
        case (.string(let a), .string(let b)):
            return ByteString.compare(a, b)
        case (.array(let a), .array(let b)):
            var i = 0
            while true {
                let aDone = i >= a.count
                let bDone = i >= b.count
                if aDone || bDone {
                    return (bDone ? 1 : 0) - (aDone ? 1 : 0)
                }
                let r = compare(a[i], b[i])
                if r != 0 { return r }
                i += 1
            }
        case (.object(let a), .object(let b)):
            let ka = a.sortedKeys
            let kb = b.sortedKeys
            let r = compare(.array(ka.map { .string($0) }), .array(kb.map { .string($0) }))
            if r != 0 { return r }
            for k in ka {
                let r = compare(a[k] ?? .null, b[k] ?? .null)
                if r != 0 { return r }
            }
            return 0
        default:
            return 0
        }
    }

    /// NaN takes null's place in the type order when comparing (jq 1.7).
    private var comparisonKind: JSONKind {
        if case .number(let n) = self, n.value.isNaN { return .number }
        return kind
    }
}
