import Foundation

/// A JSON syntax error with jq's message text and position.
public struct JSONParseError: Error, Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case unfinished
        case unfinishedString
        case invalidLiteral(String)
        case invalidNumber(String)
        case invalidEscape
        case invalidUnicodeEscape
        case invalidSurrogate
        case controlCharacter
        case expectedSeparator
        case expectedValue
        case unmatched(Character)
        case keysMustBeStrings
        case keyValuePairs
        case tooDeep
        case extraValues
        case empty
    }

    public let kind: Kind
    /// jq's message without the position, e.g. "Expected separator between values".
    public let message: String
    /// 1-based line, counted the way jq counts it.
    public let line: Int
    /// jq's column: bytes consumed on the line, including the byte that
    /// triggered the error.
    public let column: Int
    /// 1-based character column of the triggering character, for messages
    /// meant for people.
    public let characterColumn: Int
    public let atEOF: Bool
    /// Byte offset of the triggering byte, or the input length at EOF.
    public let offset: Int

    /// The text jq prints, e.g. "Unfinished JSON term at EOF at line 3, column 1".
    public var jqDescription: String {
        switch kind {
        case .extraValues, .empty:
            return message
        default:
            return "\(message)\(atEOF ? " at EOF" : "") at line \(line), column \(column)"
        }
    }

    public var description: String { jqDescription }
}

/// A fast UTF-8 JSON parser that follows jq 1.7.1's input rules: several
/// whitespace-separated values, `nan`, decNumber-style numbers, a nesting limit
/// of 256, and invalid UTF-8 replaced with U+FFFD.
public enum JSONParser {
    public static let maxDepth = 256

    /// Parses every value in the input.
    public static func parseAll(_ text: String, checkpoint: (() throws -> Void)? = nil) throws -> [JSON] {
        var copy = text
        return try copy.withUTF8 { buffer in
            try parseAll(buffer, checkpoint: checkpoint)
        }
    }

    public static func parseAll(_ data: Data, checkpoint: (() throws -> Void)? = nil) throws -> [JSON] {
        try data.withUnsafeBytes { raw in
            try parseAll(raw.bindMemory(to: UInt8.self), checkpoint: checkpoint)
        }
    }

    public static func parseAll(_ bytes: UnsafeBufferPointer<UInt8>, checkpoint: (() throws -> Void)? = nil) throws -> [JSON] {
        var scanner = Scanner(bytes: bytes, checkpoint: checkpoint)
        var values: [JSON] = []
        scanner.skipBOM()
        while true {
            scanner.skipWhitespace()
            if scanner.atEnd { break }
            values.append(try scanner.parseTopLevelValue())
        }
        return values
    }

    /// Parses the values one at a time and passes each to `body` as soon as
    /// it is read, the way jq reads its input: a syntax error is thrown only
    /// after every value before it has been handled.
    public static func forEachValue(in text: String, checkpoint: (() throws -> Void)? = nil,
                                    _ body: (JSON) throws -> Void) throws {
        var copy = text
        try copy.withUTF8 { buffer in
            try forEachValue(in: buffer, checkpoint: checkpoint, body)
        }
    }

    public static func forEachValue(in data: Data, checkpoint: (() throws -> Void)? = nil,
                                    _ body: (JSON) throws -> Void) throws {
        try data.withUnsafeBytes { raw in
            try forEachValue(in: raw.bindMemory(to: UInt8.self), checkpoint: checkpoint, body)
        }
    }

    public static func forEachValue(in bytes: UnsafeBufferPointer<UInt8>, checkpoint: (() throws -> Void)? = nil,
                                    _ body: (JSON) throws -> Void) throws {
        var scanner = Scanner(bytes: bytes, checkpoint: checkpoint)
        scanner.skipBOM()
        while true {
            scanner.skipWhitespace()
            if scanner.atEnd { break }
            try body(try scanner.parseTopLevelValue())
        }
    }

