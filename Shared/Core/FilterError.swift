import Foundation
import JQEngine

/// Every failure a run can report. `message` gives the R8 wording: it names
/// the position or value involved and one next step, and never shows an
/// engine error code (R8.14).
enum FilterError: Error, Equatable, Sendable {
    /// What a timeout message suggests next (R8.5).
    enum TimeoutNextStep: Equatable, Sendable {
        /// An action run: raise the Timeout parameter.
        case raiseTimeout
        /// A background run that hit the background time cap.
        case runInApp
        /// The Playground and other places without a Timeout setting.
        case narrow
        /// Validate, Format, path and CSV actions, which run no filter.
        case smallerInput
    }

    case emptyFilter
    /// `position` is the 1-based character position; `range` is in UTF-8 bytes.
    case syntax(position: Int, range: SourceRange, detail: String, hint: String?)
    case disabledFeature(name: String, range: SourceRange)
    case undefinedVariable(name: String, range: SourceRange)
    case invalidArgumentName(String)
    case argumentsNotDictionary(found: String)
    case invalidInput(line: Int, column: Int, detail: String)
    case unreadableInput(kind: String)
    case emptyInput
    case inputTooLarge(bytes: Int, limit: Int, context: RunContext, canRunInApp: Bool)
    case runtime(detail: String, subject: String?, hint: String?, range: SourceRange?)
    case halted(message: String)
    case timeout(seconds: Int, nextStep: TimeoutNextStep)
    case memoryLimit(canRunInApp: Bool)
    case recursionLimit
    case cancelled
    case savedFilterDeleted(name: String)
    case savedFilterMissing
    case clipboardEmpty
    case pathSyntax(position: Int, range: SourceRange, detail: String, hint: String?)
    case pathMissing(path: String)
    case pathSelectsNothing
    /// A run-time error while following a path in Get or Set Value at Path.
    case pathFailed(detail: String, subject: String?, hint: String?)
    case notAPath(path: String)
    case tableInput(type: String)

