import Foundation

typealias Emit = (JSON) throws -> Void

/// A value together with its path from the root, for path expressions. A nil
/// path marks a value that did not come from a path expression.
struct PathValue {
    var path: [JSON]?
    var value: JSON
}

typealias PathEmit = (PathValue) throws -> Void

/// Result of evaluating a node directly on an owned accumulator.
enum InPlaceResult {
    /// The node does not support in-place evaluation.
    case unsupported
    /// The accumulator now holds the node's single output.
    case single
    /// The node produced these outputs (zero or several).
    case outputs([JSON])
}

/// An executable node. Every node can run normally (`eval`) and as a path
/// expression (`paths`).
class Node {
    let range: SourceRange

    init(range: SourceRange) {
        self.range = range
    }

    func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        fatalError("eval not implemented")
    }

    /// Path mode. Nodes that are not path expressions produce untracked values.
    func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try eval(input.value, env, ctx) { v in try k(PathValue(path: nil, value: v)) }
    }

    /// Evaluates on an accumulator the caller owns, so updates like `. + [$x]`
    /// or `.[$k] += 1` inside `reduce` do not copy the accumulator.
    func evalInPlace(_ value: inout JSON, _ env: Env?, _ ctx: Context) throws -> InPlaceResult {
        .unsupported
    }

    /// True when the node always produces exactly its input (used to spot
    /// `. + x` in accumulators).
    var isIdentity: Bool { false }

    /// Collects every output.
    final func collect(_ input: JSON, _ env: Env?, _ ctx: Context) throws -> [JSON] {
        var out: [JSON] = []
        try eval(input, env, ctx) { out.append($0) }
        return out
    }
}

/// Tags errors thrown by a continuation so an enclosing `try` lets them pass:
/// `try` only catches errors raised by its own body.
struct DownstreamError: Error {
    let tag: ObjectIdentifier
    let error: Error
}

@inline(__always)
func invalidPathResult(_ value: JSON) -> JQRuntimeError {
    JQRuntimeError("Invalid path expression with result \(Ops.truncatedDump(value, bufferSize: 30))", kind: .invalidPath)
}

// MARK: - Basic nodes

final class IdentityNode: Node {
    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try k(input)
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try k(input)
    }

    override func evalInPlace(_ value: inout JSON, _ env: Env?, _ ctx: Context) throws -> InPlaceResult {
        .single
    }

    override var isIdentity: Bool { true }
}

final class LiteralNode: Node {
    let value: JSON

    init(_ value: JSON, range: SourceRange) {
        self.value = value
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try k(value)
    }
}

/// `..`: the input and everything inside it, depth first.
final class RecurseAllNode: Node {
    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        var stack: [JSON] = [input]
        while let v = stack.popLast() {
            try ctx.tick()
            try k(v)
            switch v {
            case .array(let a):
                for item in a.reversed() { stack.append(item) }
            case .object(let o):
                for item in o.values.reversed() { stack.append(item) }
            default:
                break
            }
        }
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try RecurseAllNode.walkPaths(input, ctx, k)
    }

    static func walkPaths(_ input: PathValue, _ ctx: Context, _ k: PathEmit) throws {
        guard let root = input.path else {
            throw JQRuntimeError("Invalid path expression near attempt to iterate through \(Ops.truncatedDump(input.value, bufferSize: 30))",
                                 kind: .invalidPath)
        }
        var stack: [PathValue] = [PathValue(path: root, value: input.value)]
        while let pv = stack.popLast() {
            try ctx.tick()
            try k(pv)
            let base = pv.path!
            switch pv.value {
            case .array(let a):
                for (i, item) in a.enumerated().reversed() {
                    stack.append(PathValue(path: base + [.number(i)], value: item))
                }
            case .object(let o):
                for (key, item) in o.entries.reversed() {
                    stack.append(PathValue(path: base + [.string(key)], value: item))
                }
            default:
                break
            }
        }
    }
}

// MARK: - Index, slice, iterate

/// `.[key]` and `.name`. The key is evaluated against the term's input, in the
/// outer loop; the target in the inner loop.
final class IndexNode: Node {
    let target: Node
    let key: Node
    let optional: Bool

    init(target: Node, key: Node, optional: Bool, range: SourceRange) {
        self.target = target
        self.key = key
        self.optional = optional
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        if let literal = key as? LiteralNode {
            try evalWithKey(literal.value, input, env, ctx, k)
            return
        }
        try key.eval(input, env, ctx) { keyValue in
            try self.evalWithKey(keyValue, input, env, ctx, k)
        }
    }

    @inline(__always)
    private func evalWithKey(_ keyValue: JSON, _ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        if target.isIdentity {
            try indexOne(input, keyValue, k)
            return
        }
        try target.eval(input, env, ctx) { t in
            try self.indexOne(t, keyValue, k)
        }
    }

