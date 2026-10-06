import Foundation

/// Turns the parsed filter into executable nodes, resolving every name
/// lexically the way jq does: local definitions and bindings first, then
/// top-level definitions, then builtins.
final class Compiler {
    /// A compile-time scope frame. The chain mirrors the runtime `Env` frames
    /// exactly, so a name's depth here is its depth at run time.
    final class Scope {
        enum Entry {
            case variable(String)
            case function(CompiledFunction)
            case closure(String)
            case label(String)
        }

        let entry: Entry
        let parent: Scope?

        init(_ entry: Entry, parent: Scope?) {
            self.entry = entry
            self.parent = parent
        }
    }

    private let isPrelude: Bool
    /// Top-level definitions visible at the current point, innermost last.
    private var globals: [CompiledFunction] = []
    private let globalVariables: [String: Int]

    init(isPrelude: Bool, globalVariables: [String: Int]) {
        self.isPrelude = isPrelude
        self.globalVariables = globalVariables
    }

    // MARK: Builtin tables

    /// jq-defined builtins, compiled once and shared by every program.
    static let prelude: [String: CompiledFunction] = {
        let compiler = Compiler(isPrelude: true, globalVariables: [:])
        do {
            var parser = try Parser(Prelude.source)
            let ast = try parser.parseProgram()
            _ = try compiler.compile(ast, scope: nil)
        } catch {
            fatalError("jq prelude failed to compile: \(error)")
        }
        var table: [String: CompiledFunction] = [:]
        for fn in compiler.allGlobals { table["\(fn.name)/\(fn.arity)"] = fn }
        return table
    }()

    /// Every builtin as "name/arity", for the `builtins` filter.
    static let builtinNames: [String] = {
        var names = Set(prelude.keys).union(Builtins.table.keys)
        names.subtract(Builtins.disabled)
        return names.filter { !$0.hasPrefix("_") }.sorted()
    }()

    /// Definitions registered while compiling, kept after their scope closes
    /// so the prelude table can be built.
    private var allGlobals: [CompiledFunction] = []

    /// How many function bodies enclose the definition being compiled.
    private var bodyDepth = 0

    // MARK: Ranges

    private func range(_ r: SourceRange) -> SourceRange {
        isPrelude ? .builtin : r
    }

    // MARK: Expressions

    func compile(_ ast: AST, scope: Scope?) throws -> Node {
        let r = range(ast.range)
        switch ast.kind {
        case .identity:
            return IdentityNode(range: r)
        case .recurseDefault:
            return RecurseAllNode(range: r)
        case .index(let target, let key, let optional):
            return IndexNode(target: try compile(target, scope: scope), key: try compile(key, scope: scope),
                             optional: optional, range: r)
        case .slice(let target, let from, let to, let optional):
            return SliceNode(target: try compile(target, scope: scope),
                             from: try from.map { try compile($0, scope: scope) },
                             to: try to.map { try compile($0, scope: scope) },
                             optional: optional, range: r)
        case .iterate(let target, let optional):
            return IterateNode(target: try compile(target, scope: scope), optional: optional, range: r)
        case .literal(let value):
            return LiteralNode(value, range: r)
        case .string(let pieces, let format):
            var parts: [StringNode.Part] = []
            var hasInterpolation = false
            for piece in pieces {
                switch piece {
                case .text(let text):
                    parts.append(.text(text))
                case .interpolation(let expr):
                    hasInterpolation = true
                    parts.append(.interpolation(try compile(expr, scope: scope)))
                }
            }
            if !hasInterpolation {
                let text = parts.map { if case .text(let t) = $0 { return t } else { return "" } }.joined()
                return LiteralNode(.string(text), range: r)
            }
            return StringNode(parts: parts, format: format, range: r)
        case .format(let name):
            return FormatNode(name: name, range: r)
        case .array(let body):
            return ArrayNode(try body.map { try compile($0, scope: scope) }, range: r)
        case .object(let entries):
            var compiled: [(key: ObjectNode.Key, value: Node, range: SourceRange)] = []
            for entry in entries {
                let key: ObjectNode.Key
                switch entry.key {
                case .literal(let name): key = .literal(name)
                case .expression(let expr): key = .expression(try compile(expr, scope: scope))
                }
                compiled.append((key, try compile(entry.value, scope: scope), range(entry.range)))
            }
            return ObjectNode(entries: compiled, range: r)
        case .negate(let operand):
            return NegateNode(try compile(operand, scope: scope), range: r)
        case .pipe(let a, let b):
            return PipeNode(try compile(a, scope: scope), try compile(b, scope: scope), range: r)
        case .comma(let a, let b):
            return CommaNode(try compile(a, scope: scope), try compile(b, scope: scope), range: r)
        case .binary(let op, let a, let b):
            return BinaryNode(op, try compile(a, scope: scope), try compile(b, scope: scope), range: r)
        case .and(let a, let b):
            return AndNode(try compile(a, scope: scope), try compile(b, scope: scope), range: r)
        case .or(let a, let b):
            return OrNode(try compile(a, scope: scope), try compile(b, scope: scope), range: r)
        case .alternative(let a, let b):
            return AlternativeNode(try compile(a, scope: scope), try compile(b, scope: scope), range: r)
        case .assign(let op, let lhs, let rhs):
            return AssignNode(op: op, lhs: try compile(lhs, scope: scope), rhs: try compile(rhs, scope: scope), range: r)
        case .ifThen(let cond, let then, let otherwise):
            return IfNode(cond: try compile(cond, scope: scope), then: try compile(then, scope: scope),
                          otherwise: try otherwise.map { try compile($0, scope: scope) } ?? IdentityNode(range: r),
                          range: r)
        case .tryCatch(let body, let handler):
            return TryNode(body: try compile(body, scope: scope), handler: try handler.map { try compile($0, scope: scope) },
                           range: r)
        case .reduce(let source, let patterns, let initial, let update):
            let (set, inner) = try compilePatterns(patterns, scope: scope)
            return ReduceNode(source: try compile(source, scope: scope), patterns: set,
                              initial: try compile(initial, scope: scope), update: try compile(update, scope: inner),
                              range: r)
        case .foreach(let source, let patterns, let initial, let update, let extract):
            let (set, inner) = try compilePatterns(patterns, scope: scope)
            return ForeachNode(source: try compile(source, scope: scope), patterns: set,
                               initial: try compile(initial, scope: scope), update: try compile(update, scope: inner),
                               extract: try extract.map { try compile($0, scope: inner) }, range: r)
        case .bind(let source, let patterns, let body):
            let (set, inner) = try compilePatterns(patterns, scope: scope)
            return BindNode(source: try compile(source, scope: scope), patterns: set,
                            body: try compile(body, scope: inner), range: r)
        case .label(let name, let body):
            return LabelNode(body: try compile(body, scope: Scope(.label(name), parent: scope)), range: r)
        case .breakLabel(let name):
            var depth = 0
            var s = scope
            while let frame = s {
                if case .label(let n) = frame.entry, n == name {
                    return BreakNode(depth: depth, range: r)
                }
                depth += 1
                s = frame.parent
            }
            throw JQCompileError(kind: .undefinedLabel(name), range: ast.range, message: "$*label-\(name) is not defined")
        case .variable(let name):
            return try resolveVariable(name, scope: scope, range: ast.range)
        case .funcDef(let definition, let body):
            return try compileDefinition(definition, body: body, scope: scope, range: r)
        case .call(let name, let args):
            return try resolveCall(name, args, scope: scope, range: ast.range)
        }
    }