    var message: String {
        switch self {
        case .emptyFilter:
            return String(localized: "Enter a filter. Use . to return the input unchanged.")

        case .syntax(let position, _, let detail, let hint):
            let next = hint ?? String(localized: "Check the filter near that position.")
            return String(localized: "Filter error at position \(position): \(detail). \(next)")

        case .disabledFeature(let name, _):
            return String(localized: "The filter uses \(name), which this app turns off. \(Self.disabledFeatureNextStep(name))")

        case .undefinedVariable(let name, _):
            return String(localized: "The filter uses $\(name), but Arguments has no value named \(name). Add it to Arguments.")

        case .invalidArgumentName(let name):
            return String(localized: "Argument \"\(name)\" is not a valid name. Use letters, digits, and underscores, and start with a letter or underscore.")

        case .argumentsNotDictionary(let found):
            return String(localized: "Arguments must be a dictionary, but it is \(found). Pass a Dictionary with one key per variable.")

        case .invalidInput(let line, let column, let detail):
            return String(localized: "Input is not valid JSON at line \(line), column \(column): \(detail). Check the input.")

        case .unreadableInput(let kind):
            return String(localized: "The input is \(kind), which cannot be read as JSON. Pass text, a file, a dictionary, or a list.")

        case .emptyInput:
            return String(localized: "The input is empty. Pass JSON text, a file, a dictionary, or a list.")

        case .inputTooLarge(let bytes, let limit, let context, let canRunInApp):
            let size = ByteCount.describe(bytes)
            let limitText = ByteCount.describe(limit)
            switch context {
            case .background:
                if canRunInApp {
                    return String(localized: "The input is \(size), over the \(limitText) background limit. Turn on Run in app, or use a smaller input.")
                }
                return String(localized: "The input is \(size), over the \(limitText) background limit. Use a smaller input.")
            case .foreground, .playground:
                return String(localized: "The input is \(size), over the \(limitText) limit. Use a smaller input.")
            case .shareExtension:
                return String(localized: "The input is \(size), over the \(limitText) limit for the share sheet. Run the filter from Shortcuts instead.")
            }

        case .runtime(let detail, let subject, let hint, _):
            var text = String(localized: "Filter failed: \(detail).")
            if let subject { text += " " + subject }
            text += " " + (hint ?? String(localized: "Check the value this step receives, or wrap the step in try to skip errors."))
            return text

        case .halted(let message):
            return message.isEmpty ? String(localized: "The filter stopped with halt_error. Remove it to let the filter finish.") : message

        case .timeout(let seconds, let nextStep):
            switch nextStep {
            case .raiseTimeout:
                return String(localized: "Filter stopped after \(seconds) seconds. Narrow the filter or the input, or raise Timeout.")
            case .runInApp:
                return String(localized: "Filter stopped after \(seconds) seconds, the longest a run can take in the background. Turn on Run in app, or narrow the filter or the input.")
            case .narrow:
                return String(localized: "Filter stopped after \(seconds) seconds. Narrow the filter or the input.")
            case .smallerInput:
                return String(localized: "The action stopped after \(seconds) seconds. Use a smaller input.")
            }

        case .memoryLimit(let canRunInApp):
            if canRunInApp {
                return String(localized: "The filter ran out of memory. Use a smaller input, or turn on Run in app.")
            }
            return String(localized: "The filter ran out of memory. Use a smaller input or a narrower filter.")

        case .recursionLimit:
            return String(localized: "The filter recursed too deeply and stopped. Check that each recursive function has a case that ends it.")

        case .cancelled:
            return String(localized: "The run was cancelled. Run it again to get a result.")

        case .savedFilterDeleted(let name):
            return String(localized: "Saved filter \"\(name)\" was deleted. Pick another one.")

        case .savedFilterMissing:
            return String(localized: "That saved filter no longer exists. Pick another one.")

        case .clipboardEmpty:
            return String(localized: "The clipboard has no text. Copy some JSON, then try again.")

        case .pathSyntax(let position, _, let detail, let hint):
            let next = hint ?? String(localized: "Check the path near that position.")
            return String(localized: "Path error at position \(position): \(detail). \(next)")

        case .pathMissing(let path):
            return String(localized: "There is no value at \(path). Check the path, or set If Missing to Return Nothing.")

        case .pathSelectsNothing:
            return String(localized: "The path selects nothing. Use a path such as .data.items[0].")

        case .pathFailed(let detail, let subject, let hint):
            var text = String(localized: "Path failed: \(detail).")
            if let subject { text += " " + subject }
            text += " " + (hint ?? String(localized: "Check the path against the input."))
            return text

        case .notAPath(let path):
            return String(localized: "\(path) is not a path. Use keys and indexes, such as .data.items[0].")

        case .tableInput(let type):
            return String(localized: "JSON to CSV needs a list of objects, but the input is \(Self.describeType(type)). Pass an array of objects.")
        }
    }

    /// The part of the filter to underline in the editor (R6.10), in UTF-8
    /// byte offsets of the filter or path text.
    var highlight: SourceRange? {
        switch self {
        case .syntax(_, let range, _, _), .pathSyntax(_, let range, _, _):
            return range
        case .disabledFeature(_, let range), .undefinedVariable(_, let range):
            return range
        case .runtime(_, _, _, let range):
            return range
        default:
            return nil
        }
    }

    /// Errors that come from the filter text itself, as opposed to the input
    /// or the limits.
    var isFilterProblem: Bool {
        switch self {
        case .emptyFilter, .syntax, .disabledFeature, .undefinedVariable, .runtime, .halted, .recursionLimit:
            return true
        default:
            return false
        }
    }

    private static func disabledFeatureNextStep(_ name: String) -> String {
        switch name {
        case "$ENV", "env":
            return String(localized: "Remove it, or pass the value in Arguments.")
        case "input", "inputs":
            return String(localized: "Remove it, or turn on Slurp to get every input value at once.")
        case "input_filename":
            return String(localized: "Remove it. Input comes from Shortcuts, not from a file name.")
        default:
            return String(localized: "Remove it, and define the functions you need in the filter itself.")
        }
    }

    /// "null", "a number", "text", "a list", "an object", "a boolean".
    static func describeType(_ typeName: String) -> String {
        switch typeName {
        case "null": return String(localized: "null")
        case "boolean": return String(localized: "a boolean")
        case "number": return String(localized: "a number")
        case "string": return String(localized: "text")
        case "array": return String(localized: "a list")
        case "object": return String(localized: "an object")
        default: return typeName
        }
    }
}

extension FilterError: LocalizedError {
    var errorDescription: String? { message }
}

// MARK: - Mapping engine errors

