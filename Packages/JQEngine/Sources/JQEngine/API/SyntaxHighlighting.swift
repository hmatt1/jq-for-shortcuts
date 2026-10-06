import Foundation

/// One colored span of a filter, for an editor.
public struct JQSyntaxToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `if`, `then`, `def`, `reduce`, `as`, `and`, ...
        case keyword
        /// `true`, `false`, `null`
        case literal
        case number
        /// A string literal, quotes included. Interpolations split it into parts.
        case string
        /// The `\(` and `)` around a string interpolation.
        case interpolation
        /// `.`, `.name`, `..`
        case field
        /// `$name`, `$__loc__`
        case variable
        /// A function name such as `map` or `select`.
        case function
        /// `@base64`, `@csv`, ...
        case format
        /// `|`, `,`, `+`, `==`, `//`, `|=`, `?`, ...
        case `operator`
        /// `(`, `)`, `[`, `]`, `{`, `}`
        case bracket
        case comment
        /// A character jq does not accept here, or an unterminated string.
        case invalid
    }

    public var kind: Kind
    /// UTF-8 byte offsets in the filter.
    public var range: SourceRange

    public init(kind: Kind, range: SourceRange) {
        self.kind = kind
        self.range = range
    }
}

/// An opening bracket and the bracket that closes it. Either side is nil
/// when the filter has no partner for it.
public struct JQBracketPair: Sendable, Equatable {
    /// UTF-8 byte offset of `(`, `[`, `{` or the `(` of `\(`.
    public var open: Int?
    /// UTF-8 byte offset of the matching `)`, `]` or `}`.
    public var close: Int?

    public init(open: Int?, close: Int?) {
        self.open = open
        self.close = close
    }
}

public struct JQSyntaxAnalysis: Sendable, Equatable {
    public var tokens: [JQSyntaxToken]
    public var brackets: [JQBracketPair]

    /// The pair whose opening or closing bracket sits at `offset` or ends
    /// just before it, which is where the cursor is after typing a bracket.
    public func bracketPair(near offset: Int) -> JQBracketPair? {
        if let pair = brackets.first(where: { $0.close == offset - 1 || $0.open == offset - 1 }) {
            return pair
        }
        return brackets.first(where: { $0.open == offset || $0.close == offset })
    }
}

/// Splits a filter into colored spans without compiling it, so the editor
/// can color a filter that does not parse yet.
public enum JQSyntaxHighlighter {
    public static func analyze(_ source: String) -> JQSyntaxAnalysis {
        var scanner = HighlightScanner(Array(source.utf8))
        scanner.run()
        return JQSyntaxAnalysis(tokens: scanner.tokens, brackets: scanner.pairs)
    }
}

private struct HighlightScanner {
    private enum Mode {
        /// Ordinary filter text. `interpolationDepth` counts the parentheses
        /// opened inside a `\( ... )`, or is nil outside an interpolation.
        case code(interpolationDepth: Int?)
        /// Inside a string literal; the current text part starts at `segmentStart`.
        case string(segmentStart: Int)
    }

    private struct OpenBracket {
        let offset: Int
        let byte: UInt8
    }

    let bytes: [UInt8]
    var position = 0
    var tokens: [JQSyntaxToken] = []
    var pairs: [JQBracketPair] = []
    private var modes: [Mode] = [.code(interpolationDepth: nil)]
    private var openBrackets: [OpenBracket] = []

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    private static let keywords: Set<String> = [
        "as", "import", "include", "module", "def", "if", "then", "else", "elif", "and", "or", "end",
        "reduce", "foreach", "try", "catch", "label", "break", "not",
    ]
    private static let literals: Set<String> = ["true", "false", "null"]
    private static let operators: [[UInt8]] = [
        "?//", "//=", "|=", "+=", "-=", "*=", "/=", "%=", "==", "!=", "<=", ">=", "//",
        "?", "=", ";", ",", ":", "|", "+", "-", "*", "/", "%", "<", ">",
    ].map { Array($0.utf8) }

    mutating func run() {
        while position < bytes.count {
            switch modes[modes.count - 1] {
            case .string(let segmentStart):
                scanString(segmentStart: segmentStart)
            case .code(let depth):
                scanCode(interpolationDepth: depth)
            }
        }
        if case .string(let segmentStart) = modes[modes.count - 1] {
            // A string that never closes.
            mark(.invalid, segmentStart, bytes.count)
        }
        for open in openBrackets {
            pairs.append(JQBracketPair(open: open.offset, close: nil))
        }
        pairs.sort { ($0.open ?? $0.close ?? 0) < ($1.open ?? $1.close ?? 0) }
    }

    private mutating func mark(_ kind: JQSyntaxToken.Kind, _ start: Int, _ end: Int) {
        guard end > start else { return }
        tokens.append(JQSyntaxToken(kind: kind, range: SourceRange(start, end)))
    }

    // MARK: Code

