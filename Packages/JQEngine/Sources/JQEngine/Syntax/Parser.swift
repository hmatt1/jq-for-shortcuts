import Foundation

/// A recursive-descent parser for jq 1.7.1's grammar (src/parser.y). Binary
/// operators use precedence climbing with jq's exact precedence and
/// associativity table.
struct Parser {
    private var lexer: Lexer
    private var current: Token
    private var lookahead: Token?
    private let source: String

    private enum Associativity { case left, right, none }

    private enum Precedence {
        static let pipe = 1
        static let comma = 2
        static let alternative = 3
        static let assignment = 4
        static let or = 5
        static let and = 6
        static let comparison = 7
        static let additive = 8
        static let multiplicative = 9
        static let postfixTry = 11
        static let `try` = 12
        static let `catch` = 13
    }

    init(_ source: String) throws {
        self.source = source
        lexer = Lexer(source)
        current = Token(kind: .eof, range: .none)
        current = try lexer.next()
    }

    // MARK: Program

    /// Parses a complete filter.
    mutating func parseProgram() throws -> AST {
        if case .eof = current.kind {
            throw SyntaxError(kind: .emptyFilter, range: SourceRange(0, 0))
        }
        if case .keyword(.module) = current.kind {
            let start = current.range
            try advance()
            let metadata = try parseExp(Precedence.pipe)
            guard Parser.isConstantObject(metadata) else {
                throw SyntaxError(kind: .unexpectedToken("module metadata (it must be a constant object)"),
                                  range: start.union(metadata.range))
            }
            try expectOp(";", context: nil)
        }
        if case .keyword(let k) = current.kind, k == .import || k == .include {
            throw SyntaxError(kind: .disabledFeature(k.rawValue), range: current.range)
        }
        let body = try parseExp(Precedence.pipe)
        guard case .eof = current.kind else {
            throw unexpected(current, expectingValue: false)
        }
        return body
    }

    /// `module` metadata must be an object built only from constants.
    private static func isConstantObject(_ ast: AST) -> Bool {
        guard case .object(let entries) = ast.kind else { return false }
        return entries.allSatisfy { entry in
            guard case .literal = entry.key else { return false }
            return isConstant(entry.value)
        }
    }

    private static func isConstant(_ ast: AST) -> Bool {
        switch ast.kind {
        case .literal: return true
        case .string(let parts, _): return parts.allSatisfy { if case .text = $0 { return true } else { return false } }
        case .array(let inner): return inner.map(isConstant) ?? true
        case .comma(let a, let b): return isConstant(a) && isConstant(b)
        case .object: return isConstantObject(ast)
        default: return false
        }
    }

    // MARK: Tokens

    private mutating func advance() throws {
        if let next = lookahead {
            current = next
            lookahead = nil
        } else {
            current = try lexer.next()
        }
    }

    private mutating func peek() throws -> Token {
        if let lookahead { return lookahead }
        let next = try lexer.next()
        lookahead = next
        return next
    }

    private func isOp(_ op: String) -> Bool {
        if case .op(let o) = current.kind { return o == op }
        return false
    }

    private func isKeyword(_ keyword: Keyword) -> Bool {
        if case .keyword(let k) = current.kind { return k == keyword }
        return false
    }

    /// Consumes `op` or throws. `context` is the opening token whose closing
    /// counterpart is expected, for "unclosed" errors.
    private mutating func expectOp(_ op: String, context: Token?) throws {
        guard isOp(op) else {
            throw expectationFailure(expected: op, context: context)
        }
        try advance()
    }

    private mutating func expectKeyword(_ keyword: Keyword, context: Token?) throws {
        guard isKeyword(keyword) else {
            throw expectationFailure(expected: keyword.rawValue, context: context)
        }
        try advance()
    }

    private func expectationFailure(expected: String, context: Token?) -> SyntaxError {
        if case .eof = current.kind, let context {
            return SyntaxError(kind: .unclosed(context.displayName, opening: context.range), range: current.range)
        }
        if let context, ["(", "[", "{"].contains(context.displayName), isClosingBracket(current) {
            return SyntaxError(kind: .unclosed(context.displayName, opening: context.range), range: current.range)
        }
        return unexpected(current, expectingValue: false)
    }