    @inline(__always)
    private func indexOne(_ t: JSON, _ keyValue: JSON, _ k: Emit) throws {
        let result: JSON
        do {
            result = try Ops.index(t, keyValue)
        } catch let error as JQRuntimeError {
            if optional { return }
            throw error.located(range, subject: target.range)
        }
        try k(result)
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try key.eval(input.value, env, ctx) { keyValue in
            try self.target.paths(input, env, ctx) { pv in
                guard let path = pv.path else {
                    if self.optional { return }
                    throw JQRuntimeError("Invalid path expression near attempt to access element \(Ops.truncatedDump(keyValue)) of \(Ops.truncatedDump(pv.value, bufferSize: 30))",
                                         kind: .invalidPath).located(self.range)
                }
                let result: JSON
                do {
                    result = try Ops.index(pv.value, keyValue)
                } catch let error as JQRuntimeError {
                    if self.optional { return }
                    throw error.located(self.range, subject: self.target.range)
                }
                try k(PathValue(path: path + [keyValue], value: result))
            }
        }
    }
}

final class SliceNode: Node {
    let target: Node
    let from: Node
    let to: Node
    let optional: Bool

    init(target: Node, from: Node?, to: Node?, optional: Bool, range: SourceRange) {
        self.target = target
        self.from = from ?? LiteralNode(.null, range: range)
        self.to = to ?? LiteralNode(.null, range: range)
        self.optional = optional
        super.init(range: range)
    }

    /// Start outermost, then end, then the target.
    private func forEachKey(_ input: JSON, _ env: Env?, _ ctx: Context, _ body: (JSON) throws -> Void) throws {
        try from.eval(input, env, ctx) { f in
            try self.to.eval(input, env, ctx) { t in
                try body(Ops.sliceKey(f, t))
            }
        }
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try forEachKey(input, env, ctx) { keyValue in
            try self.target.eval(input, env, ctx) { t in
                let result: JSON
                do {
                    result = try Ops.index(t, keyValue)
                } catch let error as JQRuntimeError {
                    if self.optional { return }
                    throw error.located(self.range, subject: self.target.range)
                }
                try k(result)
            }
        }
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try forEachKey(input.value, env, ctx) { keyValue in
            try self.target.paths(input, env, ctx) { pv in
                guard let path = pv.path else {
                    if self.optional { return }
                    throw JQRuntimeError("Invalid path expression near attempt to access element \(Ops.truncatedDump(keyValue)) of \(Ops.truncatedDump(pv.value, bufferSize: 30))",
                                         kind: .invalidPath).located(self.range)
                }
                let result: JSON
                do {
                    result = try Ops.index(pv.value, keyValue)
                } catch let error as JQRuntimeError {
                    if self.optional { return }
                    throw error.located(self.range, subject: self.target.range)
                }
                try k(PathValue(path: path + [keyValue], value: result))
            }
        }
    }
}

/// `.[]`
final class IterateNode: Node {
    let target: Node
    let optional: Bool

    init(target: Node, optional: Bool, range: SourceRange) {
        self.target = target
        self.optional = optional
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        if target.isIdentity {
            try iterate(input, ctx, k)
            return
        }
        try target.eval(input, env, ctx) { t in
            try self.iterate(t, ctx, k)
        }
    }

    @inline(__always)
    private func iterate(_ t: JSON, _ ctx: Context, _ k: Emit) throws {
        switch t {
        case .array(let a):
            for item in a {
                try ctx.tick()
                try k(item)
            }
        case .object(let o):
            for item in o.values {
                try ctx.tick()
                try k(item)
            }
        default:
            if optional { return }
            throw JQRuntimeError("Cannot iterate over \(Ops.describe(t))", kind: .iterate(type: t.typeName))
                .located(range, subject: target.range)
        }
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try target.paths(input, env, ctx) { pv in
            guard let path = pv.path else {
                if self.optional { return }
                throw JQRuntimeError("Invalid path expression near attempt to iterate through \(Ops.truncatedDump(pv.value, bufferSize: 30))",
                                     kind: .invalidPath).located(self.range)
            }
            switch pv.value {
            case .array(let a):
                for (i, item) in a.enumerated() {
                    try ctx.tick()
                    try k(PathValue(path: path + [.number(i)], value: item))
                }
            case .object(let o):
                for (key, item) in o.entries {
                    try ctx.tick()
                    try k(PathValue(path: path + [.string(key)], value: item))
                }
            default:
                if self.optional { return }
                throw JQRuntimeError("Cannot iterate over \(Ops.describe(pv.value))", kind: .iterate(type: pv.value.typeName))
                    .located(self.range, subject: self.target.range)
            }
        }
    }
}

// MARK: - Composition

final class PipeNode: Node {
    let lhs: Node
    let rhs: Node

    init(_ lhs: Node, _ rhs: Node, range: SourceRange) {
        self.lhs = lhs
        self.rhs = rhs
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try lhs.eval(input, env, ctx) { v in
            try self.rhs.eval(v, env, ctx, k)
        }
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try lhs.paths(input, env, ctx) { pv in
            try self.rhs.paths(pv, env, ctx, k)
        }
    }

    override func evalInPlace(_ value: inout JSON, _ env: Env?, _ ctx: Context) throws -> InPlaceResult {
        switch try lhs.evalInPlace(&value, env, ctx) {
        case .unsupported:
            return .unsupported
        case .single:
            switch try rhs.evalInPlace(&value, env, ctx) {
            case .unsupported:
                return .outputs(try rhs.collect(value, env, ctx))
            case let other:
                return other
            }
        case .outputs(let mids):
            var out: [JSON] = []
            for m in mids { try rhs.eval(m, env, ctx) { out.append($0) } }
            return .outputs(out)
        }
    }
}

