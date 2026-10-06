import Foundation

/// A compiled jq filter. Compile once and run it on any number of inputs;
/// a filter is immutable and safe to share between threads.
public final class JQFilter: @unchecked Sendable {
    public let source: String
    /// The names `$name` refers to, in the order `run` expects their values.
    public let argumentNames: [String]
    let root: Node

    /// Compiles `source`. `argumentNames` are the variables the caller will
    /// pass, without `$`; `$ARGS` is always available.
    public init(_ source: String, argumentNames: [String] = []) throws {
        self.source = source
        self.argumentNames = argumentNames
        if source.allSatisfy({ $0.isWhitespace }) {
            throw JQCompileError(kind: .emptyFilter, range: SourceRange(0, 0), message: "Enter a filter")
        }
        var globals: [String: Int] = [:]
        for (i, name) in argumentNames.enumerated() { globals[name] = i }
        if globals["ARGS"] == nil { globals["ARGS"] = argumentNames.count }
        let compiler = Compiler(isPrelude: false, globalVariables: globals)
        do {
            var parser = try Parser(source)
            let ast = try parser.parseProgram()
            root = try compiler.compile(ast, scope: nil)
        } catch let error as SyntaxError {
            throw JQCompileError(kind: error.kind, range: error.range, message: JQFilter.describe(error.kind))
        }
    }

    /// Runs the filter on one input, calling `onResult` for every output.
    ///
    /// - Throws: `JQRuntimeError` for an uncaught error, `JQHalt` for
    ///   `halt`/`halt_error`, `JQStopReason` when a limit stops the run, or
    ///   any error `onResult` throws.
    public func run(_ input: JSON,
                    arguments: [String: JSON] = [:],
                    limits: JQLimits = JQLimits(),
                    cancellation: JQCancellation? = nil,
                    onMessage: ((JQMessage) -> Void)? = nil,
                    onResult: (JSON) throws -> Void) throws {
        let ctx = makeContext(arguments: arguments, limits: limits, cancellation: cancellation, onMessage: onMessage)
        try ctx.checkLimits()
        try root.eval(input, nil, ctx) { value in
            try onResult(value)
        }
    }

    /// Runs the filter as a path expression, the way jq's `path(f)` does.
    /// `onPath` receives one array of keys and indexes for each location the
    /// filter selects. A filter that is not a path expression, such as `1`
    /// or `.a + 1`, throws jq's "Invalid path expression" error.
    public func runPaths(_ input: JSON,
                         arguments: [String: JSON] = [:],
                         limits: JQLimits = JQLimits(),
                         cancellation: JQCancellation? = nil,
                         onPath: ([JSON]) throws -> Void) throws {
        let ctx = makeContext(arguments: arguments, limits: limits, cancellation: cancellation, onMessage: nil)
        try ctx.checkLimits()
        try root.paths(PathValue(path: [], value: input), nil, ctx) { pathValue in
            guard let path = pathValue.path else {
                throw invalidPathResult(pathValue.value).located(root.range)
            }
            try onPath(path)
        }
    }

    private func makeContext(arguments: [String: JSON], limits: JQLimits, cancellation: JQCancellation?,
                             onMessage: ((JQMessage) -> Void)?) -> Context {
        var values: [JSON] = argumentNames.map { arguments[$0] ?? .null }
        var named = JSONObject()
        for name in argumentNames { named[name] = arguments[name] ?? .null }
        var argsObject = JSONObject()
        argsObject["positional"] = .array([])
        argsObject["named"] = .object(named)
        if !argumentNames.contains("ARGS") { values.append(.object(argsObject)) }
        return Context(limits: limits, cancellation: cancellation, onMessage: onMessage, globals: values)
    }

    /// Every output for one input.
    public func results(for input: JSON, arguments: [String: JSON] = [:], limits: JQLimits = JQLimits()) throws -> [JSON] {
        var out: [JSON] = []
        try run(input, arguments: arguments, limits: limits) { out.append($0) }
        return out
    }

    static func describe(_ kind: JQCompileError.Kind) -> String {
        switch kind {
        case .emptyFilter: return "Enter a filter"
        case .unexpectedToken(let t): return "syntax error, unexpected \(t)"
        case .missingValueBefore(let t): return "syntax error, unexpected \(t)"
        case .unexpectedEnd: return "syntax error, unexpected end of file"
        case .unclosed(let open, _): return "syntax error, unclosed \(open)"
        case .unterminatedString: return "syntax error, unterminated string"
        case .invalidEscape(let e): return "invalid escape \(e)"
        case .invalidNumber(let n): return "invalid numeric literal \(n)"
        case .invalidCharacter(let c): return "syntax error, unexpected INVALID_CHARACTER \(c)"
        case .curlyQuote(let c): return "syntax error, unexpected INVALID_CHARACTER \(c)"
        case .objectValueNeedsParentheses: return "syntax error, object values need parentheses"
        case .objectKeyNeedsParentheses: return "May need parentheses around object key expression"
        case .invalidObjectKey(let d): return "Cannot use \(d) as object key"
        case .topLevelProgramNotGiven: return "Top-level program not given (try \".\")"
        case .undefinedFunction(let name, let arity, _): return "\(name)/\(arity) is not defined"
        case .undefinedVariable(let name): return "$\(name) is not defined"
        case .disabledFeature(let name): return "\(name) is not available"
        case .undefinedLabel(let name): return "$*label-\(name) is not defined"
        }
    }
}

/// Convenience entry points.
public enum JQ {
    /// The jq version whose behavior the engine follows.
    public static let compatibleVersion = "1.7.1"

    /// Runs `filter` on every input and returns all results.
    public static func run(_ filter: String, on inputs: [JSON], arguments: [String: JSON] = [:],
                           limits: JQLimits = JQLimits()) throws -> [JSON] {
        let compiled = try JQFilter(filter, argumentNames: Array(arguments.keys).sorted())
        var out: [JSON] = []
        for input in inputs {
            try compiled.run(input, arguments: arguments, limits: limits) { out.append($0) }
        }
        return out
    }

    /// Every builtin as "name/arity".
    public static var builtinNames: [String] { Compiler.builtinNames }
}