    /// Parses exactly one value, the way `fromjson` and `tonumber` do. The
    /// error message includes jq's "(while parsing '...')" suffix.
    public static func parseSingle(_ text: String) throws -> JSON {
        var copy = text
        return try copy.withUTF8 { buffer -> JSON in
            var scanner = Scanner(bytes: buffer, checkpoint: nil)
            do {
                scanner.skipWhitespace()
                if scanner.atEnd {
                    throw scanner.makeError(.empty, "Expected JSON value", atEOF: true)
                }
                let value = try scanner.parseTopLevelValue()
                scanner.skipWhitespace()
                if !scanner.atEnd {
                    // A second value, or an error inside it.
                    _ = try scanner.parseTopLevelValue()
                    throw scanner.makeError(.extraValues, "Unexpected extra JSON values", atEOF: false)
                }
                return value
            } catch let error as JSONParseError {
                throw JSONParseError(
                    kind: error.kind,
                    message: "\(error.jqDescription) (while parsing '\(text)')",
                    line: error.line,
                    column: error.column,
                    characterColumn: error.characterColumn,
                    atEOF: error.atEOF,
                    offset: error.offset
                )
            }
        }
    }

    // MARK: - Scanner

    struct Scanner {
        let b: UnsafeBufferPointer<UInt8>
        var i = 0
        var depth = 0
        let checkpoint: (() throws -> Void)?
        var nextCheckpoint = 1 << 16

        init(bytes: UnsafeBufferPointer<UInt8>, checkpoint: (() throws -> Void)?) {
            self.b = bytes
            self.checkpoint = checkpoint
        }

        var atEnd: Bool { i >= b.count }

        mutating func skipBOM() {
            if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF {
                i = 3
            }
        }

        @inline(__always)
        mutating func skipWhitespace() {
            while i < b.count {
                let c = b[i]
                if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 {
                    i += 1
                } else {
                    break
                }
            }
        }

        @inline(__always)
        static func isLiteralByte(_ c: UInt8) -> Bool {
            switch c {
            case 0x20, 0x0A, 0x0D, 0x09, 0x22, 0x5B, 0x5D, 0x7B, 0x7D, 0x2C, 0x3A:
                return false
            default:
                return true
            }
        }

        mutating func maybeCheckpoint() throws {
            if i >= nextCheckpoint {
                nextCheckpoint = i + (1 << 16)
                try checkpoint?()
            }
        }

        // MARK: Values

        mutating func parseTopLevelValue() throws -> JSON {
            let c = b[i]
            switch c {
            case 0x5D: throw makeError(.unmatched("]"), "Unmatched ']'", at: i)
            case 0x7D: throw makeError(.unmatched("}"), "Unmatched '}'", at: i)
            case 0x2C: throw makeError(.expectedValue, "Expected value before ','", at: i)
            case 0x3A: throw makeError(.keyValuePairs, "':' not as part of an object", at: i)
            default: return try parseValue()
            }
        }

        mutating func parseValue() throws -> JSON {
            try maybeCheckpoint()
            let c = b[i]
            switch c {
            case 0x7B: return try parseObject()
            case 0x5B: return try parseArray()
            case 0x22: return .string(try parseString())
            default: return try parseLiteral()
            }
        }

        mutating func parseArray() throws -> JSON {
            if depth >= JSONParser.maxDepth {
                throw makeError(.tooDeep, "Exceeds depth limit for parsing", at: i)
            }
            depth += 1
            defer { depth -= 1 }
            i += 1
            var items: [JSON] = []
            skipWhitespace()
            if i >= b.count { throw unfinished() }
            if b[i] == 0x5D {
                i += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                if i >= b.count { throw unfinished() }
                switch b[i] {
                case 0x2C: throw makeError(.expectedValue, "Expected value before ','", at: i)
                case 0x5D: throw makeError(.expectedValue, "Expected another array element", at: i)
                case 0x7D: throw makeError(.keyValuePairs, "Objects must consist of key:value pairs", at: i)
                case 0x3A: throw makeError(.keyValuePairs, "':' not as part of an object", at: i)
                default: break
                }
                items.append(try parseValue())
                skipWhitespace()
                if i >= b.count { throw unfinished() }
                switch b[i] {
                case 0x2C:
                    i += 1
                case 0x5D:
                    i += 1
                    return .array(items)
                case 0x7D:
                    throw makeError(.keyValuePairs, "Objects must consist of key:value pairs", at: i)
                case 0x3A:
                    throw makeError(.keyValuePairs, "':' not as part of an object", at: i)
                default:
                    throw try separatorMissing()
                }
            }
        }