final class CommaNode: Node {
    let lhs: Node
    let rhs: Node

    init(_ lhs: Node, _ rhs: Node, range: SourceRange) {
        self.lhs = lhs
        self.rhs = rhs
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try lhs.eval(input, env, ctx, k)
        try rhs.eval(input, env, ctx, k)
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try lhs.paths(input, env, ctx, k)
        try rhs.paths(input, env, ctx, k)
    }
}

final class NegateNode: Node {
    let operand: Node

    init(_ operand: Node, range: SourceRange) {
        self.operand = operand
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try operand.eval(input, env, ctx) { v in
            do {
                try k(try Ops.negate(v))
            } catch let error as JQRuntimeError {
                throw error.located(self.range, subject: self.operand.range)
            }
        }
    }
}

/// Arithmetic and comparison. jq evaluates the right operand in the outer
/// loop: `[(1,2) + (10,20)]` is `[11,12,21,22]`.
final class BinaryNode: Node {
    let op: BinaryOperator
    let lhs: Node
    let rhs: Node

    init(_ op: BinaryOperator, _ lhs: Node, _ rhs: Node, range: SourceRange) {
        self.op = op
        self.lhs = lhs
        self.rhs = rhs
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try rhs.eval(input, env, ctx) { b in
            try self.lhs.eval(input, env, ctx) { a in
                let result: JSON
                do {
                    result = try Ops.binary(self.op, a, b, ctx: ctx)
                } catch let error as JQRuntimeError {
                    throw error.located(self.range, subject: self.lhs.range)
                }
                try k(result)
            }
        }
    }

    override func evalInPlace(_ value: inout JSON, _ env: Env?, _ ctx: Context) throws -> InPlaceResult {
        guard op == .add, lhs.isIdentity else { return .unsupported }
        let rights = try rhs.collect(value, env, ctx)
        if rights.count == 1 {
            do {
                try Ops.addInPlace(&value, rights[0])
            } catch let error as JQRuntimeError {
                throw error.located(range, subject: lhs.range)
            }
            return .single
        }
        var out: [JSON] = []
        for b in rights {
            do {
                out.append(try Ops.add(value, b))
            } catch let error as JQRuntimeError {
                throw error.located(range, subject: lhs.range)
            }
        }
        return .outputs(out)
    }
}

final class AndNode: Node {
    let lhs: Node
    let rhs: Node

    init(_ lhs: Node, _ rhs: Node, range: SourceRange) {
        self.lhs = lhs
        self.rhs = rhs
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try lhs.eval(input, env, ctx) { a in
            if !a.isTruthy {
                try k(.false)
                return
            }
            try self.rhs.eval(input, env, ctx) { b in try k(.bool(b.isTruthy)) }
        }
    }
}

final class OrNode: Node {
    let lhs: Node
    let rhs: Node

    init(_ lhs: Node, _ rhs: Node, range: SourceRange) {
        self.lhs = lhs
        self.rhs = rhs
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try lhs.eval(input, env, ctx) { a in
            if a.isTruthy {
                try k(.true)
                return
            }
            try self.rhs.eval(input, env, ctx) { b in try k(.bool(b.isTruthy)) }
        }
    }
}

/// `a // b`: a's truthy outputs, or b's outputs when a has none. In jq 1.7.1
/// errors raised by `a` propagate.
final class AlternativeNode: Node {
    let lhs: Node
    let rhs: Node

    init(_ lhs: Node, _ rhs: Node, range: SourceRange) {
        self.lhs = lhs
        self.rhs = rhs
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        var found = false
        try lhs.eval(input, env, ctx) { v in
            guard v.isTruthy else { return }
            found = true
            try k(v)
        }
        if !found {
            try rhs.eval(input, env, ctx, k)
        }
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        var found = false
        try lhs.paths(input, env, ctx) { pv in
            guard pv.value.isTruthy else { return }
            found = true
            try k(pv)
        }
        if !found {
            try rhs.paths(input, env, ctx, k)
        }
    }
}

// MARK: - Construction

final class ArrayNode: Node {
    let body: Node?

    init(_ body: Node?, range: SourceRange) {
        self.body = body
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        guard let body else {
            try k(.array([]))
            return
        }
        var items: [JSON] = []
        try body.eval(input, env, ctx) { v in
            items.append(v)
            if items.count & 0xFFFF == 0 { try ctx.checkSize(items.count) }
        }
        try k(.array(items))
    }
}

final class ObjectNode: Node {
    enum Key {
        case literal(String)
        case expression(Node)
    }

    let entries: [(key: Key, value: Node, range: SourceRange)]

    init(entries: [(key: Key, value: Node, range: SourceRange)], range: SourceRange) {
        self.entries = entries
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        var object = JSONObject(minimumCapacity: entries.count)
        try build(0, &object, input, env, ctx, k)
    }