    // MARK: Definitions

    private func compileDefinition(_ definition: FunctionDefinition, body: AST, scope: Scope?, range r: SourceRange) throws -> Node {
        let function = CompiledFunction(name: definition.name, parameters: definition.parameters,
                                        range: range(definition.range))
        if scope == nil {
            // No local frames to capture, so calls go straight to it.
            globals.append(function)
            if bodyDepth == 0 {
                // Only true top-level definitions become builtins; a helper
                // defined inside another function's body stays private to it.
                allGlobals.append(function)
            }
            function.body = try insideBody {
                try compile(definition.body, scope: parameterScope(definition, base: nil))
            }
            let rest = try compile(body, scope: nil)
            globals.removeLast()
            return rest
        }
        let own = Scope(.function(function), parent: scope)
        function.body = try compile(definition.body, scope: parameterScope(definition, base: own))
        let rest = try compile(body, scope: own)
        return FunctionDefinitionNode(function: function, body: rest, range: r)
    }

    private func insideBody<T>(_ work: () throws -> T) rethrows -> T {
        bodyDepth += 1
        defer { bodyDepth -= 1 }
        return try work()
    }

    /// Closure frames for every parameter, then value frames for `$`
    /// parameters, as `CallFunctionNode` pushes them.
    private func parameterScope(_ definition: FunctionDefinition, base: Scope?) -> Scope? {
        var scope = base
        for p in definition.parameters {
            scope = Scope(.closure(p.name), parent: scope)
        }
        for p in definition.parameters {
            if case .value(let name) = p {
                scope = Scope(.variable(name), parent: scope)
            }
        }
        return scope
    }

    // MARK: Name resolution

    private func resolveVariable(_ name: String, scope: Scope?, range r: SourceRange) throws -> Node {
        var depth = 0
        var s = scope
        while let frame = s {
            if case .variable(let n) = frame.entry, n == name {
                return VariableNode(depth: depth, name: name, range: range(r))
            }
            depth += 1
            s = frame.parent
        }
        if let index = globalVariables[name] {
            return GlobalVariableNode(index: index, range: range(r))
        }
        if name == "ENV" {
            throw JQCompileError(kind: .disabledFeature("$ENV"), range: r, message: "$ENV is not available")
        }
        if name == "__prog_args" {
            return LiteralNode(.array([]), range: range(r))
        }
        throw JQCompileError(kind: .undefinedVariable(name), range: r, message: "$\(name) is not defined")
    }