        mutating func parseObject() throws -> JSON {
            if depth >= JSONParser.maxDepth {
                throw makeError(.tooDeep, "Exceeds depth limit for parsing", at: i)
            }
            depth += 1
            defer { depth -= 1 }
            i += 1
            var object = JSONObject()
            skipWhitespace()
            if i >= b.count { throw unfinished() }
            if b[i] == 0x7D {
                i += 1
                return .object(object)
            }
            while true {
                skipWhitespace()
                if i >= b.count { throw unfinished() }
                let c = b[i]
                if c != 0x22 {
                    switch c {
                    case 0x7D:
                        throw makeError(.keyValuePairs, "Expected another key-value pair", at: i)
                    case 0x2C:
                        throw makeError(.expectedValue, "Expected value before ','", at: i)
                    case 0x5D:
                        throw makeError(.unmatched("]"), "Unmatched ']' in the middle of an object", at: i)
                    case 0x3A:
                        throw makeError(.keyValuePairs, "Expected string key before ':'", at: i)
                    case 0x5B, 0x7B:
                        throw makeError(.keysMustBeStrings, "Object keys must be strings", at: i)
                    default:
                        // A literal key: jq reports at the byte after the token.
                        let start = i
                        while i < b.count, Scanner.isLiteralByte(b[i]) { i += 1 }
                        if i >= b.count {
                            throw try literalErrorOrUnfinished(start: start)
                        }
                        _ = try? literalValue(start: start, end: i)
                        if b[i] == 0x3A {
                            throw makeError(.keysMustBeStrings, "Object keys must be strings", at: i)
                        }
                        throw makeError(.keyValuePairs, "Objects must consist of key:value pairs", at: i)
                    }
                }
                let key = try parseString()
                skipWhitespace()
                if i >= b.count { throw unfinished() }
                guard b[i] == 0x3A else {
                    switch b[i] {
                    case 0x7D, 0x2C:
                        throw makeError(.keyValuePairs, "Objects must consist of key:value pairs", at: i)
                    default:
                        throw try separatorMissing()
                    }
                }
                i += 1
                skipWhitespace()
                if i >= b.count { throw unfinished() }
                switch b[i] {
                case 0x7D:
                    throw makeError(.unmatched("}"), "Unmatched '}'", at: i)
                case 0x2C:
                    throw makeError(.expectedValue, "Expected value before ','", at: i)
                case 0x5D:
                    throw makeError(.unmatched("]"), "Unmatched ']' in the middle of an object", at: i)
                case 0x3A:
                    throw makeError(.keyValuePairs, "':' should follow a key", at: i)
                default:
                    break
                }
                let value = try parseValue()
                object.set(key, value)
                skipWhitespace()
                if i >= b.count { throw unfinished() }
                switch b[i] {
                case 0x2C:
                    i += 1
                case 0x7D:
                    i += 1
                    return .object(object)
                case 0x5D:
                    throw makeError(.unmatched("]"), "Unmatched ']' in the middle of an object", at: i)
                case 0x3A:
                    throw makeError(.keyValuePairs, "':' should follow a key", at: i)
                default:
                    throw try separatorMissing()
                }
            }
        }

        /// Builds jq's "Expected separator between values" error, positioned
        /// where jq would detect it: at a bracket, at the closing quote of a
        /// string, or just after a literal token.
        mutating func separatorMissing() throws -> JSONParseError {
            let c = b[i]
            if c == 0x5B || c == 0x7B {
                return makeError(.expectedSeparator, "Expected separator between values", at: i)
            }
            if c == 0x22 {
                _ = try parseString()
                return makeError(.expectedSeparator, "Expected separator between values", at: i - 1)
            }
            let start = i
            while i < b.count, Scanner.isLiteralByte(b[i]) { i += 1 }
            if i >= b.count {
                if (try? literalValue(start: start, end: i)) == nil {
                    return try literalErrorOrUnfinished(start: start)
                }
                return makeError(.unfinished, "Unfinished JSON term", atEOF: true)
            }
            if (try? literalValue(start: start, end: i)) == nil {
                return try literalError(start: start, end: i, at: i)
            }
            return makeError(.expectedSeparator, "Expected separator between values", at: i)
        }

        mutating func parseLiteral() throws -> JSON {
            let start = i
            while i < b.count, Scanner.isLiteralByte(b[i]) { i += 1 }
            do {
                return try literalValue(start: start, end: i)
            } catch {
                if i >= b.count {
                    throw try literalErrorOrUnfinished(start: start)
                }
                throw try literalError(start: start, end: i, at: i)
            }
        }

        struct NotALiteral: Error {}