    /// Entries left to right, outer to inner; within an entry, key then value.
    private func build(_ index: Int, _ object: inout JSONObject, _ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        if index == entries.count {
            try k(.object(object))
            return
        }
        let entry = entries[index]
        switch entry.key {
        case .literal(let name):
            try entry.value.eval(input, env, ctx) { v in
                var copy = object
                copy.set(name, v)
                try self.build(index + 1, &copy, input, env, ctx, k)
            }
        case .expression(let keyNode):
            try keyNode.eval(input, env, ctx) { keyValue in
                guard case .string(let name) = keyValue else {
                    throw JQRuntimeError("Cannot use \(Ops.describe(keyValue)) as object key",
                                         kind: .objectKey(type: keyValue.typeName))
                        .located(entry.range, subject: keyNode.range)
                }
                try entry.value.eval(input, env, ctx) { v in
                    var copy = object
                    copy.set(name, v)
                    try self.build(index + 1, &copy, input, env, ctx, k)
                }
            }
        }
    }
}

/// A string literal with interpolations. Later interpolations are outer
/// loops, as in jq.
final class StringNode: Node {
    enum Part {
        case text(String)
        case interpolation(Node)
    }

    let parts: [Part]
    let format: String

    init(parts: [Part], format: String, range: SourceRange) {
        self.parts = parts
        self.format = format
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try build(parts.count - 1, input, env, ctx) { prefix in try k(.string(prefix)) }
    }

    /// Produces every value of parts[0...index], outermost loop last.
    private func build(_ index: Int, _ input: JSON, _ env: Env?, _ ctx: Context, _ k: (String) throws -> Void) throws {
        if index < 0 {
            try k("")
            return
        }
        switch parts[index] {
        case .text(let text):
            try build(index - 1, input, env, ctx) { prefix in try k(prefix + text) }
        case .interpolation(let node):
            try node.eval(input, env, ctx) { v in
                let formatted: String
                do {
                    formatted = try Formats.apply(self.format, to: v)
                } catch let error as JQRuntimeError {
                    throw error.located(node.range)
                }
                try self.build(index - 1, input, env, ctx) { prefix in try k(prefix + formatted) }
            }
        }
    }
}

/// `@base64` and friends applied to `.`.
final class FormatNode: Node {
    let name: String

    init(name: String, range: SourceRange) {
        self.name = name
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        do {
            try k(.string(try Formats.apply(name, to: input)))
        } catch let error as JQRuntimeError {
            throw error.located(range)
        }
    }
}

// MARK: - Control flow

final class IfNode: Node {
    let cond: Node
    let then: Node
    let otherwise: Node

    init(cond: Node, then: Node, otherwise: Node, range: SourceRange) {
        self.cond = cond
        self.then = then
        self.otherwise = otherwise
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try cond.eval(input, env, ctx) { c in
            if c.isTruthy {
                try self.then.eval(input, env, ctx, k)
            } else {
                try self.otherwise.eval(input, env, ctx, k)
            }
        }
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try cond.eval(input.value, env, ctx) { c in
            if c.isTruthy {
                try self.then.paths(input, env, ctx, k)
            } else {
                try self.otherwise.paths(input, env, ctx, k)
            }
        }
    }

    override func evalInPlace(_ value: inout JSON, _ env: Env?, _ ctx: Context) throws -> InPlaceResult {
        let conds = try cond.collect(value, env, ctx)
        if conds.count == 1 {
            let branch = conds[0].isTruthy ? then : otherwise
            switch try branch.evalInPlace(&value, env, ctx) {
            case .unsupported:
                return .outputs(try branch.collect(value, env, ctx))
            case let other:
                return other
            }
        }
        var out: [JSON] = []
        for c in conds {
            try (c.isTruthy ? then : otherwise).eval(value, env, ctx) { out.append($0) }
        }
        return .outputs(out)
    }
}

/// `try body catch handler` and `body?`. Only errors raised by the body are
/// caught; `break`, `halt` and resource limits pass through.
final class TryNode: Node {
    let body: Node
    let handler: Node?

    init(body: Node, handler: Node?, range: SourceRange) {
        self.body = body
        self.handler = handler
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        let tag = ObjectIdentifier(self)
        do {
            try body.eval(input, env, ctx) { v in
                do {
                    try k(v)
                } catch {
                    throw DownstreamError(tag: tag, error: error)
                }
            }
        } catch let d as DownstreamError where d.tag == tag {
            throw d.error
        } catch let error as JQRuntimeError {
            guard let handler else { return }
            try handler.eval(error.value, env, ctx, k)
        } catch let signal as BreakSignal {
            // jq 1.7.1: `break` is an error, so `try` inside the label catches it.
            guard let handler else { return }
            try handler.eval(signal.label.value, env, ctx, k)
        }
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        let tag = ObjectIdentifier(self)
        do {
            try body.paths(input, env, ctx) { pv in
                do {
                    try k(pv)
                } catch {
                    throw DownstreamError(tag: tag, error: error)
                }
            }
        } catch let d as DownstreamError where d.tag == tag {
            throw d.error
        } catch let error as JQRuntimeError {
            guard let handler else { return }
            try handler.paths(PathValue(path: nil, value: error.value), env, ctx, k)
        } catch let signal as BreakSignal {
            guard let handler else { return }
            try handler.paths(PathValue(path: nil, value: signal.label.value), env, ctx, k)
        }
    }
}

// MARK: - Variables and bindings

final class VariableNode: Node {
    let depth: Int
    let name: String