enum FilterErrorMapper {
    /// A compile error as the most specific R8 error. `isPath` words it for
    /// Get Value at Path and Set Value at Path.
    static func compile(_ error: JQCompileError, source: String, isPath: Bool = false) -> FilterError {
        switch error.kind {
        case .emptyFilter:
            return isPath ? .pathSelectsNothing : .emptyFilter
        case .disabledFeature(let name):
            return .disabledFeature(name: name, range: error.range)
        case .undefinedVariable(let name):
            return .undefinedVariable(name: name, range: error.range)
        default:
            break
        }
        var kind = error.kind
        var range = error.range
        if let opener = unclosedOpener(before: error, in: source) {
            // A closing bracket that does not match, or the end of the filter,
            // usually means an earlier bracket was never closed.
            kind = .unclosed(opener.text, opening: opener.range)
        }
        if case .unclosed(_, let opening) = kind {
            range = opening
        }
        let position = SourceRange.characterOffset(in: source, utf8Offset: range.start) + 1
        let (detail, hint) = describe(kind)
        return isPath
            ? .pathSyntax(position: position, range: range, detail: detail, hint: hint)
            : .syntax(position: position, range: range, detail: detail, hint: hint)
    }

    private static let closingBrackets: Set<String> = [")", "]", "}"]

    /// The innermost bracket opened before a misplaced closing bracket or the
    /// end of the filter that has no partner.
    private static func unclosedOpener(before error: JQCompileError, in source: String) -> (text: String, range: SourceRange)? {
        switch error.kind {
        case .unexpectedToken(let token) where closingBrackets.contains(token):
            break
        case .missingValueBefore(let token) where closingBrackets.contains(token):
            break
        case .unexpectedEnd:
            break
        default:
            return nil
        }
        let openers = JQSyntaxHighlighter.analyze(source).brackets
            .compactMap { pair -> Int? in pair.close == nil ? pair.open : nil }
            .filter { $0 < error.range.start }
        guard let offset = openers.max() else { return nil }
        let bytes = Array(source.utf8)
        // `\(` opens an interpolation; show it as the parenthesis it is.
        let text = String(decoding: [bytes[offset]], as: UTF8.self)
        return (text, SourceRange(offset, offset + 1))
    }
    private static let clauseKeywords: Set<String> = ["then", "else", "elif", "end", "catch"]

    private static func describe(_ kind: JQCompileError.Kind) -> (String, String?) {
        switch kind {
        case .missingValueBefore(let token):
            let hint = closingBrackets.contains(token)
                ? String(localized: "Check for a missing value or an extra closing bracket before it.")
                : String(localized: "Check for a missing value before it.")
            return (String(localized: "unexpected \"\(token)\""), hint)
        case .unexpectedToken(let token):
            if closingBrackets.contains(token) {
                return (String(localized: "unexpected \"\(token)\""), String(localized: "Check for an extra closing bracket."))
            }
            if clauseKeywords.contains(token) {
                return (String(localized: "unexpected \"\(token)\""), String(localized: "Check the if or try before it."))
            }
            return (String(localized: "unexpected \"\(token)\""), String(localized: "Check for a missing | or , before it."))
        case .unexpectedEnd:
            return (String(localized: "the filter ends too early"),
                    String(localized: "Check for a missing value or closing bracket."))
        case .unclosed(let opener, _):
            return (String(localized: "\"\(opener)\" is never closed"), closingHint(for: opener))
        case .unterminatedString:
            return (String(localized: "this string is never closed"), String(localized: "Add the closing quote."))
        case .invalidEscape(let escape):
            return (String(localized: "\"\(escape)\" is not a valid escape"),
                    String(localized: "Write a backslash inside a string as two backslashes."))
        case .invalidNumber(let text):
            return (String(localized: "\"\(text)\" is not a valid number"), String(localized: "Check the digits."))
        case .invalidCharacter(let character):
            return (String(localized: "unexpected character \"\(character)\""),
                    String(localized: "Remove it, or put it inside a string."))
        case .curlyQuote(let quote):
            return (String(localized: "\(quote) is a curly quote"),
                    String(localized: "Replace it with a straight quote (\"), or turn off Smart Punctuation."))
        case .objectValueNeedsParentheses:
            return (String(localized: "an object value needs parentheses here"),
                    String(localized: "Wrap the value in ( ), for example {total: (.a + .b)}."))
        case .objectKeyNeedsParentheses:
            return (String(localized: "an object key needs parentheses here"),
                    String(localized: "Wrap the key in ( ), for example {(.name): .value}."))
        case .invalidObjectKey(let description):
            return (String(localized: "\(description) cannot be an object key"), String(localized: "Use text as the key."))
        case .topLevelProgramNotGiven:
            return (String(localized: "the filter only defines functions"),
                    String(localized: "Add a filter after the last semicolon, for example ."))
        case .undefinedFunction(let name, let arity, let suggestion):
            let detail = String(localized: "\(name)/\(arity) is not a known function")
            if let suggestion {
                return (detail, String(localized: "Did you mean \(suggestion)?"))
            }
            return (detail, String(localized: "Check the spelling, or look it up on the Reference tab."))
        case .undefinedLabel(let name):
            return (String(localized: "break $\(name) has no matching label"),
                    String(localized: "Add label $\(name) | before it."))
        case .emptyFilter, .disabledFeature, .undefinedVariable:
            return ("", nil)
        }
    }