    private func resolveCall(_ name: String, _ args: [AST], scope: Scope?, range r: SourceRange) throws -> Node {
        let arity = args.count
        var depth = 0
        var s = scope
        while let frame = s {
            switch frame.entry {
            case .function(let fn) where fn.name == name && fn.arity == arity:
                return CallFunctionNode(function: fn, depth: depth,
                                        args: try args.map { try compile($0, scope: scope) }, range: range(r))
            case .closure(let n) where n == name && arity == 0:
                return CallClosureNode(depth: depth, range: range(r))
            default:
                break
            }
            depth += 1
            s = frame.parent
        }
        if let fn = globals.last(where: { $0.name == name && $0.arity == arity }) {
            return CallFunctionNode(function: fn, depth: nil, args: try args.map { try compile($0, scope: scope) },
                                    range: range(r))
        }
        let key = "\(name)/\(arity)"
        if Builtins.disabled.contains(key) {
            throw JQCompileError(kind: .disabledFeature(name), range: r, message: "\(key) is not available")
        }
        if !isPrelude, let fn = Compiler.prelude[key] {
            return CallFunctionNode(function: fn, depth: nil, args: try args.map { try compile($0, scope: scope) },
                                    range: range(r))
        }
        if let native = Builtins.table[key] {
            return CallNativeNode(builtin: native, args: try args.map { try compile($0, scope: scope) }, range: range(r))
        }
        throw JQCompileError(kind: .undefinedFunction(name: name, arity: arity, suggestion: suggestion(for: name, arity: arity, scope: scope)),
                             range: r, message: "\(key) is not defined")
    }

    /// The closest known function name, for "did you mean" hints.
    private func suggestion(for name: String, arity: Int, scope: Scope?) -> String? {
        var candidates = Set(Compiler.builtinNames)
        for fn in globals { candidates.insert("\(fn.name)/\(fn.arity)") }
        var s = scope
        while let frame = s {
            if case .function(let fn) = frame.entry { candidates.insert("\(fn.name)/\(fn.arity)") }
            s = frame.parent
        }
        var best: (String, Int)?
        for candidate in candidates {
            let parts = candidate.split(separator: "/")
            guard let candidateName = parts.first.map(String.init), let a = parts.last.flatMap({ Int($0) }) else { continue }
            if candidateName == name && a != arity {
                return candidate
            }
            let d = Compiler.editDistance(name, candidateName)
            let score = d * 2 + (a == arity ? 0 : 1)
            if d <= max(1, name.count / 3), best == nil || score < best!.1 {
                best = (candidateName, score)
            }
        }
        return best?.0
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a)
        let y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count]
    }

    // MARK: Patterns

    private func compilePatterns(_ patterns: [Pattern], scope: Scope?) throws -> (PatternSet, Scope?) {
        if patterns.count == 1 {
            let (compiled, inner) = try compilePattern(patterns[0], scope: scope)
            return (PatternSet(alternatives: [compiled], layouts: [], unionCount: 0), inner)
        }
        var union: [String] = []
        for p in patterns {
            for name in p.variableNames where !union.contains(name) { union.append(name) }
        }
        var alternatives: [CompiledPattern] = []
        var layouts: [[Int]] = []
        for p in patterns {
            let (compiled, _) = try compilePattern(p, scope: scope)
            alternatives.append(compiled)
            layouts.append(p.variableNames.map { union.firstIndex(of: $0)! })
        }
        var inner = scope
        for name in union { inner = Scope(.variable(name), parent: inner) }
        return (PatternSet(alternatives: alternatives, layouts: layouts, unionCount: union.count), inner)
    }

    /// Compiles one pattern; returns it and the scope after its variables.
    private func compilePattern(_ pattern: Pattern, scope: Scope?) throws -> (CompiledPattern, Scope?) {
        switch pattern {
        case .variable(let name, _):
            return (.variable, Scope(.variable(name), parent: scope))
        case .array(let items, _):
            var current = scope
            var compiled: [CompiledPattern] = []
            for item in items {
                let (c, next) = try compilePattern(item, scope: current)
                compiled.append(c)
                current = next
            }
            return (.array(compiled), current)
        case .object(let entries, _):
            var current = scope
            var compiled: [(key: CompiledPatternKey, bindsVariable: Bool, pattern: CompiledPattern?)] = []
            for entry in entries {
                let key: CompiledPatternKey
                switch entry.key {
                case .literal(let name): key = .literal(name)
                case .expression(let expr): key = .expression(try compile(expr, scope: current))
                }
                if let bound = entry.bindsVariable {
                    current = Scope(.variable(bound), parent: current)
                }
                var sub: CompiledPattern?
                if let p = entry.pattern {
                    let (c, next) = try compilePattern(p, scope: current)
                    sub = c
                    current = next
                }
                compiled.append((key, entry.bindsVariable != nil, sub))
            }
            return (.object(compiled), current)
        }
    }
}

extension SourceRange {
    /// Marks nodes compiled from the builtin prelude; errors raised there are
    /// reported at the caller's position instead.
    static let builtin = SourceRange(-1, -1)

    public var isValid: Bool { start >= 0 }
}
