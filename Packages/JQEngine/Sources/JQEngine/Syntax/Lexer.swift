import Foundation

/// A half-open range of UTF-8 byte offsets in the filter text.
public struct SourceRange: Sendable, Equatable, Hashable {
    public var start: Int
    public var end: Int

    public init(_ start: Int, _ end: Int) {
        self.start = start
        self.end = max(start, end)
    }

    public static let none = SourceRange(0, 0)

    func union(_ other: SourceRange) -> SourceRange {
        SourceRange(min(start, other.start), max(end, other.end))
    }
}

enum TokenKind: Equatable {
    case ident(String)          // name, may contain ::
    case field(String)          // .name
    case binding(String)        // $name
    case loc                    // $__loc__
    case format(String)         // @name
    case number(JSONNumber)
    case stringStart            // "
    case keyword(Keyword)
    case op(String)             // punctuation and operators
    case eof
    case invalid(Character)

    static func == (lhs: TokenKind, rhs: TokenKind) -> Bool {
        switch (lhs, rhs) {
        case (.ident(let a), .ident(let b)): return a == b
        case (.field(let a), .field(let b)): return a == b
        case (.binding(let a), .binding(let b)): return a == b
        case (.loc, .loc): return true
        case (.format(let a), .format(let b)): return a == b
        case (.number(let a), .number(let b)): return a.value == b.value
        case (.stringStart, .stringStart): return true
        case (.keyword(let a), .keyword(let b)): return a == b
        case (.op(let a), .op(let b)): return a == b
        case (.eof, .eof): return true
        case (.invalid(let a), .invalid(let b)): return a == b
        default: return false
        }
    }
}

enum Keyword: String, CaseIterable {
    case `as`, `import`, include, module, def, `if`, then, `else`, elif, and, or, end
    case reduce, foreach, `try`, `catch`, label, `break`
}

struct Token {
    let kind: TokenKind
    let range: SourceRange

    /// How jq's parser names this token in syntax errors.
    var displayName: String {
        switch kind {
        case .ident(let name): return name
        case .field(let name): return ".\(name)"
        case .binding(let name): return "$\(name)"
        case .loc: return "$__loc__"
        case .format(let name): return "@\(name)"
        case .number(let n): return n.jqText
        case .stringStart: return "\""
        case .keyword(let k): return k.rawValue
        case .op(let o): return o
        case .eof: return "end of filter"
        case .invalid(let c): return String(c)
        }
    }
}

/// One piece of a string literal.
enum StringPart {
    case text(String, SourceRange)
    case interpolationStart(SourceRange)   // \(
    case end(SourceRange)                  // closing quote
}

/// The jq 1.7.1 lexer. String literals are lexed on demand by the parser,
/// because an interpolation `\( ... )` switches back to ordinary tokens.
struct Lexer {
    let bytes: [UInt8]
    private(set) var position = 0

    init(_ source: String) {
        bytes = Array(source.utf8)
    }

    // MARK: Ordinary tokens