    init(depth: Int, name: String, range: SourceRange) {
        self.depth = depth
        self.name = name
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        guard case .value(let v) = env!.at(depth).slot else {
            fatalError("variable $\(name) resolved to a non-value frame")
        }
        try k(v)
    }
}

final class GlobalVariableNode: Node {
    let index: Int

    init(index: Int, range: SourceRange) {
        self.index = index
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try k(ctx.globals[index])
    }
}

/// A compiled destructuring pattern. Binds variables as frames, in order.
indirect enum CompiledPattern {
    case variable
    case array([CompiledPattern])
    case object([(key: CompiledPatternKey, bindsVariable: Bool, pattern: CompiledPattern?)])
}

enum CompiledPatternKey {
    case literal(String)
    /// Evaluated in the scope where the pattern starts, plus the frames bound
    /// so far by this pattern.
    case expression(Node)
}

enum Destructure {
    /// Binds `value` to `pattern`, pushing one frame per variable, and calls
    /// `body` for every combination (key expressions can be generators).
    static func bind(_ pattern: CompiledPattern, _ value: JSON, _ env: Env?, _ input: JSON, _ ctx: Context,
                     _ body: (Env?) throws -> Void) throws {
        switch pattern {
        case .variable:
            try body(Env(.value(value), parent: env))
        case .array(let items):
            try bindArray(items, 0, value, env, input, ctx, body)
        case .object(let entries):
            try bindObject(entries, 0, value, env, input, ctx, body)
        }
    }

    private static func bindArray(_ items: [CompiledPattern], _ i: Int, _ value: JSON, _ env: Env?, _ input: JSON,
                                  _ ctx: Context, _ body: (Env?) throws -> Void) throws {
        if i == items.count {
            try body(env)
            return
        }
        let element: JSON
        switch value {
        case .array(let a):
            element = i < a.count ? a[i] : .null
        case .null:
            element = .null
        default:
            throw JQRuntimeError("Cannot index \(value.typeName) with number",
                                 kind: .index(target: value.typeName, key: "number"))
        }
        try bind(items[i], element, env, input, ctx) { inner in
            try bindArray(items, i + 1, value, inner, input, ctx, body)
        }
    }

    private static func bindObject(_ entries: [(key: CompiledPatternKey, bindsVariable: Bool, pattern: CompiledPattern?)],
                                   _ i: Int, _ value: JSON, _ env: Env?, _ input: JSON, _ ctx: Context,
                                   _ body: (Env?) throws -> Void) throws {
        if i == entries.count {
            try body(env)
            return
        }
        let entry = entries[i]
        func withKey(_ key: JSON) throws {
            guard case .string = key else {
                throw JQRuntimeError("Cannot index \(value.typeName) with \(key.typeName)",
                                     kind: .index(target: value.typeName, key: key.typeName))
            }
            let element = try Ops.index(value, key)
            var scope = env
            if entry.bindsVariable {
                scope = Env(.value(element), parent: scope)
            }
            if let pattern = entry.pattern {
                try bind(pattern, element, scope, input, ctx) { inner in
                    try bindObject(entries, i + 1, value, inner, input, ctx, body)
                }
            } else {
                try bindObject(entries, i + 1, value, scope, input, ctx, body)
            }
        }
        switch entry.key {
        case .literal(let name):
            try withKey(.string(name))
        case .expression(let node):
            try node.eval(input, env, ctx) { key in try withKey(key) }
        }
    }
}

/// Patterns joined by `?//`. Every alternative binds the same frames (the union
/// of all variables, null when absent), so the body resolves identically.
struct PatternSet {
    let alternatives: [CompiledPattern]
    /// For each alternative, a mapping from its own frames to the union.
    let layouts: [[Int]]
    let unionCount: Int

    var isSingle: Bool { alternatives.count == 1 }

    /// Runs `body` for each binding. With alternatives, an error in
    /// destructuring or in the body moves on to the next alternative.
    func bind(_ value: JSON, _ env: Env?, _ input: JSON, _ ctx: Context, _ body: (Env?) throws -> Void) throws {
        if isSingle {
            try Destructure.bind(alternatives[0], value, env, input, ctx, body)
            return
        }
        for (index, pattern) in alternatives.enumerated() {
            let isLast = index == alternatives.count - 1
            do {
                try Destructure.bind(pattern, value, env, input, ctx) { bound in
                    // Collect this alternative's values in binding order.
                    var own: [JSON] = []
                    var e = bound
                    while let frame = e, frame !== env {
                        if case .value(let v) = frame.slot { own.append(v) }
                        e = frame.parent
                    }
                    own.reverse()
                    var union = [JSON](repeating: .null, count: unionCount)
                    for (i, slot) in layouts[index].enumerated() where i < own.count {
                        union[slot] = own[i]
                    }
                    var scope = env
                    for v in union { scope = Env(.value(v), parent: scope) }
                    try body(scope)
                }
                return
            } catch let error as JQRuntimeError {
                if isLast { throw error }
            } catch let stop as ControlFlowStop {
                // jq 1.7.1 treats a `break` that unwinds through `?//` like an
                // error and tries the next alternative.
                if isLast { throw stop }
            }
        }
    }
}

final class BindNode: Node {
    let source: Node
    let patterns: PatternSet
    let body: Node

