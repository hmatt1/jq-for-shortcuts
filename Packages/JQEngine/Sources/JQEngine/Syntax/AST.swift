import Foundation

/// The parsed filter, before name resolution.
struct AST {
    indirect enum Kind {
        case identity
        case recurseDefault
        case index(target: AST, key: AST, optional: Bool)
        case slice(target: AST, from: AST?, to: AST?, optional: Bool)
        case iterate(target: AST, optional: Bool)
        case literal(JSON)
        case string(parts: [StringPiece], format: String)
        case format(String)
        case array(AST?)
        case object([ObjectEntry])
        case negate(AST)
        case pipe(AST, AST)
        case comma(AST, AST)
        case binary(BinaryOperator, AST, AST)
        case and(AST, AST)
        case or(AST, AST)
        case alternative(AST, AST)
        case assign(AssignOperator, AST, AST)
        case ifThen(cond: AST, then: AST, else: AST?)
        case tryCatch(body: AST, handler: AST?)
        case reduce(source: AST, patterns: [Pattern], initial: AST, update: AST)
        case foreach(source: AST, patterns: [Pattern], initial: AST, update: AST, extract: AST?)
        case bind(source: AST, patterns: [Pattern], body: AST)
        case label(name: String, body: AST)
        case breakLabel(name: String)
        case variable(name: String)
        case funcDef(FunctionDefinition, body: AST)
        case call(name: String, args: [AST])
    }

    let kind: Kind
    let range: SourceRange

    init(_ kind: Kind, _ range: SourceRange) {
        self.kind = kind
        self.range = range
    }
}

enum StringPiece {
    case text(String)
    case interpolation(AST)
}

struct ObjectEntry {
    enum Key {
        /// `ident:`, `"text":`, keyword keys and the shorthand forms.
        case literal(String)
        /// `"\(...)": v`, `@fmt "...": v`, `(expr): v`, `$var: v`.
        case expression(AST)
    }

    let key: Key
    let value: AST
    let range: SourceRange
}

indirect enum Pattern {
    case variable(name: String, range: SourceRange)
    case array([Pattern], range: SourceRange)
    case object([ObjectPatternEntry], range: SourceRange)

    var range: SourceRange {
        switch self {
        case .variable(_, let r), .array(_, let r), .object(_, let r): return r
        }
    }

    /// Variable names in the order they are bound.
    var variableNames: [String] {
        switch self {
        case .variable(let name, _):
            return [name]
        case .array(let items, _):
            return items.flatMap(\.variableNames)
        case .object(let entries, _):
            return entries.flatMap { entry -> [String] in
                var names: [String] = []
                if let bound = entry.bindsVariable { names.append(bound) }
                if let pattern = entry.pattern { names.append(contentsOf: pattern.variableNames) }
                return names
            }
        }
    }
}

struct ObjectPatternEntry {
    enum Key {
        case literal(String)
        case expression(AST)
    }

    let key: Key
    /// `$name` and `$name: pattern` bind the whole value to `$name` too.
    let bindsVariable: String?
    let pattern: Pattern?
    let range: SourceRange
}

final class FunctionDefinition {
    enum Parameter {
        /// `f`: a filter argument, evaluated lazily in the caller's scope.
        case closure(String)
        /// `$f`: sugar for `f as $f`, so both `f` and `$f` are visible.
        case value(String)

        var name: String {
            switch self {
            case .closure(let n), .value(let n): return n
            }
        }
    }

    let name: String
    let parameters: [Parameter]
    let body: AST
    let range: SourceRange

    init(name: String, parameters: [Parameter], body: AST, range: SourceRange) {
        self.name = name
        self.parameters = parameters
        self.body = body
        self.range = range
    }

    var arity: Int { parameters.count }
}

public enum BinaryOperator: String, Sendable {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case modulo = "%"
    case equal = "=="
    case notEqual = "!="
    case less = "<"
    case lessOrEqual = "<="
    case greater = ">"
    case greaterOrEqual = ">="
}

public enum AssignOperator: String, Sendable {
    case assign = "="
    case update = "|="
    case add = "+="
    case subtract = "-="
    case multiply = "*="
    case divide = "/="
    case modulo = "%="
    case alternative = "//="

    var arithmetic: BinaryOperator? {
        switch self {
        case .add: return .add
        case .subtract: return .subtract
        case .multiply: return .multiply
        case .divide: return .divide
        case .modulo: return .modulo
        default: return nil
        }
    }
}