        func literalValue(start: Int, end: Int) throws -> JSON {
            let n = end - start
            guard n > 0 else { throw NotALiteral() }
            let first = b[start]
            switch first {
            case UInt8(ascii: "t"):
                if n == 4, b[start + 1] == UInt8(ascii: "r"), b[start + 2] == UInt8(ascii: "u"), b[start + 3] == UInt8(ascii: "e") {
                    return .true
                }
                throw NotALiteral()
            case UInt8(ascii: "f"):
                if n == 5, b[start + 1] == UInt8(ascii: "a"), b[start + 2] == UInt8(ascii: "l"),
                   b[start + 3] == UInt8(ascii: "s"), b[start + 4] == UInt8(ascii: "e") {
                    return .false
                }
                throw NotALiteral()
            case UInt8(ascii: "n") where n > 1 && b[start + 1] == UInt8(ascii: "u"):
                if n == 4, b[start + 2] == UInt8(ascii: "l"), b[start + 3] == UInt8(ascii: "l") {
                    return .null
                }
                throw NotALiteral()
            default:
                return .number(try Scanner.number(b, start, end))
            }
        }

        /// Parses a number token. Plain integers up to 15 digits take a fast
        /// path; everything else goes through decNumber-style parsing so the
        /// canonical literal survives.
        static func number(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) throws -> JSONNumber {
            var j = start
            var negative = false
            if b[j] == UInt8(ascii: "-") {
                negative = true
                j += 1
            }
            let digitCount = end - j
            if digitCount > 0 && digitCount <= 15 {
                var simple = true
                var v: Int64 = 0
                var k = j
                while k < end {
                    let c = b[k]
                    if c < 48 || c > 57 { simple = false; break }
                    v = v * 10 + Int64(c - 48)
                    k += 1
                }
                if simple && !(digitCount > 1 && b[j] == 48) && !(negative && v == 0) {
                    let text = String(decoding: UnsafeBufferPointer(rebasing: b[start..<end]), as: UTF8.self)
                    return JSONNumber(value: Double(negative ? -v : v), literal: text, needsDecimalComparison: false)
                }
            }
            let text = String(decoding: UnsafeBufferPointer(rebasing: b[start..<end]), as: UTF8.self)
            guard let literal = DecimalLiteral(Substring(text)) else { throw NotALiteral() }
            return literal.makeNumber()
        }

        /// jq checks `true`, `false` and `null` (an `n` followed by `u`) as
        /// words; every other token is parsed as a number.
        func isWordToken(_ start: Int, _ end: Int) -> Bool {
            switch b[start] {
            case UInt8(ascii: "t"), UInt8(ascii: "f"): return true
            case UInt8(ascii: "n"): return end - start > 1 && b[start + 1] == UInt8(ascii: "u")
            default: return false
            }
        }

        func literalError(start: Int, end: Int, at position: Int) throws -> JSONParseError {
            let token = String(decoding: UnsafeBufferPointer(rebasing: b[start..<end]), as: UTF8.self)
            if isWordToken(start, end) {
                return makeError(.invalidLiteral(token), "Invalid literal", at: position)
            }
            return makeError(.invalidNumber(token), "Invalid numeric literal", at: position)
        }

        func literalErrorOrUnfinished(start: Int) throws -> JSONParseError {
            let token = String(decoding: UnsafeBufferPointer(rebasing: b[start..<b.count]), as: UTF8.self)
            if isWordToken(start, b.count) {
                return makeError(.invalidLiteral(token), "Invalid literal", atEOF: true)
            }
            return makeError(.invalidNumber(token), "Invalid numeric literal", atEOF: true)
        }

        // MARK: Strings

        mutating func parseString() throws -> String {
            let openQuote = i
            i += 1
            let start = i
            // Fast path: no escapes and no control characters.
            while i < b.count {
                let c = b[i]
                if c == 0x22 {
                    let s = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
                    i += 1
                    return s
                }
                if c == 0x5C || c < 0x20 { break }
                i += 1
            }
            i = start
            return try parseEscapedString(openQuote: openQuote)
        }