    init(source: Node, patterns: PatternSet, body: Node, range: SourceRange) {
        self.source = source
        self.patterns = patterns
        self.body = body
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try source.eval(input, env, ctx) { v in
            try self.patterns.bind(v, env, input, ctx) { scope in
                try self.body.eval(input, scope, ctx, k)
            }
        }
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try source.eval(input.value, env, ctx) { v in
            try self.patterns.bind(v, env, input.value, ctx) { scope in
                try self.body.paths(input, scope, ctx, k)
            }
        }
    }
}

/// `reduce SOURCE as $x (INIT; UPDATE)`. An update with no output leaves
/// null; with several outputs the last one wins (jq 1.7).
final class ReduceNode: Node {
    let source: Node
    let patterns: PatternSet
    let initial: Node
    let update: Node

    init(source: Node, patterns: PatternSet, initial: Node, update: Node, range: SourceRange) {
        self.source = source
        self.patterns = patterns
        self.initial = initial
        self.update = update
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try initial.eval(input, env, ctx) { start in
            var acc = start
            try self.source.eval(input, env, ctx) { item in
                try ctx.tick()
                try self.patterns.bind(item, env, input, ctx) { scope in
                    switch try self.update.evalInPlace(&acc, scope, ctx) {
                    case .single:
                        break
                    case .outputs(let outs):
                        acc = outs.last ?? .null
                    case .unsupported:
                        let current = acc
                        acc = .null
                        var last: JSON = .null
                        try self.update.eval(current, scope, ctx) { last = $0 }
                        acc = last
                    }
                }
            }
            try k(acc)
        }
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try initial.paths(input, env, ctx) { start in
            var acc = start
            try self.source.eval(input.value, env, ctx) { item in
                try ctx.tick()
                try self.patterns.bind(item, env, input.value, ctx) { scope in
                    var last = PathValue(path: nil, value: .null)
                    try self.update.paths(acc, scope, ctx) { last = $0 }
                    acc = last
                }
            }
            try k(acc)
        }
    }
}

/// `foreach SOURCE as $x (INIT; UPDATE; EXTRACT)`.
final class ForeachNode: Node {
    let source: Node
    let patterns: PatternSet
    let initial: Node
    let update: Node
    let extract: Node?

    init(source: Node, patterns: PatternSet, initial: Node, update: Node, extract: Node?, range: SourceRange) {
        self.source = source
        self.patterns = patterns
        self.initial = initial
        self.update = update
        self.extract = extract
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try initial.eval(input, env, ctx) { start in
            var state = start
            try self.source.eval(input, env, ctx) { item in
                try ctx.tick()
                try self.patterns.bind(item, env, input, ctx) { scope in
                    let current = state
                    state = .null
                    try self.update.eval(current, scope, ctx) { next in
                        state = next
                        if let extract = self.extract {
                            try extract.eval(next, scope, ctx, k)
                        } else {
                            try k(next)
                        }
                    }
                }
            }
        }
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try initial.paths(input, env, ctx) { start in
            var state = start
            try self.source.eval(input.value, env, ctx) { item in
                try ctx.tick()
                try self.patterns.bind(item, env, input.value, ctx) { scope in
                    let current = state
                    state = PathValue(path: nil, value: .null)
                    try self.update.paths(current, scope, ctx) { next in
                        state = next
                        if let extract = self.extract {
                            try extract.paths(next, scope, ctx, k)
                        } else {
                            try k(next)
                        }
                    }
                }
            }
        }
    }
}

final class LabelNode: Node {
    let body: Node

    init(body: Node, range: SourceRange) {
        self.body = body
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        let token = ctx.makeLabel()
        do {
            try body.eval(input, Env(.label(token), parent: env), ctx, k)
        } catch let signal as BreakSignal where signal.label === token {
            return
        } catch let error as JQRuntimeError where error.value == token.value {
            return
        }
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        let token = ctx.makeLabel()
        do {
            try body.paths(input, Env(.label(token), parent: env), ctx, k)
        } catch let signal as BreakSignal where signal.label === token {
            return
        } catch let error as JQRuntimeError where error.value == token.value {
            return
        }
    }
}

final class BreakNode: Node {
    let depth: Int

    init(depth: Int, range: SourceRange) {
        self.depth = depth
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        guard case .label(let token) = env!.at(depth).slot else {
            fatalError("break resolved to a non-label frame")
        }
        throw BreakSignal(label: token)
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try eval(input.value, env, ctx) { _ in }
    }
}

// MARK: - Functions

/// `def f: ...; body` for a definition inside an expression.
final class FunctionDefinitionNode: Node {
    let function: CompiledFunction
    let body: Node

    init(function: CompiledFunction, body: Node, range: SourceRange) {
        self.function = function
        self.body = body
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try body.eval(input, Env(.function(function), parent: env), ctx, k)
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try body.paths(input, Env(.function(function), parent: env), ctx, k)
    }

    override func evalInPlace(_ value: inout JSON, _ env: Env?, _ ctx: Context) throws -> InPlaceResult {
        try body.evalInPlace(&value, Env(.function(function), parent: env), ctx)
    }
}

/// Calls a jq-defined function. `depth` locates the frame of a local
/// definition; nil means a top-level or builtin definition.
final class CallFunctionNode: Node {
    let function: CompiledFunction
    let depth: Int?
    let args: [Node]