    private mutating func scanCode(interpolationDepth: Int?) {
        let c = bytes[position]
        let start = position

        if c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D {
            position += 1
            return
        }
        if c == UInt8(ascii: "#") {
            while position < bytes.count, bytes[position] != 0x0A { position += 1 }
            mark(.comment, start, position)
            return
        }
        if isIdentStart(c) {
            let name = scanIdentifier()
            if Self.keywords.contains(name) {
                mark(.keyword, start, position)
            } else if Self.literals.contains(name) {
                mark(.literal, start, position)
            } else {
                mark(.function, start, position)
            }
            return
        }
        if isDigit(c) || (c == UInt8(ascii: ".") && position + 1 < bytes.count && isDigit(bytes[position + 1])) {
            scanNumber()
            mark(.number, start, position)
            return
        }
        switch c {
        case UInt8(ascii: "."):
            position += 1
            if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
                position += 1
            } else if position < bytes.count, isIdentStart(bytes[position]) {
                while position < bytes.count, isIdentContinue(bytes[position]) { position += 1 }
            }
            mark(.field, start, position)
            return
        case UInt8(ascii: "$"):
            position += 1
            if position < bytes.count, isIdentStart(bytes[position]) {
                _ = scanIdentifier()
                mark(.variable, start, position)
            } else {
                mark(.invalid, start, position)
            }
            return
        case UInt8(ascii: "@"):
            position += 1
            while position < bytes.count, isIdentContinue(bytes[position]) { position += 1 }
            mark(position > start + 1 ? .format : .invalid, start, position)
            return
        case UInt8(ascii: "\""):
            position += 1
            modes.append(.string(segmentStart: start))
            return
        case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"):
            position += 1
            mark(.bracket, start, position)
            openBrackets.append(OpenBracket(offset: start, byte: c))
            if c == UInt8(ascii: "("), let depth = interpolationDepth {
                modes[modes.count - 1] = .code(interpolationDepth: depth + 1)
            }
            return
        case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"):
            position += 1
            if c == UInt8(ascii: ")"), interpolationDepth == 0 {
                // Closes `\(`: back into the string.
                mark(.interpolation, start, position)
                closeBracket(at: start, byte: c)
                modes.removeLast()
                modes[modes.count - 1] = .string(segmentStart: position)
                return
            }
            mark(.bracket, start, position)
            closeBracket(at: start, byte: c)
            if c == UInt8(ascii: ")"), let depth = interpolationDepth {
                modes[modes.count - 1] = .code(interpolationDepth: max(depth - 1, 0))
            }
            return
        default:
            break
        }
        for op in Self.operators where matches(op) {
            position += op.count
            mark(.operator, start, position)
            return
        }
        position = scalarEnd(from: position)
        mark(.invalid, start, position)
    }

    private mutating func closeBracket(at offset: Int, byte: UInt8) {
        let expected: UInt8
        switch byte {
        case UInt8(ascii: ")"): expected = UInt8(ascii: "(")
        case UInt8(ascii: "]"): expected = UInt8(ascii: "[")
        default: expected = UInt8(ascii: "{")
        }
        if let last = openBrackets.last, last.byte == expected {
            openBrackets.removeLast()
            pairs.append(JQBracketPair(open: last.offset, close: offset))
        } else {
            pairs.append(JQBracketPair(open: nil, close: offset))
        }
    }

    // MARK: Strings

    private mutating func scanString(segmentStart: Int) {
        while position < bytes.count {
            let c = bytes[position]
            if c == UInt8(ascii: "\"") {
                position += 1
                mark(.string, segmentStart, position)
                modes.removeLast()
                return
            }
            if c == UInt8(ascii: "\\") {
                if position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: "(") {
                    mark(.string, segmentStart, position)
                    mark(.interpolation, position, position + 2)
                    openBrackets.append(OpenBracket(offset: position + 1, byte: UInt8(ascii: "(")))
                    position += 2
                    modes.append(.code(interpolationDepth: 0))
                    return
                }
                position = min(position + 2, bytes.count)
                continue
            }
            position += 1
        }
    }

    // MARK: Helpers

    private func matches(_ text: [UInt8]) -> Bool {
        guard position + text.count <= bytes.count else { return false }
        for i in 0..<text.count where bytes[position + i] != text[i] { return false }
        return true
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

    private mutating func scanIdentifier() -> String {
        let start = position
        position += 1
        while position < bytes.count, isIdentContinue(bytes[position]) { position += 1 }
        while position + 2 < bytes.count,
              bytes[position] == UInt8(ascii: ":"), bytes[position + 1] == UInt8(ascii: ":"),
              isIdentStart(bytes[position + 2]) {
            position += 3
            while position < bytes.count, isIdentContinue(bytes[position]) { position += 1 }
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    private mutating func scanNumber() {
        while position < bytes.count, isDigit(bytes[position]) { position += 1 }
        if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
            position += 1
            while position < bytes.count, isDigit(bytes[position]) { position += 1 }
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
            var p = position + 1
            if p < bytes.count, bytes[p] == UInt8(ascii: "+") || bytes[p] == UInt8(ascii: "-") { p += 1 }
            if p < bytes.count, isDigit(bytes[p]) {
                while p < bytes.count, isDigit(bytes[p]) { p += 1 }
                position = p
            }
        }
    }

    private func scalarEnd(from index: Int) -> Int {
        var end = index + 1
        while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
        return end
    }
}