    private func isClosingBracket(_ token: Token) -> Bool {
        if case .op(let o) = token.kind { return o == ")" || o == "]" || o == "}" }
        return false
    }

    /// Builds the error for a token that cannot appear here.
    private func unexpected(_ token: Token, expectingValue: Bool) -> SyntaxError {
        switch token.kind {
        case .eof:
            return SyntaxError(kind: .unexpectedEnd, range: token.range)
        case .invalid(let c):
            let curly: Set<Character> = ["\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "\u{00AB}", "\u{00BB}"]
            if curly.contains(c) {
                return SyntaxError(kind: .curlyQuote(String(c)), range: token.range)
            }
            return SyntaxError(kind: .invalidCharacter(String(c)), range: token.range)
        default:
            break
        }
        if expectingValue {
            return SyntaxError(kind: .missingValueBefore(token.displayName), range: token.range)
        }
        return SyntaxError(kind: .unexpectedToken(token.displayName), range: token.range)
    }

    // MARK: Expressions

    private static func binaryInfo(_ token: Token) -> (Int, Associativity)? {
        switch token.kind {
        case .op(let o):
            switch o {
            case "|": return (Precedence.pipe, .right)
            case ",": return (Precedence.comma, .left)
            case "//": return (Precedence.alternative, .right)
            case "=", "|=", "+=", "-=", "*=", "/=", "%=", "//=": return (Precedence.assignment, .none)
            case "==", "!=", "<", "<=", ">", ">=": return (Precedence.comparison, .none)
            case "+", "-": return (Precedence.additive, .left)
            case "*", "/", "%": return (Precedence.multiplicative, .left)
            default: return nil
            }
        case .keyword(.or): return (Precedence.or, .left)
        case .keyword(.and): return (Precedence.and, .left)
        default: return nil
        }
    }

    private mutating func parseExp(_ minPrecedence: Int) throws -> AST {
        var lhs = try parseUnary()
        while true {
            if isOp("?") && Precedence.postfixTry >= minPrecedence {
                let range = lhs.range.union(current.range)
                try advance()
                lhs = AST(.tryCatch(body: lhs, handler: nil), range)
                continue
            }
            guard let (precedence, associativity) = Parser.binaryInfo(current), precedence >= minPrecedence else {
                break
            }
            let opToken = current
            try advance()
            let rhs = try parseExp(associativity == .right ? precedence : precedence + 1)
            lhs = try combine(opToken, lhs, rhs)
            if associativity == .none, let (next, _) = Parser.binaryInfo(current), next == precedence {
                throw unexpected(current, expectingValue: false)
            }
        }
        return lhs
    }

    private func combine(_ op: Token, _ lhs: AST, _ rhs: AST) throws -> AST {
        let range = lhs.range.union(rhs.range)
        switch op.kind {
        case .keyword(.or): return AST(.or(lhs, rhs), range)
        case .keyword(.and): return AST(.and(lhs, rhs), range)
        case .op(let o):
            switch o {
            case "|": return AST(.pipe(lhs, rhs), range)
            case ",": return AST(.comma(lhs, rhs), range)
            case "//": return AST(.alternative(lhs, rhs), range)
            default:
                if let assign = AssignOperator(rawValue: o) {
                    return AST(.assign(assign, lhs, rhs), range)
                }
                if let binary = BinaryOperator(rawValue: o) {
                    return AST(.binary(binary, lhs, rhs), range)
                }
            }
        default:
            break
        }
        throw unexpected(op, expectingValue: false)
    }

    /// Prefix forms that start an expression: def, reduce, foreach, if, try,
    /// label, unary minus, and a term with an optional `as` binding.
    private mutating func parseUnary() throws -> AST {
        let start = current
        switch current.kind {
        case .keyword(.def):
            let definition = try parseFunctionDefinition()
            if case .eof = current.kind {
                throw SyntaxError(kind: .topLevelProgramNotGiven, range: definition.range)
            }
            let body = try parseExp(Precedence.pipe)
            return AST(.funcDef(definition, body: body), start.range.union(body.range))
        case .keyword(.reduce):
            try advance()
            let source = try parseTerm()
            try expectKeyword(.as, context: nil)
            let patterns = try parsePatterns()
            let open = current
            try expectOp("(", context: nil)
            let initial = try parseExp(Precedence.pipe)
            try expectOp(";", context: open)
            let update = try parseExp(Precedence.pipe)
            let close = current
            try expectOp(")", context: open)
            return AST(.reduce(source: source, patterns: patterns, initial: initial, update: update),
                       start.range.union(close.range))
        case .keyword(.foreach):
            try advance()
            let source = try parseTerm()
            try expectKeyword(.as, context: nil)
            let patterns = try parsePatterns()
            let open = current
            try expectOp("(", context: nil)
            let initial = try parseExp(Precedence.pipe)
            try expectOp(";", context: open)
            let update = try parseExp(Precedence.pipe)
            var extract: AST?
            if isOp(";") {
                try advance()
                extract = try parseExp(Precedence.pipe)
            }
            let close = current
            try expectOp(")", context: open)
            return AST(.foreach(source: source, patterns: patterns, initial: initial, update: update, extract: extract),
                       start.range.union(close.range))
        case .keyword(.if):
            return try parseIf()
        case .keyword(.try):
            try advance()
            let body = try parseExp(Precedence.try)
            if isKeyword(.catch) {
                try advance()
                let handler = try parseExp(Precedence.catch)
                return AST(.tryCatch(body: body, handler: handler), start.range.union(handler.range))
            }
            return AST(.tryCatch(body: body, handler: nil), start.range.union(body.range))
        case .keyword(.label):
            try advance()
            guard case .binding(let name) = current.kind else {
                throw unexpected(current, expectingValue: true)
            }
            try advance()
            try expectOp("|", context: nil)
            let body = try parseExp(Precedence.pipe)
            return AST(.label(name: name, body: body), start.range.union(body.range))
        case .op("-"):
            try advance()
            let operand = try parseExp(Precedence.multiplicative)
            return AST(.negate(operand), start.range.union(operand.range))
        default:
            let term = try parseTerm()
            if isKeyword(.as) {
                try advance()
                let patterns = try parsePatterns()
                try expectOp("|", context: nil)
                let body = try parseExp(Precedence.pipe)
                return AST(.bind(source: term, patterns: patterns, body: body), term.range.union(body.range))
            }
            return term
        }
    }

    private mutating func parseIf() throws -> AST {
        let ifToken = current
        try advance()
        let cond = try parseExp(Precedence.pipe)
        try expectKeyword(.then, context: ifToken)
        let then = try parseExp(Precedence.pipe)
        if isKeyword(.elif) {
            let elifToken = current
            let rest = try parseElif(ifToken: ifToken)
            _ = elifToken
            return AST(.ifThen(cond: cond, then: then, else: rest), ifToken.range.union(rest.range))
        }
        if isKeyword(.else) {
            try advance()
            let otherwise = try parseExp(Precedence.pipe)
            let endToken = current
            try expectKeyword(.end, context: ifToken)
            return AST(.ifThen(cond: cond, then: then, else: otherwise), ifToken.range.union(endToken.range))
        }
        let endToken = current
        try expectKeyword(.end, context: ifToken)
        return AST(.ifThen(cond: cond, then: then, else: nil), ifToken.range.union(endToken.range))
    }

    /// `elif c then e ElseBody`, as a nested if.
    private mutating func parseElif(ifToken: Token) throws -> AST {
        let elifToken = current
        try advance()
        let cond = try parseExp(Precedence.pipe)
        try expectKeyword(.then, context: ifToken)
        let then = try parseExp(Precedence.pipe)
        if isKeyword(.elif) {
            let rest = try parseElif(ifToken: ifToken)
            return AST(.ifThen(cond: cond, then: then, else: rest), elifToken.range.union(rest.range))
        }
        if isKeyword(.else) {
            try advance()
            let otherwise = try parseExp(Precedence.pipe)
            let endToken = current
            try expectKeyword(.end, context: ifToken)
            return AST(.ifThen(cond: cond, then: then, else: otherwise), elifToken.range.union(endToken.range))
        }
        let endToken = current
        try expectKeyword(.end, context: ifToken)
        return AST(.ifThen(cond: cond, then: then, else: nil), elifToken.range.union(endToken.range))
    }

    private mutating func parseFunctionDefinition() throws -> FunctionDefinition {
        let defToken = current
        try advance()
        guard case .ident(let name) = current.kind else {
            throw unexpected(current, expectingValue: false)
        }
        try advance()
        var parameters: [FunctionDefinition.Parameter] = []
        if isOp("(") {
            let open = current
            try advance()
            while true {
                switch current.kind {
                case .binding(let p):
                    parameters.append(.value(p))
                case .ident(let p):
                    parameters.append(.closure(p))
                default:
                    throw unexpected(current, expectingValue: false)
                }
                try advance()
                if isOp(";") {
                    try advance()
                    continue
                }
                try expectOp(")", context: open)
                break
            }
        }
        try expectOp(":", context: nil)
        let body = try parseExp(Precedence.pipe)
        let semicolon = current
        try expectOp(";", context: defToken)
        return FunctionDefinition(name: name, parameters: parameters, body: body,
                                  range: defToken.range.union(semicolon.range))
    }

    // MARK: Terms

    private mutating func parseTerm() throws -> AST {
        var term = try parsePrimary()
        while true {
            switch current.kind {
            case .field(let name):
                let range = current.range
                try advance()
                let optional = try consumeQuestionMark()
                term = AST(.index(target: term, key: AST(.literal(.string(name)), range), optional: optional),
                           term.range.union(range))
            case .op("."):
                let next = try peek()
                if case .stringStart = next.kind {
                    try advance()
                    let key = try parseString(format: "text")
                    let optional = try consumeQuestionMark()
                    term = AST(.index(target: term, key: key, optional: optional), term.range.union(key.range))
                } else if case .op("[") = next.kind {
                    try advance()
                    term = try parseBracketSuffix(term)
                } else {
                    return term
                }
            case .op("["):
                term = try parseBracketSuffix(term)
            default:
                return term
            }
        }
    }

    private mutating func consumeQuestionMark() throws -> Bool {
        if isOp("?") {
            try advance()
            return true
        }
        return false
    }

    /// `[ ]`, `[e]`, `[e:e]`, `[e:]`, `[:e]` after a term, with an optional `?`.
    private mutating func parseBracketSuffix(_ target: AST) throws -> AST {
        let open = current
        try advance()
        if isOp("]") {
            let close = current
            try advance()
            let optional = try consumeQuestionMark()
            return AST(.iterate(target: target, optional: optional), target.range.union(close.range))
        }
        if isOp(":") {
            try advance()
            let to = try parseExp(Precedence.pipe)
            let close = current
            try expectOp("]", context: open)
            let optional = try consumeQuestionMark()
            return AST(.slice(target: target, from: nil, to: to, optional: optional), target.range.union(close.range))
        }
        let key = try parseExp(Precedence.pipe)
        if isOp(":") {
            try advance()
            var to: AST?
            if !isOp("]") {
                to = try parseExp(Precedence.pipe)
            }
            let close = current
            try expectOp("]", context: open)
            let optional = try consumeQuestionMark()
            return AST(.slice(target: target, from: key, to: to, optional: optional), target.range.union(close.range))
        }
        let close = current
        try expectOp("]", context: open)
        let optional = try consumeQuestionMark()
        return AST(.index(target: target, key: key, optional: optional), target.range.union(close.range))
    }

    private mutating func parsePrimary() throws -> AST {
        let token = current
        switch token.kind {
        case .op("."):
            let next = try peek()
            if case .stringStart = next.kind {
                try advance()
                let key = try parseString(format: "text")
                let optional = try consumeQuestionMark()
                return AST(.index(target: AST(.identity, token.range), key: key, optional: optional),
                           token.range.union(key.range))
            }
            try advance()
            return AST(.identity, token.range)
        case .op(".."):
            try advance()
            return AST(.recurseDefault, token.range)
        case .field(let name):
            try advance()
            let optional = try consumeQuestionMark()
            let identity = AST(.identity, SourceRange(token.range.start, token.range.start))
            return AST(.index(target: identity, key: AST(.literal(.string(name)), token.range), optional: optional),
                       token.range)
        case .number(let n):
            try advance()
            return AST(.literal(.number(n)), token.range)
        case .stringStart:
            return try parseString(format: "text")
        case .format(let name):
            let next = try peek()
            if case .stringStart = next.kind {
                try advance()
                return try parseString(format: name, formatRange: token.range)
            }
            try advance()
            return AST(.format(name), token.range)
        case .op("("):
            try advance()
            let inner = try parseExp(Precedence.pipe)
            let close = current
            try expectOp(")", context: token)
            return AST(inner.kind, token.range.union(close.range))
        case .op("["):
            try advance()
            if isOp("]") {
                let close = current
                try advance()
                return AST(.array(nil), token.range.union(close.range))
            }
            let inner = try parseExp(Precedence.pipe)
            let close = current
            try expectOp("]", context: token)
            return AST(.array(inner), token.range.union(close.range))
        case .op("{"):
            return try parseObject()
        case .op("$"):
            // `$$$$name`, used only inside jq's own builtins.
            try advance()
            while isOp("$") { try advance() }
            guard case .binding(let name) = current.kind else {
                throw unexpected(current, expectingValue: true)
            }
            let range = token.range.union(current.range)
            try advance()
            return AST(.variable(name: name), range)
        case .binding(let name):
            try advance()
            return AST(.variable(name: name), token.range)
        case .loc:
            try advance()
            return AST(.literal(locObject(at: token.range)), token.range)
        case .ident(let name):
            try advance()
            switch name {
            case "true": return AST(.literal(.true), token.range)
            case "false": return AST(.literal(.false), token.range)
            case "null": return AST(.literal(.null), token.range)
            default: break
            }
            if isOp("(") {
                let open = current
                try advance()
                var args: [AST] = []
                while true {
                    args.append(try parseExp(Precedence.pipe))
                    if isOp(";") {
                        try advance()
                        continue
                    }
                    let close = current
                    try expectOp(")", context: open)
                    return AST(.call(name: name, args: args), token.range.union(close.range))
                }
            }
            return AST(.call(name: name, args: []), token.range)
        case .keyword(.break):
            try advance()
            guard case .binding(let name) = current.kind else {
                throw unexpected(current, expectingValue: true)
            }
            let range = token.range.union(current.range)
            try advance()
            return AST(.breakLabel(name: name), range)
        case .keyword(.if), .keyword(.try), .keyword(.reduce), .keyword(.foreach), .keyword(.label), .keyword(.def):
            // These are expressions in jq 1.7.1, not terms; they need
            // parentheses where only a term is allowed.
            throw SyntaxError(kind: .objectValueNeedsParentheses, range: token.range)
        default:
            throw unexpected(token, expectingValue: true)
        }
    }

    private func locObject(at range: SourceRange) -> JSON {
        let prefix = source.utf8.prefix(range.start)
        let line = prefix.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        var object = JSONObject()
        object["file"] = .string("<top-level>")
        object["line"] = .number(line)
        return .object(object)
    }

    // MARK: Strings

    /// Parses a string literal whose opening quote is the current token.
    private mutating func parseString(format: String, formatRange: SourceRange? = nil) throws -> AST {
        let open = current
        guard case .stringStart = open.kind, lookahead == nil else {
            throw unexpected(current, expectingValue: true)
        }
        var pieces: [StringPiece] = []
        var endRange = open.range
        loop: while true {
            switch try lexer.nextStringPart(openQuote: open.range.start) {
            case .text(let text, _):
                pieces.append(.text(text))
            case .interpolationStart(let interpRange):
                current = try lexer.next()
                let expr = try parseExp(Precedence.pipe)
                guard isOp(")"), lookahead == nil else {
                    let context = Token(kind: .op("("), range: interpRange)
                    throw expectationFailure(expected: ")", context: context)
                }
                pieces.append(.interpolation(expr))
            case .end(let range):
                endRange = range
                break loop
            }
        }
        try advance()
        let start = formatRange?.start ?? open.range.start
        return AST(.string(parts: pieces, format: format), SourceRange(start, endRange.end))
    }

    // MARK: Objects

    private mutating func parseObject() throws -> AST {
        let open = current
        try advance()
        var entries: [ObjectEntry] = []
        while true {
            if isOp("}") {
                let close = current
                try advance()
                return AST(.object(entries), open.range.union(close.range))
            }
            entries.append(try parseObjectEntry())
            if isOp(",") {
                try advance()
                continue
            }
            if isOp("}") { continue }
            if case .eof = current.kind {
                throw SyntaxError(kind: .unclosed("{", opening: open.range), range: current.range)
            }
            if Parser.binaryInfo(current) != nil || isKeyword(.as) {
                throw SyntaxError(kind: .objectValueNeedsParentheses, range: current.range)
            }
            throw unexpected(current, expectingValue: false)
        }
    }

    private mutating func parseObjectEntry() throws -> ObjectEntry {
        let token = current
        switch token.kind {
        case .ident(let name):
            try advance()
            return try finishObjectEntry(key: .literal(name), shorthand: indexOfIdentity(name, token.range), start: token.range)
        case .keyword(let keyword):
            try advance()
            return try finishObjectEntry(key: .literal(keyword.rawValue),
                                         shorthand: indexOfIdentity(keyword.rawValue, token.range), start: token.range)
        case .binding(let name):
            try advance()
            if isOp(":") {
                try advance()
                let value = try parseObjectValue()
                return ObjectEntry(key: .expression(AST(.variable(name: name), token.range)), value: value,
                                   range: token.range.union(value.range))
            }
            return ObjectEntry(key: .literal(name), value: AST(.variable(name: name), token.range), range: token.range)
        case .loc:
            try advance()
            return ObjectEntry(key: .literal("__loc__"), value: AST(.literal(locObject(at: token.range)), token.range),
                               range: token.range)
        case .stringStart:
            let key = try parseString(format: "text")
            return try finishStringKeyEntry(key)
        case .format(let name):
            let next = try peek()
            guard case .stringStart = next.kind else {
                throw SyntaxError(kind: .objectKeyNeedsParentheses, range: token.range)
            }
            try advance()
            let key = try parseString(format: name, formatRange: token.range)
            return try finishStringKeyEntry(key)
        case .op("("):
            try advance()
            let key = try parseExp(Precedence.pipe)
            try expectOp(")", context: token)
            if case .literal(let constant) = key.kind, constant.stringValue == nil {
                throw SyntaxError(kind: .invalidObjectKey(Builtins.describeForError(constant)), range: key.range)
            }
            try expectOp(":", context: nil)
            let value = try parseObjectValue()
            return ObjectEntry(key: .expression(key), value: value, range: token.range.union(value.range))
        case .number:
            throw SyntaxError(kind: .objectKeyNeedsParentheses, range: token.range)
        default:
            throw unexpected(token, expectingValue: true)
        }
    }

    private func indexOfIdentity(_ name: String, _ range: SourceRange) -> AST {
        AST(.index(target: AST(.identity, range), key: AST(.literal(.string(name)), range), optional: false), range)
    }

    private mutating func finishObjectEntry(key: ObjectEntry.Key, shorthand: AST, start: SourceRange) throws -> ObjectEntry {
        if isOp(":") {
            try advance()
            let value = try parseObjectValue()
            return ObjectEntry(key: key, value: value, range: start.union(value.range))
        }
        return ObjectEntry(key: key, value: shorthand, range: start)
    }

    private mutating func finishStringKeyEntry(_ key: AST) throws -> ObjectEntry {
        let keyForm: ObjectEntry.Key
        if case .string(let parts, let format) = key.kind, format == "text", parts.count <= 1,
           case .text(let text)? = parts.first {
            keyForm = .literal(text)
        } else if case .string(let parts, _) = key.kind, parts.isEmpty {
            keyForm = .literal("")
        } else {
            keyForm = .expression(key)
        }
        if isOp(":") {
            try advance()
            let value = try parseObjectValue()
            return ObjectEntry(key: keyForm, value: value, range: key.range.union(value.range))
        }
        // `{"a b"}` means `{"a b": .["a b"]}`.
        let value = AST(.index(target: AST(.identity, key.range), key: key, optional: false), key.range)
        return ObjectEntry(key: keyForm, value: value, range: key.range)
    }

    /// `ExpD: ExpD '|' ExpD | '-' ExpD | Term`
    private mutating func parseObjectValue() throws -> AST {
        let lhs = try parseObjectValuePrimary()
        if isOp("|") {
            try advance()
            let rhs = try parseObjectValue()
            return AST(.pipe(lhs, rhs), lhs.range.union(rhs.range))
        }
        return lhs
    }

    private mutating func parseObjectValuePrimary() throws -> AST {
        if isOp("-") {
            let minus = current
            try advance()
            let operand = try parseObjectValuePrimary()
            return AST(.negate(operand), minus.range.union(operand.range))
        }
        return try parseTerm()
    }

    // MARK: Patterns

    private mutating func parsePatterns() throws -> [Pattern] {
        var patterns = [try parsePattern()]
        while isOp("?//") {
            try advance()
            patterns.append(try parsePattern())
        }
        return patterns
    }

    private mutating func parsePattern() throws -> Pattern {
        let token = current
        switch token.kind {
        case .binding(let name):
            try advance()
            return .variable(name: name, range: token.range)
        case .op("["):
            try advance()
            var items: [Pattern] = []
            while true {
                items.append(try parsePattern())
                if isOp(",") {
                    try advance()
                    continue
                }
                let close = current
                try expectOp("]", context: token)
                return .array(items, range: token.range.union(close.range))
            }
        case .op("{"):
            try advance()
            var entries: [ObjectPatternEntry] = []
            while true {
                entries.append(try parseObjectPatternEntry())
                if isOp(",") {
                    try advance()
                    continue
                }
                let close = current
                try expectOp("}", context: token)
                return .object(entries, range: token.range.union(close.range))
            }
        default:
            throw unexpected(token, expectingValue: true)
        }
    }

    private mutating func parseObjectPatternEntry() throws -> ObjectPatternEntry {
        let token = current
        switch token.kind {
        case .binding(let name):
            try advance()
            if isOp(":") {
                try advance()
                let pattern = try parsePattern()
                return ObjectPatternEntry(key: .literal(name), bindsVariable: name, pattern: pattern,
                                          range: token.range.union(pattern.range))
            }
            return ObjectPatternEntry(key: .literal(name), bindsVariable: name, pattern: nil, range: token.range)
        case .ident(let name):
            try advance()
            try expectOp(":", context: nil)
            let pattern = try parsePattern()
            return ObjectPatternEntry(key: .literal(name), bindsVariable: nil, pattern: pattern,
                                      range: token.range.union(pattern.range))
        case .keyword(let keyword):
            try advance()
            try expectOp(":", context: nil)
            let pattern = try parsePattern()
            return ObjectPatternEntry(key: .literal(keyword.rawValue), bindsVariable: nil, pattern: pattern,
                                      range: token.range.union(pattern.range))
        case .stringStart:
            let key = try parseString(format: "text")
            try expectOp(":", context: nil)
            let pattern = try parsePattern()
            return ObjectPatternEntry(key: .expression(key), bindsVariable: nil, pattern: pattern,
                                      range: key.range.union(pattern.range))
        case .op("("):
            try advance()
            let key = try parseExp(Precedence.pipe)
            try expectOp(")", context: token)
            try expectOp(":", context: nil)
            let pattern = try parsePattern()
            return ObjectPatternEntry(key: .expression(key), bindsVariable: nil, pattern: pattern,
                                      range: token.range.union(pattern.range))
        default:
            throw unexpected(token, expectingValue: true)
        }
    }
}