    init(function: CompiledFunction, depth: Int?, args: [Node], range: SourceRange) {
        self.function = function
        self.depth = depth
        self.args = args
        super.init(range: range)
    }

    /// The environment the body runs in, before parameters.
    @inline(__always)
    private func baseEnv(_ env: Env?) -> Env? {
        guard let depth else { return nil }
        return env!.at(depth)
    }

    /// Pushes closure frames for every parameter, then value frames for `$`
    /// parameters (outer to inner), calling `body` once per combination.
    private func bindParameters(_ input: JSON, _ env: Env?, _ ctx: Context, _ body: (Env?) throws -> Void) throws {
        var scope = baseEnv(env)
        let params = function.parameters
        if params.isEmpty {
            try body(scope)
            return
        }
        for (i, _) in params.enumerated() {
            scope = Env(.closure(args[i], env), parent: scope)
        }
        let valueParams = params.indices.filter { if case .value = params[$0] { return true } else { return false } }
        if valueParams.isEmpty {
            try body(scope)
            return
        }
        try bindValues(valueParams[...], scope, input, env, ctx, body)
    }

    private func bindValues(_ remaining: ArraySlice<Int>, _ scope: Env?, _ input: JSON, _ callerEnv: Env?,
                            _ ctx: Context, _ body: (Env?) throws -> Void) throws {
        guard let first = remaining.first else {
            try body(scope)
            return
        }
        try args[first].eval(input, callerEnv, ctx) { v in
            try self.bindValues(remaining.dropFirst(), Env(.value(v), parent: scope), input, callerEnv, ctx, body)
        }
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        try ctx.tick()
        try ctx.checkStack()
        try bindParameters(input, env, ctx) { scope in
            do {
                try function.body.eval(input, scope, ctx, k)
            } catch let error as JQRuntimeError where error.range == nil {
                throw error.located(range)
            }
        }
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        try ctx.tick()
        try ctx.checkStack()
        try bindParameters(input.value, env, ctx) { scope in
            try function.body.paths(input, scope, ctx, k)
        }
    }

    override func evalInPlace(_ value: inout JSON, _ env: Env?, _ ctx: Context) throws -> InPlaceResult {
        guard function.parameters.isEmpty else { return .unsupported }
        try ctx.checkStack()
        return try function.body.evalInPlace(&value, baseEnv(env), ctx)
    }
}

/// Invokes a filter argument inside the function that received it.
final class CallClosureNode: Node {
    let depth: Int

    init(depth: Int, range: SourceRange) {
        self.depth = depth
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        guard case .closure(let node, let closureEnv) = env!.at(depth).slot else {
            fatalError("closure call resolved to a non-closure frame")
        }
        try ctx.checkStack()
        try node.eval(input, closureEnv, ctx, k)
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        guard case .closure(let node, let closureEnv) = env!.at(depth).slot else {
            fatalError("closure call resolved to a non-closure frame")
        }
        try ctx.checkStack()
        try node.paths(input, closureEnv, ctx, k)
    }

    override func evalInPlace(_ value: inout JSON, _ env: Env?, _ ctx: Context) throws -> InPlaceResult {
        guard case .closure(let node, let closureEnv) = env!.at(depth).slot else {
            return .unsupported
        }
        return try node.evalInPlace(&value, closureEnv, ctx)
    }
}

/// A builtin implemented in Swift.
final class CallNativeNode: Node {
    let builtin: NativeBuiltin
    let args: [Node]

    init(builtin: NativeBuiltin, args: [Node], range: SourceRange) {
        self.builtin = builtin
        self.args = args
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        do {
            try builtin.run(NativeCall(input: input, args: args, env: env, ctx: ctx, node: self), k)
        } catch let error as JQRuntimeError where error.range == nil {
            throw error.located(range)
        }
    }

    override func paths(_ input: PathValue, _ env: Env?, _ ctx: Context, _ k: PathEmit) throws {
        if let pathRun = builtin.paths {
            do {
                try pathRun(NativeCall(input: input.value, args: args, env: env, ctx: ctx, node: self), input, k)
            } catch let error as JQRuntimeError where error.range == nil {
                throw error.located(range)
            }
            return
        }
        try super.paths(input, env, ctx, k)
    }

    override func evalInPlace(_ value: inout JSON, _ env: Env?, _ ctx: Context) throws -> InPlaceResult {
        guard let inPlace = builtin.inPlace else { return .unsupported }
        return try inPlace(NativeCall(input: .null, args: args, env: env, ctx: ctx, node: self), &value)
    }
}

// MARK: - Assignment

/// `=`, `|=`, `+=`, `-=`, `*=`, `/=`, `%=`, `//=` with jq 1.7.1 semantics:
/// paths come from the original input, `|=` keeps the first output of the
/// update and deletes paths whose update is empty.
final class AssignNode: Node {
    let op: AssignOperator
    let lhs: Node
    let rhs: Node

    init(op: AssignOperator, lhs: Node, rhs: Node, range: SourceRange) {
        self.op = op
        self.lhs = lhs
        self.rhs = rhs
        super.init(range: range)
    }