        mutating func parseEscapedString(openQuote: Int) throws -> String {
            // Find the closing quote first: jq reports escape errors there.
            var end = i
            var sawControl = false
            while end < b.count {
                let c = b[end]
                if c == 0x22 { break }
                if c == 0x5C {
                    end += 2
                    continue
                }
                if c < 0x20 { sawControl = true }
                end += 1
            }
            if end >= b.count {
                i = b.count
                throw makeError(.unfinishedString, "Unfinished string", atEOF: true)
            }
            var out: [UInt8] = []
            out.reserveCapacity(end - i)
            var k = i
            while k < end {
                let c = b[k]
                if c != 0x5C {
                    out.append(c)
                    k += 1
                    continue
                }
                k += 1
                guard k < end else {
                    throw makeError(.invalidEscape, "Expected escape character at end of string", at: end)
                }
                let e = b[k]
                k += 1
                switch e {
                case 0x22: out.append(0x22)
                case 0x5C: out.append(0x5C)
                case 0x2F: out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard k + 4 <= end else {
                        throw makeError(.invalidUnicodeEscape, "Invalid \\uXXXX escape", at: end)
                    }
                    guard let unit = Scanner.hex4(b, k) else {
                        throw makeError(.invalidUnicodeEscape, "Invalid characters in \\uXXXX escape", at: end)
                    }
                    k += 4
                    var scalarValue = UInt32(unit)
                    if unit >= 0xD800 && unit <= 0xDBFF {
                        guard k + 6 <= end, b[k] == 0x5C, b[k + 1] == UInt8(ascii: "u"),
                              let low = Scanner.hex4(b, k + 2), low >= 0xDC00, low <= 0xDFFF else {
                            throw makeError(.invalidSurrogate, "Invalid \\uXXXX\\uXXXX surrogate pair escape", at: end)
                        }
                        k += 6
                        scalarValue = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                    } else if unit >= 0xDC00 && unit <= 0xDFFF {
                        throw makeError(.invalidSurrogate, "Invalid \\uXXXX\\uXXXX surrogate pair escape", at: end)
                    }
                    Scanner.appendUTF8(scalarValue, to: &out)
                default:
                    throw makeError(.invalidEscape, "Invalid escape", at: end)
                }
            }
            if sawControl {
                throw makeError(.controlCharacter, "Invalid string: control characters from U+0000 through U+001F must be escaped", at: end)
            }
            i = end + 1
            return String(decoding: out, as: UTF8.self)
        }

        static func hex4(_ b: UnsafeBufferPointer<UInt8>, _ at: Int) -> UInt16? {
            var v: UInt16 = 0
            for k in at..<(at + 4) {
                let c = b[k]
                let d: UInt16
                switch c {
                case 48...57: d = UInt16(c - 48)
                case 65...70: d = UInt16(c - 55)
                case 97...102: d = UInt16(c - 87)
                default: return nil
                }
                v = v << 4 | d
            }
            return v
        }

        static func appendUTF8(_ scalar: UInt32, to out: inout [UInt8]) {
            switch scalar {
            case 0..<0x80:
                out.append(UInt8(scalar))
            case 0x80..<0x800:
                out.append(UInt8(0xC0 | (scalar >> 6)))
                out.append(UInt8(0x80 | (scalar & 0x3F)))
            case 0x800..<0x10000:
                out.append(UInt8(0xE0 | (scalar >> 12)))
                out.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
                out.append(UInt8(0x80 | (scalar & 0x3F)))
            default:
                out.append(UInt8(0xF0 | (scalar >> 18)))
                out.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
                out.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
                out.append(UInt8(0x80 | (scalar & 0x3F)))
            }
        }

        // MARK: Errors

        func unfinished() -> JSONParseError {
            makeError(.unfinished, "Unfinished JSON term", atEOF: true)
        }

        /// An error triggered by the byte at `position`.
        func makeError(_ kind: JSONParseError.Kind, _ message: String, at position: Int) -> JSONParseError {
            let (line, column, characterColumn) = location(through: position)
            return JSONParseError(kind: kind, message: message, line: line, column: column,
                                  characterColumn: characterColumn, atEOF: false, offset: position)
        }

        func makeError(_ kind: JSONParseError.Kind, _ message: String, atEOF: Bool) -> JSONParseError {
            let (line, column, characterColumn) = location(through: b.count - 1)
            return JSONParseError(kind: kind, message: message, line: line, column: column,
                                  characterColumn: characterColumn, atEOF: atEOF, offset: b.count)
        }

        /// jq's line and column after consuming the byte at `position`, plus a
        /// 1-based character column for people.
        func location(through position: Int) -> (Int, Int, Int) {
            var line = 1
            var column = 0
            var lineStart = 0
            var k = 0
            let last = min(position, b.count - 1)
            if last < 0 { return (1, 0, 1) }
            while k <= last {
                column += 1
                if b[k] == 0x0A {
                    line += 1
                    column = 0
                    lineStart = k + 1
                }
                k += 1
            }
            var characters = 0
            var m = lineStart
            while m <= last {
                if b[m] & 0xC0 != 0x80 { characters += 1 }
                m += 1
            }
            return (line, column, max(characters, 1))
        }
    }
}