    private static func closingHint(for opener: String) -> String {
        switch opener {
        case "(": return String(localized: "Add the closing ).")
        case "[": return String(localized: "Add the closing ].")
        case "{": return String(localized: "Add the closing }.")
        case "\"": return String(localized: "Add the closing quote.")
        case "if": return String(localized: "Finish the if with then, else and end.")
        case "try": return String(localized: "Finish the try with an expression after it.")
        default: return String(localized: "Finish the \(opener) expression.")
        }
    }

    // MARK: Run-time errors

    /// A run-time error in the R8.2 form: the failing operation, the value
    /// involved, and a hint when one applies (R8.11).
    static func runtime(_ error: JQRuntimeError, source: String) -> FilterError {
        let subjectText = error.subjectRange.map { $0.text(in: source).trimmingCharacters(in: .whitespacesAndNewlines) }
        let subject = subjectText.flatMap { $0.isEmpty || $0 == "." || $0.count > 60 ? nil : $0 }

        switch error.kind {
        case .custom:
            let text: String
            if case .string(let message) = error.value {
                text = message
            } else {
                text = JSONWriter.string(error.value)
            }
            return .runtime(detail: trimmedSentence(text), subject: nil,
                            hint: String(localized: "The filter called error(). Check the input it received, or catch the error with try."),
                            range: error.range)

        case .iterate(let type):
            let detail = String(localized: "cannot iterate over \(FilterError.describeType(type))")
            let base = subject ?? "."
            let optional = base == "." ? ".[]?" : "\(base)[]?"
            let hint: String
            if type == "null" {
                hint = String(localized: "Use `\(optional)` to skip a missing list.")
            } else {
                hint = String(localized: "Iterate over a list or an object, or use `\(optional)` to skip other values.")
            }
            return .runtime(detail: detail, subject: subjectSentence(subject, type: type), hint: hint, range: error.range)

        case .index(let target, let keyType):
            let key = quotedKey(in: error.message)
            let keyText = key.map { "\"\($0)\"" } ?? FilterError.describeType(keyType)
            let detail = String(localized: "cannot index \(FilterError.describeType(target)) with \(keyText)")
            let hint: String
            if target == "array", let key {
                let field = JQPathBuilder.expression([.key(key)])
                if let subject {
                    hint = String(localized: "Go through its items first, for example `\(subject)[]\(field)`.")
                } else {
                    hint = String(localized: "The value is a list. Go through its items first, for example `.[]\(field)`.")
                }
            } else if target == "object", keyType == "number" {
                hint = subject == nil
                    ? String(localized: "The value is an object, not a list. Use a key such as `.name` instead of an index.")
                    : String(localized: "Use a key such as `.name` instead of an index.")
            } else {
                hint = subject == nil
                    ? String(localized: "The value has no keys or items. Check the path before this step.")
                    : String(localized: "It has no keys or items. Check the path before this step.")
            }
            return .runtime(detail: detail, subject: subjectSentence(subject, type: target), hint: hint, range: error.range)

        case .arithmetic(let operation, let lhs, let rhs):
            let hint: String
            if operation == .add, Set([lhs, rhs]) == ["string", "number"] {
                hint = String(localized: "Convert one side first, for example with tostring or tonumber.")
            } else {
                hint = String(localized: "Check the types of both sides, for example with type.")
            }
            return .runtime(detail: lowercasedFirst(trimmedSentence(error.message)), subject: nil, hint: hint, range: error.range)

        case .invalidPath:
            return .runtime(detail: lowercasedFirst(trimmedSentence(error.message)), subject: nil,
                            hint: String(localized: "Use a path such as .a.b[0] on the left of =, |= or in del()."),
                            range: error.range)

        default:
            let message = error.message
            var hint: String?
            if message.contains("as JSON") || message.contains("cannot be parsed as a number") {
                hint = String(localized: "Use try tonumber to skip values that are not numbers.")
            } else if message.contains("csv") || message.contains("tsv") {
                hint = String(localized: "@csv and @tsv take a list of strings, numbers, booleans or nulls. Turn objects into text with tojson first.")
            }
            return .runtime(detail: lowercasedFirst(trimmedSentence(message)), subject: nil, hint: hint, range: error.range)
        }
    }

