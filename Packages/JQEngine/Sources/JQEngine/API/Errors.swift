import Foundation

/// A problem in the filter text, found before the filter runs.
public struct JQCompileError: Error, Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case emptyFilter
        /// A token that cannot appear here, where an operator or the end was expected.
        case unexpectedToken(String)
        /// An operator or closing bracket where a value was expected.
        case missingValueBefore(String)
        /// The filter ends where a value was expected.
        case unexpectedEnd
        /// An opening bracket, string or keyword that is never closed.
        case unclosed(String, opening: SourceRange)
        case unterminatedString
        case invalidEscape(String)
        case invalidNumber(String)
        case invalidCharacter(String)
        /// A curly quote from a phone keyboard, which jq does not accept.
        case curlyQuote(String)
        /// `{a: 1 + 2}` needs parentheses around the value.
        case objectValueNeedsParentheses
        /// `{1: 2}` needs parentheses around the key.
        case objectKeyNeedsParentheses
        /// A constant object key that is not a string.
        case invalidObjectKey(String)
        /// The filter only defines functions.
        case topLevelProgramNotGiven
        case undefinedFunction(name: String, arity: Int, suggestion: String?)
        case undefinedVariable(String)
        /// A jq feature this engine removes, such as `$ENV` or `input`.
        case disabledFeature(String)
        case undefinedLabel(String)
    }

    public let kind: Kind
    /// UTF-8 byte offsets in the filter.
    public let range: SourceRange
    /// A jq-style description of the problem.
    public let message: String

    public init(kind: Kind, range: SourceRange, message: String) {
        self.kind = kind
        self.range = range
        self.message = message
    }

    public var description: String { message }
}

/// Syntax errors raised while lexing and parsing; converted to
/// `JQCompileError` before they leave the engine.
struct SyntaxError: Error {
    let kind: JQCompileError.Kind
    let range: SourceRange
}

/// An error raised while a filter runs. `try ... catch` sees `value`.
public struct JQRuntimeError: Error, Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// `error(x)` called by the filter.
        case custom
        case iterate(type: String)
        case index(target: String, key: String)
        case arithmetic(operation: BinaryOperator, lhs: String, rhs: String)
        case divideByZero
        case negate(type: String)
        case invalidPath
        case objectKey(type: String)
        case length(type: String)
        case other
    }

    /// The error value; a string for every error jq raises itself.
    public let value: JSON
    public let kind: Kind
    /// The part of the filter that raised the error.
    public internal(set) var range: SourceRange?
    /// The expression whose value caused the error, such as `.items` in
    /// `.items[]` when `.items` is null.
    public internal(set) var subjectRange: SourceRange?

    public init(_ message: String, kind: Kind = .other) {
        self.value = .string(message)
        self.kind = kind
    }

    public init(value: JSON, kind: Kind) {
        self.value = value
        self.kind = kind
    }

    /// The message text: the string itself, or the value as JSON.
    public var message: String {
        if case .string(let s) = value { return s }
        return JSONWriter.string(value)
    }

    /// What jq's command line prints for an uncaught error.
    public var jqDescription: String {
        if case .string(let s) = value { return s }
        return "\(JSONWriter.string(value)) (not a string)"
    }

    public var description: String { jqDescription }

    func located(_ range: SourceRange, subject: SourceRange? = nil) -> JQRuntimeError {
        guard self.range == nil, range.isValid else { return self }
        var copy = self
        copy.range = range
        if let subject, subject.isValid { copy.subjectRange = subject }
        return copy
    }
}

/// Why a run stopped before the filter finished. These cannot be caught by
/// `try` inside the filter.
public enum JQStopReason: Error, Sendable, Equatable {
    case timeout(seconds: Double)
    case memoryLimit(bytes: UInt64)
    case cancelled
    case recursionLimit
}

/// `halt` and `halt_error` end the run; `halt` keeps the results produced so
/// far, `halt_error` reports its message as the error.
public struct JQHalt: Error, Sendable {
    public let exitCode: Int
    /// nil for `halt`; the message value for `halt_error`.
    public let message: JSON?
}

/// Errors that end a generator early, the way jq 1.7.1's `break` does.
/// Destructuring alternatives (`?//`) react to them like errors.
protocol ControlFlowStop: Error {}

/// Control flow for `label $name | ... break $name`. jq 1.7.1 implements
/// `break` as an error whose value is `{"__jq": n}`, so an inner `try`
/// catches it with that value.
struct BreakSignal: ControlFlowStop {
    let label: LabelToken
}

final class LabelToken {
    let number: Int

    init(number: Int) {
        self.number = number
    }

    /// The error value jq raises for `break`.
    var value: JSON {
        var o = JSONObject()
        o["__jq"] = .number(number)
        return .object(o)
    }
}

extension SourceRange {
    /// Converts a UTF-8 byte offset into a 0-based character offset.
    public static func characterOffset(in source: String, utf8Offset: Int) -> Int {
        let target = min(max(utf8Offset, 0), source.utf8.count)
        var bytes = 0
        var characters = 0
        for character in source {
            let width = character.utf8.count
            if bytes + width > target { break }
            bytes += width
            characters += 1
        }
        return characters
    }

    /// The range as UTF-16 offsets, for text views.
    public func utf16Range(in source: String) -> Range<Int> {
        func convert(_ offset: Int) -> Int {
            let utf8 = source.utf8
            let clamped = min(max(offset, 0), utf8.count)
            let index = utf8.index(utf8.startIndex, offsetBy: clamped)
            return source.utf16.distance(from: source.utf16.startIndex, to: index)
        }
        let s = convert(start)
        let e = convert(end)
        return s..<max(s, e)
    }

    /// The filter text the range covers.
    public func text(in source: String) -> String {
        let bytes = Array(source.utf8)
        let s = min(max(start, 0), bytes.count)
        let e = min(max(end, s), bytes.count)
        return String(decoding: bytes[s..<e], as: UTF8.self)
    }
}