    override func eval(_ input: JSON, _ env: Env?, _ ctx: Context, _ k: Emit) throws {
        switch op {
        case .update:
            var value = input
            try update(&value, env, ctx) { v, scope in
                try self.rhs.firstOutput(v, scope, ctx)
            }
            try k(value)
        case .assign:
            try rhs.eval(input, env, ctx) { replacement in
                var value = input
                let paths = try self.collectPaths(value, env, ctx)
                for p in paths {
                    try ctx.tick()
                    do {
                        try Ops.setPath(&value, p[...], replacement)
                    } catch let error as JQRuntimeError {
                        throw error.located(self.range, subject: self.lhs.range)
                    }
                }
                try k(value)
            }
        default:
            try rhs.eval(input, env, ctx) { operand in
                var value = input
                try self.applyArithmetic(&value, operand, env, ctx)
                try k(value)
            }
        }
    }

    override func evalInPlace(_ value: inout JSON, _ env: Env?, _ ctx: Context) throws -> InPlaceResult {
        switch op {
        case .update:
            try update(&value, env, ctx) { v, scope in
                try self.rhs.firstOutput(v, scope, ctx)
            }
            return .single
        case .assign:
            let replacements = try rhs.collect(value, env, ctx)
            if replacements.count == 1 {
                let paths = try collectPaths(value, env, ctx)
                for p in paths {
                    try ctx.tick()
                    do {
                        try Ops.setPath(&value, p[...], replacements[0])
                    } catch let error as JQRuntimeError {
                        throw error.located(range, subject: lhs.range)
                    }
                }
                return .single
            }
            var outs: [JSON] = []
            for r in replacements {
                var copy = value
                for p in try collectPaths(copy, env, ctx) {
                    try Ops.setPath(&copy, p[...], r)
                }
                outs.append(copy)
            }
            return .outputs(outs)
        default:
            let operands = try rhs.collect(value, env, ctx)
            if operands.count == 1 {
                try applyArithmetic(&value, operands[0], env, ctx)
                return .single
            }
            var outs: [JSON] = []
            for operand in operands {
                var copy = value
                try applyArithmetic(&copy, operand, env, ctx)
                outs.append(copy)
            }
            return .outputs(outs)
        }
    }

    /// `lhs op= operand` as `lhs |= . op $operand`.
    private func applyArithmetic(_ value: inout JSON, _ operand: JSON, _ env: Env?, _ ctx: Context) throws {
        if op == .alternative {
            try update(&value, env, ctx) { v, _ in v.isTruthy ? v : operand }
            return
        }
        let arithmetic = op.arithmetic!
        try update(&value, env, ctx) { v, _ in
            do {
                if arithmetic == .add {
                    var current = v
                    try Ops.addInPlace(&current, operand)
                    return current
                }
                return try Ops.binary(arithmetic, v, operand, ctx: ctx)
            } catch let error as JQRuntimeError {
                throw error.located(self.range, subject: self.lhs.range)
            }
        }
    }

    private func collectPaths(_ value: JSON, _ env: Env?, _ ctx: Context) throws -> [[JSON]] {
        var paths: [[JSON]] = []
        try lhs.paths(PathValue(path: [], value: value), env, ctx) { pv in
            guard let p = pv.path else {
                throw invalidPathResult(pv.value).located(self.lhs.range)
            }
            paths.append(p)
        }
        return paths
    }

    /// The core of `_modify`: for each path of the original value, replace the
    /// value there with `transform`'s result, or delete it when there is none.
    private func update(_ value: inout JSON, _ env: Env?, _ ctx: Context,
                        _ transform: (JSON, Env?) throws -> JSON?) throws {
        let paths = try collectPaths(value, env, ctx)
        var deletions: [JSON] = []
        for p in paths {
            try ctx.tick()
            let current: JSON
            do {
                current = try Ops.getPath(value, .array(p))
            } catch let error as JQRuntimeError {
                throw error.located(range, subject: lhs.range)
            }
            if let next = try transform(current, env) {
                do {
                    try Ops.setPath(&value, p[...], next)
                } catch let error as JQRuntimeError {
                    throw error.located(range, subject: lhs.range)
                }
            } else {
                deletions.append(.array(p))
            }
        }
        if !deletions.isEmpty {
            value = try Ops.deletePaths(value, .array(deletions))
        }
    }
}

extension Node {
    /// The first output, or nil when there is none. Like jq's
    /// `label $out | f | ., break $out`, this consumes one label number.
    func firstOutput(_ input: JSON, _ env: Env?, _ ctx: Context) throws -> JSON? {
        var result: JSON?
        _ = ctx.makeLabel()
        let stop = FirstOutputStop()
        do {
            try eval(input, env, ctx) { v in
                result = v
                throw stop
            }
        } catch let s as FirstOutputStop where s === stop {
        }
        return result
    }

    /// Emits outputs until `stop` is thrown by the continuation, as jq's
    /// label-based builtins do.
    func emitUntilStopped(_ input: JSON, _ env: Env?, _ ctx: Context, _ stop: FirstOutputStop, _ k: Emit) throws {
        do {
            try eval(input, env, ctx, k)
        } catch let s as FirstOutputStop where s === stop {
        }
    }
}

final class FirstOutputStop: ControlFlowStop {}