    /// "`.items` was null."
    private static func subjectSentence(_ subject: String?, type: String) -> String? {
        guard let subject else { return nil }
        return String(localized: "`\(subject)` was \(FilterError.describeType(type)).")
    }

    /// The key in a message like `Cannot index array with string "name"`.
    private static func quotedKey(in message: String) -> String? {
        guard let start = message.range(of: "with string \""), message.hasSuffix("\"") else { return nil }
        let key = message[start.upperBound..<message.index(before: message.endIndex)]
        return String(key)
    }

    private static func trimmedSentence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed.isEmpty ? String(localized: "error") : trimmed
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        // Keep words like "JSON" intact.
        if text.count > 1, text.dropFirst().first?.isUppercase == true { return text }
        return first.lowercased() + text.dropFirst()
    }

    // MARK: Other failures

    static func stop(_ reason: JQStopReason, timeout: (seconds: Double, capped: Bool), nextStep: FilterError.TimeoutNextStep,
                     canRunInApp: Bool) -> FilterError {
        switch reason {
        case .timeout:
            return .timeout(seconds: Int(timeout.seconds.rounded()), nextStep: timeout.capped ? .runInApp : nextStep)
        case .memoryLimit:
            return .memoryLimit(canRunInApp: canRunInApp)
        case .cancelled:
            return .cancelled
        case .recursionLimit:
            return .recursionLimit
        }
    }

    /// A run-time error from Get or Set Value at Path, worded for a path.
    static func pathRuntime(_ error: JQRuntimeError, source: String) -> FilterError {
        let mapped = runtime(error, source: source)
        guard case .runtime(let detail, let subject, let hint, _) = mapped else { return mapped }
        return .pathFailed(detail: detail, subject: subject, hint: hint)
    }

    /// R8.3: the position and a plain description of a JSON syntax error.
    static func input(_ error: JSONParseError) -> FilterError {
        if error.kind == .empty {
            return .emptyInput
        }
        let detail: String
        switch error.kind {
        case .unfinished:
            detail = String(localized: "unexpected end of input")
        case .unfinishedString:
            detail = String(localized: "unexpected end of string")
        case .invalidLiteral(let text):
            detail = String(localized: "\"\(text)\" is not a JSON value")
        case .invalidNumber(let text):
            detail = String(localized: "\"\(text)\" is not a valid number")
        case .invalidEscape, .invalidUnicodeEscape, .invalidSurrogate:
            detail = String(localized: "a string has an invalid escape")
        case .controlCharacter:
            detail = String(localized: "a string contains a control character")
        case .expectedSeparator:
            detail = String(localized: "a comma or colon is missing")
        case .expectedValue:
            detail = String(localized: "a value is missing")
        case .unmatched(let character):
            detail = String(localized: "unmatched \"\(String(character))\"")
        case .keysMustBeStrings:
            detail = String(localized: "object keys must be text in double quotes")
        case .keyValuePairs:
            detail = String(localized: "objects must hold key: value pairs")
        case .tooDeep:
            detail = String(localized: "the JSON is nested more than 256 levels deep")
        case .extraValues, .empty:
            detail = String(localized: "unexpected extra values")
        }
        return .invalidInput(line: max(error.line, 1), column: max(error.characterColumn, 1), detail: detail)
    }

    /// `halt_error`'s message as the error text (R4.10), or nil for `halt`.
    static func halt(_ halt: JQHalt) -> FilterError? {
        guard let message = halt.message else { return nil }
        if case .string(let text) = message {
            return .halted(message: text.trimmingCharacters(in: .newlines))
        }
        return .halted(message: JSONWriter.string(message))
    }
}