    mutating func next() throws -> Token {
        skipTrivia()
        guard position < bytes.count else {
            return Token(kind: .eof, range: SourceRange(bytes.count, bytes.count))
        }
        let start = position
        let c = bytes[position]

        if isIdentStart(c) {
            let name = scanIdentifier()
            if let keyword = Keyword(rawValue: name) {
                return Token(kind: .keyword(keyword), range: SourceRange(start, position))
            }
            return Token(kind: .ident(name), range: SourceRange(start, position))
        }
        if isDigit(c) || (c == UInt8(ascii: ".") && position + 1 < bytes.count && isDigit(bytes[position + 1])) {
            return try scanNumber(start)
        }
        switch c {
        case UInt8(ascii: "."):
            if position + 1 < bytes.count {
                let d = bytes[position + 1]
                if d == UInt8(ascii: ".") {
                    position += 2
                    return Token(kind: .op(".."), range: SourceRange(start, position))
                }
                if isIdentStart(d) {
                    position += 1
                    let name = scanPlainIdentifier()
                    return Token(kind: .field(name), range: SourceRange(start, position))
                }
            }
            position += 1
            return Token(kind: .op("."), range: SourceRange(start, position))
        case UInt8(ascii: "$"):
            if matches("$__loc__") {
                let after = position + 8
                if after >= bytes.count || !isIdentContinue(bytes[after]) {
                    position = after
                    return Token(kind: .loc, range: SourceRange(start, position))
                }
            }
            if position + 1 < bytes.count, isIdentStart(bytes[position + 1]) {
                position += 1
                let name = scanIdentifier()
                return Token(kind: .binding(name), range: SourceRange(start, position))
            }
            position += 1
            return Token(kind: .op("$"), range: SourceRange(start, position))
        case UInt8(ascii: "@"):
            var end = position + 1
            while end < bytes.count, isIdentContinue(bytes[end]) { end += 1 }
            if end > position + 1 {
                let name = String(decoding: bytes[(position + 1)..<end], as: UTF8.self)
                position = end
                return Token(kind: .format(name), range: SourceRange(start, position))
            }
            position += 1
            return Token(kind: .invalid("@"), range: SourceRange(start, position))
        case UInt8(ascii: "\""):
            position += 1
            return Token(kind: .stringStart, range: SourceRange(start, position))
        default:
            break
        }
        for op in Lexer.operators where matches(op) {
            position += op.utf8.count
            return Token(kind: .op(op), range: SourceRange(start, position))
        }
        // Any other character, decoded as a whole Unicode scalar.
        let scalarEnd = utf8ScalarEnd(from: position)
        let text = String(decoding: bytes[position..<scalarEnd], as: UTF8.self)
        position = scalarEnd
        return Token(kind: .invalid(text.first ?? "?"), range: SourceRange(start, scalarEnd))
    }

    /// Longest operators first, as flex picks the longest match.
    static let operators: [String] = [
        "?//", "//=", "|=", "+=", "-=", "*=", "/=", "%=", "==", "!=", "<=", ">=", "//",
        "?", "=", ";", ",", ":", "|", "+", "-", "*", "/", "%", "<", ">",
        "[", "]", "{", "}", "(", ")"
    ]

    private func matches(_ text: String) -> Bool {
        let t = Array(text.utf8)
        guard position + t.count <= bytes.count else { return false }
        for i in 0..<t.count where bytes[position + i] != t[i] { return false }
        return true
    }

    private mutating func skipTrivia() {
        while position < bytes.count {
            let c = bytes[position]
            if c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D {
                position += 1
            } else if c == UInt8(ascii: "#") {
                while position < bytes.count, bytes[position] != 0x0A { position += 1 }
            } else {
                return
            }
        }
    }

    private func isIdentStart(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x5F
    }

    private func isIdentContinue(_ c: UInt8) -> Bool {
        isIdentStart(c) || isDigit(c)
    }

    private func isDigit(_ c: UInt8) -> Bool {
        c >= 0x30 && c <= 0x39
    }

    /// `[a-zA-Z_][a-zA-Z_0-9]*`
    private mutating func scanPlainIdentifier() -> String {
        let start = position
        position += 1
        while position < bytes.count, isIdentContinue(bytes[position]) { position += 1 }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    /// `([a-zA-Z_][a-zA-Z_0-9]*::)*[a-zA-Z_][a-zA-Z_0-9]*`
    private mutating func scanIdentifier() -> String {
        let start = position
        _ = scanPlainIdentifier()
        while position + 2 < bytes.count,
              bytes[position] == UInt8(ascii: ":"), bytes[position + 1] == UInt8(ascii: ":"),
              isIdentStart(bytes[position + 2]) {
            position += 2
            _ = scanPlainIdentifier()
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    /// `([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?`
    private mutating func scanNumber(_ start: Int) throws -> Token {
        if bytes[position] == UInt8(ascii: ".") {
            position += 1
            while position < bytes.count, isDigit(bytes[position]) { position += 1 }
        } else {
            while position < bytes.count, isDigit(bytes[position]) { position += 1 }
            if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
                position += 1
                while position < bytes.count, isDigit(bytes[position]) { position += 1 }
            }
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
            var p = position + 1
            if p < bytes.count, bytes[p] == UInt8(ascii: "+") || bytes[p] == UInt8(ascii: "-") { p += 1 }
            if p < bytes.count, isDigit(bytes[p]) {
                while p < bytes.count, isDigit(bytes[p]) { p += 1 }
                position = p
            }
        }
        let text = String(decoding: bytes[start..<position], as: UTF8.self)
        guard let number = JSONNumber(literal: text) else {
            throw SyntaxError(kind: .invalidNumber(text), range: SourceRange(start, position))
        }
        return Token(kind: .number(number), range: SourceRange(start, position))
    }

    private func utf8ScalarEnd(from index: Int) -> Int {
        var end = index + 1
        while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
        return end
    }

    // MARK: String literals

    /// Reads the next piece of a string literal, after the opening quote or
    /// after the `)` that closes an interpolation.
    mutating func nextStringPart(openQuote: Int) throws -> StringPart {
        let start = position
        var text: [UInt8] = []
        while position < bytes.count {
            let c = bytes[position]
            if c == UInt8(ascii: "\"") {
                if position > start {
                    return .text(String(decoding: text, as: UTF8.self), SourceRange(start, position))
                }
                position += 1
                return .end(SourceRange(start, position))
            }
            if c == UInt8(ascii: "\\") {
                guard position + 1 < bytes.count else {
                    throw SyntaxError(kind: .unterminatedString, range: SourceRange(openQuote, bytes.count))
                }
                let e = bytes[position + 1]
                if e == UInt8(ascii: "(") {
                    if position > start {
                        return .text(String(decoding: text, as: UTF8.self), SourceRange(start, position))
                    }
                    position += 2
                    return .interpolationStart(SourceRange(start, position))
                }
                let escapeStart = position
                position += 2
                switch e {
                case UInt8(ascii: "\""): text.append(0x22)
                case UInt8(ascii: "\\"): text.append(0x5C)
                case UInt8(ascii: "/"): text.append(0x2F)
                case UInt8(ascii: "b"): text.append(0x08)
                case UInt8(ascii: "f"): text.append(0x0C)
                case UInt8(ascii: "n"): text.append(0x0A)
                case UInt8(ascii: "r"): text.append(0x0D)
                case UInt8(ascii: "t"): text.append(0x09)
                case UInt8(ascii: "u"):
                    guard let unit = hex4(at: position) else {
                        throw SyntaxError(kind: .invalidEscape("\\u"), range: SourceRange(escapeStart, min(position + 4, bytes.count)))
                    }
                    position += 4
                    var scalar = UInt32(unit)
                    if unit >= 0xD800 && unit <= 0xDBFF {
                        guard position + 6 <= bytes.count, bytes[position] == UInt8(ascii: "\\"),
                              bytes[position + 1] == UInt8(ascii: "u"), let low = hex4(at: position + 2),
                              low >= 0xDC00, low <= 0xDFFF else {
                            throw SyntaxError(kind: .invalidEscape("\\u\(String(unit, radix: 16))"), range: SourceRange(escapeStart, position))
                        }
                        position += 6
                        scalar = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                    } else if unit >= 0xDC00 && unit <= 0xDFFF {
                        throw SyntaxError(kind: .invalidEscape("\\u\(String(unit, radix: 16))"), range: SourceRange(escapeStart, position))
                    }
                    JSONParser.Scanner.appendUTF8(scalar, to: &text)
                default:
                    let shown = String(decoding: bytes[escapeStart..<utf8ScalarEnd(from: escapeStart + 1)], as: UTF8.self)
                    throw SyntaxError(kind: .invalidEscape(shown), range: SourceRange(escapeStart, utf8ScalarEnd(from: escapeStart + 1)))
                }
                continue
            }
            text.append(c)
            position += 1
        }
        throw SyntaxError(kind: .unterminatedString, range: SourceRange(openQuote, bytes.count))
    }

    private func hex4(at index: Int) -> UInt16? {
        guard index + 4 <= bytes.count else { return nil }
        var v: UInt16 = 0
        for k in index..<(index + 4) {
            let c = bytes[k]
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
}
