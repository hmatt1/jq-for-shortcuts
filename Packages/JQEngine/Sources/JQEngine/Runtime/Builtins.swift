import Foundation

/// The arguments of a native builtin call.
struct NativeCall {
    let input: JSON
    let args: [Node]
    let env: Env?
    let ctx: Context
    let node: Node

    /// Evaluates argument `i` against `input`.
    @inline(__always)
    func eval(_ i: Int, _ input: JSON, _ k: Emit) throws {
        try args[i].eval(input, env, ctx, k)
    }

    func collect(_ i: Int, _ input: JSON) throws -> [JSON] {
        try args[i].collect(input, env, ctx)
    }

    /// Evaluates every argument against the call's input, as jq does for
    /// builtins written in C: the last argument is the outermost loop.
    func cartesian(_ body: ([JSON]) throws -> Void) throws {
        if args.isEmpty {
            try body([])
            return
        }
        var values = [JSON](repeating: .null, count: args.count)
        func loop(_ i: Int) throws {
            if i < 0 {
                try body(values)
                return
            }
            try args[i].eval(input, env, ctx) { v in
                values[i] = v
                try loop(i - 1)
            }
        }
        try loop(args.count - 1)
    }
}

/// A builtin implemented in Swift.
struct NativeBuiltin {
    let name: String
    let arity: Int
    let run: (NativeCall, Emit) throws -> Void
    var paths: ((NativeCall, PathValue, PathEmit) throws -> Void)?
    var inPlace: ((NativeCall, inout JSON) throws -> InPlaceResult)?

    var key: String { "\(name)/\(arity)" }
}

enum Builtins {
    /// Every native builtin, keyed by "name/arity".
    static let table: [String: NativeBuiltin] = {
        var t: [String: NativeBuiltin] = [:]
        func add(_ b: NativeBuiltin) { t[b.key] = b }
        for b in core() + strings() + collections() + paths() + iteration() + math() + Regex.builtins() + Dates.builtins() {
            add(b)
        }
        return t
    }()

    /// jq builtins this engine removes because they read files or the
    /// environment (design requirement R4.7).
    static let disabled: Set<String> = [
        "input/0", "inputs/0", "input_filename/0", "env/0",
        "get_search_list/0", "get_prog_origin/0", "get_jq_origin/0", "modulemeta/0"
    ]

    /// Formats a constant for compile-time object-key errors.
    static func describeForError(_ value: JSON) -> String {
        Ops.describe(value)
    }

    // MARK: Helpers

    /// A builtin that maps the input to one value.
    static func unary(_ name: String, _ f: @escaping (JSON, Context) throws -> JSON) -> NativeBuiltin {
        NativeBuiltin(name: name, arity: 0, run: { call, k in
            try k(try f(call.input, call.ctx))
        })
    }

    /// A C-style builtin: arguments are evaluated as values (last outermost).
    static func valued(_ name: String, _ arity: Int, _ f: @escaping (JSON, [JSON], Context) throws -> JSON) -> NativeBuiltin {
        NativeBuiltin(name: name, arity: arity, run: { call, k in
            try call.cartesian { values in
                try k(try f(call.input, values, call.ctx))
            }
        })
    }

    static func requireString(_ v: JSON, _ message: String) throws -> String {
        guard case .string(let s) = v else { throw JQRuntimeError(message) }
        return s
    }

    // MARK: Core

    static func core() -> [NativeBuiltin] {
        var list: [NativeBuiltin] = []
        list.append(NativeBuiltin(name: "empty", arity: 0, run: { _, _ in }, paths: { _, _, _ in }))
        list.append(unary("not") { v, _ in .bool(!v.isTruthy) })
        list.append(NativeBuiltin(name: "error", arity: 0, run: { call, _ in
            throw JQRuntimeError(value: call.input, kind: .custom)
        }, paths: { call, _, _ in
            throw JQRuntimeError(value: call.input, kind: .custom)
        }))
        list.append(NativeBuiltin(name: "path", arity: 1, run: { call, k in
            try call.args[0].paths(PathValue(path: [], value: call.input), call.env, call.ctx) { pv in
                guard let p = pv.path else {
                    throw invalidPathResult(pv.value)
                }
                try k(.array(p))
            }
        }))
        list.append(unary("type") { v, _ in .string(v.typeName) })
        list.append(unary("length") { v, _ in try Ops.length(v) })
        list.append(unary("utf8bytelength") { v, _ in
            guard case .string(let s) = v else { throw Ops.typeError(v, "only strings have UTF-8 byte length") }
            return .number(s.utf8.count)
        })
        list.append(unary("infinite") { _, _ in .number(.infinity) })
        list.append(unary("nan") { _, _ in .number(.nan) })
        list.append(unary("isinfinite") { v, _ in
            if case .number(let n) = v { return .bool(n.value.isInfinite) }
            return .false
        })
        list.append(unary("isnan") { v, _ in
            if case .number(let n) = v { return .bool(n.value.isNaN) }
            return .false
        })
        list.append(unary("isnormal") { v, _ in
            if case .number(let n) = v { return .bool(n.value.isNormal) }
            return .false
        })
        list.append(unary("tostring") { v, _ in .string(Ops.toString(v)) })
        list.append(unary("tojson") { v, _ in .string(JSONWriter.string(v)) })
        list.append(unary("fromjson") { v, _ in
            guard case .string(let s) = v else { throw Ops.typeError(v, "only strings can be parsed") }
            do {
                return try JSONParser.parseSingle(s)
            } catch let error as JSONParseError {
                throw JQRuntimeError(error.message)
            }
        })
        list.append(unary("tonumber") { v, _ in try Ops.toNumber(v) })
        list.append(unary("keys") { v, _ in try Ops.keys(v, sorted: true) })
        list.append(unary("keys_unsorted") { v, _ in try Ops.keys(v, sorted: false) })
        list.append(valued("has", 1) { v, a, _ in .bool(try Ops.has(v, a[0])) })
        list.append(valued("contains", 1) { v, a, _ in
            guard v.kind == a[0].kind else {
                throw Ops.typeError2(v, a[0], "cannot have their containment checked")
            }
            return .bool(Ops.contains(v, a[0]))
        })
        list.append(NativeBuiltin(name: "debug", arity: 0, run: { call, k in
            let message = JSONWriter.string(.array([.string("DEBUG:"), call.input]))
            call.ctx.emit(.debug(message))
            try k(call.input)
        }, paths: { call, input, k in
            let message = JSONWriter.string(.array([.string("DEBUG:"), input.value]))
            call.ctx.emit(.debug(message))
            try k(input)
        }))
        list.append(NativeBuiltin(name: "stderr", arity: 0, run: { call, k in
            call.ctx.emit(.stderr(Ops.toString(call.input)))
            try k(call.input)
        }))
        list.append(NativeBuiltin(name: "halt", arity: 0, run: { _, _ in
            throw JQHalt(exitCode: 0, message: nil)
        }))
        list.append(NativeBuiltin(name: "halt_error", arity: 1, run: { call, _ in
            try call.cartesian { values in
                guard case .number(let n) = values[0] else {
                    throw Ops.typeError(call.input, "halt_error/1: number required")
                }
                throw JQHalt(exitCode: Int(n.value), message: call.input)
            }
        }))
        list.append(unary("input_line_number") { _, _ in .number(0) })
        list.append(valued("format", 1) { v, a, _ in
            guard case .string(let name) = a[0] else { throw Ops.typeError(a[0], "is not a valid format") }
            return .string(try Formats.apply(name, to: v))
        })
        list.append(unary("builtins") { _, _ in
            .array(Compiler.builtinNames.map { .string($0) })
        })
        return list
    }

    // MARK: Strings

    static func strings() -> [NativeBuiltin] {
        var list: [NativeBuiltin] = []
        list.append(valued("startswith", 1) { v, a, _ in
            guard case .string(let s) = v, case .string(let p) = a[0] else {
                throw JQRuntimeError("startswith() requires string inputs")
            }
            return .bool(ByteString.hasPrefix(s, p))
        })
        list.append(valued("endswith", 1) { v, a, _ in
            guard case .string(let s) = v, case .string(let p) = a[0] else {
                throw JQRuntimeError("endswith() requires string inputs")
            }
            return .bool(ByteString.hasSuffix(s, p))
        })
        list.append(valued("ltrimstr", 1) { v, a, _ in
            guard case .string(let s) = v, case .string(let p) = a[0], ByteString.hasPrefix(s, p) else { return v }
            return .string(String(decoding: Array(s.utf8).dropFirst(p.utf8.count), as: UTF8.self))
        })
        list.append(valued("rtrimstr", 1) { v, a, _ in
            guard case .string(let s) = v, case .string(let p) = a[0], ByteString.hasSuffix(s, p) else { return v }
            return .string(String(decoding: Array(s.utf8).dropLast(p.utf8.count), as: UTF8.self))
        })
        list.append(valued("split", 1) { v, a, _ in
            guard case .string(let s) = v, case .string(let sep) = a[0] else {
                throw JQRuntimeError("split input and separator must be strings")
            }
            return Ops.splitString(s, by: sep)
        })
        list.append(valued("_strindices", 1) { v, a, _ in
            guard case .string(let s) = v, case .string(let n) = a[0] else {
                throw JQRuntimeError("Cannot determine indices of \(v.typeName) in \(a[0].typeName)")
            }
            return Ops.stringIndexes(s, n)
        })
        list.append(unary("explode") { v, _ in
            guard case .string(let s) = v else { throw JQRuntimeError("explode input must be a string") }
            return .array(s.unicodeScalars.map { .number(Int($0.value)) })
        })
        list.append(unary("implode") { v, ctx in
            guard case .array(let codes) = v else { throw JQRuntimeError("implode input must be an array") }
            var scalars = String.UnicodeScalarView()
            for c in codes {
                guard case .number(let n) = c, !n.value.isNaN else {
                    throw Ops.typeError(c, "can't be imploded, unicode codepoint needs to be numeric")
                }
                let i = Ops.clampToInt32(n.value)
                let scalar = Unicode.Scalar(UInt32(clamping: max(i, 0))).flatMap { (i < 0 || i > 0x10FFFF) ? nil : $0 }
                scalars.append(scalar ?? "\u{FFFD}")
            }
            return .string(String(scalars))
        })
        list.append(unary("ascii_downcase") { v, _ in
            guard case .string(let s) = v else { throw JQRuntimeError("explode input must be a string") }
            return .string(String(decoding: s.utf8.map { ($0 >= 65 && $0 <= 90) ? $0 + 32 : $0 }, as: UTF8.self))
        })
        list.append(unary("ascii_upcase") { v, _ in
            guard case .string(let s) = v else { throw JQRuntimeError("explode input must be a string") }
            return .string(String(decoding: s.utf8.map { ($0 >= 97 && $0 <= 122) ? $0 - 32 : $0 }, as: UTF8.self))
        })
        // join/1, with the semantics of jq 1.7.1's definition but linear time.
        list.append(NativeBuiltin(name: "join", arity: 1, run: { call, k in
            try call.eval(0, call.input) { separator in
                var acc: JSON = .null
                let items: [JSON]
                switch call.input {
                case .array(let a): items = a
                case .object(let o): items = o.values
                default:
                    throw JQRuntimeError("Cannot iterate over \(Ops.describe(call.input))", kind: .iterate(type: call.input.typeName))
                }
                for item in items {
                    try call.ctx.tick()
                    if case .null = acc {
                        acc = .string("")
                    } else {
                        try Ops.addInPlace(&acc, separator)
                    }
                    let piece: JSON
                    switch item {
                    case .bool, .number: piece = .string(Ops.toString(item))
                    case .null: piece = .string("")
                    default: piece = item
                    }
                    try Ops.addInPlace(&acc, piece)
                }
                if case .null = acc { acc = .string("") }
                try k(acc)
            }
        }))
        return list
    }

    // MARK: Collections

    static func collections() -> [NativeBuiltin] {
        var list: [NativeBuiltin] = []
        list.append(unary("sort") { v, _ in
            guard case .array(let a) = v else { throw Ops.typeError(v, "cannot be sorted, as it is not an array") }
            return .array(Ops.sortedBy(a, keys: a))
        })
        list.append(valued("_sort_by_impl", 1) { v, a, _ in
            guard case .array(let values) = v, case .array(let keys) = a[0], values.count == keys.count else {
                throw Ops.typeError2(v, a[0], "cannot be sorted, as they are not both arrays")
            }
            return .array(Ops.sortedBy(values, keys: keys))
        })
        list.append(valued("_group_by_impl", 1) { v, a, _ in
            guard case .array(let values) = v, case .array(let keys) = a[0], values.count == keys.count else {
                throw Ops.typeError2(v, a[0], "cannot be sorted, as they are not both arrays")
            }
            return .array(Ops.groupedBy(values, keys: keys))
        })
        list.append(unary("min") { v, _ in try Ops.minMaxBy(v, v, isMin: true) })
        list.append(unary("max") { v, _ in try Ops.minMaxBy(v, v, isMin: false) })
        list.append(valued("_min_by_impl", 1) { v, a, _ in try Ops.minMaxBy(v, a[0], isMin: true) })
        list.append(valued("_max_by_impl", 1) { v, a, _ in try Ops.minMaxBy(v, a[0], isMin: false) })
        // _nwise/1 without recursion: chunks of n.
        list.append(NativeBuiltin(name: "_nwise", arity: 1, run: { call, k in
            try call.eval(0, call.input) { nValue in
                var current = call.input
                while true {
                    try call.ctx.tick()
                    let len = try Ops.length(current)
                    if JSON.compare(len, nValue) <= 0 {
                        try k(current)
                        return
                    }
                    try k(try Ops.index(current, Ops.sliceKey(.number(0), nValue)))
                    current = try Ops.index(current, Ops.sliceKey(nValue, .null))
                }
            }
        }))
        return list
    }

    // MARK: Paths

    static func paths() -> [NativeBuiltin] {
        var list: [NativeBuiltin] = []
        list.append(NativeBuiltin(name: "getpath", arity: 1, run: { call, k in
            try call.eval(0, call.input) { p in
                do {
                    try k(try Ops.getPath(call.input, p))
                } catch let error as JQRuntimeError {
                    throw error
                }
            }
        }, paths: { call, input, k in
            try call.eval(0, input.value) { p in
                guard let base = input.path else {
                    throw invalidPathResult(input.value)
                }
                let value = try Ops.getPath(input.value, p)
                guard case .array(let components) = p else {
                    throw JQRuntimeError("Path must be specified as an array")
                }
                try k(PathValue(path: base + components, value: value))
            }
        }))
        list.append(NativeBuiltin(name: "setpath", arity: 2, run: { call, k in
            try call.cartesian { values in
                try k(try Ops.setPath(call.input, values[0], values[1]))
            }
        }, inPlace: { call, value in
            var combos: [[JSON]] = []
            try NativeCall(input: value, args: call.args, env: call.env, ctx: call.ctx, node: call.node).cartesian { combos.append($0) }
            if combos.count == 1 {
                guard case .array(let p) = combos[0][0] else {
                    throw JQRuntimeError("Path must be specified as an array")
                }
                try Ops.setPath(&value, p[...], combos[0][1])
                return .single
            }
            return .outputs(try combos.map { try Ops.setPath(value, $0[0], $0[1]) })
        }))
        list.append(valued("delpaths", 1) { v, a, _ in try Ops.deletePaths(v, a[0]) })
        list.append(NativeBuiltin(name: "paths", arity: 0, run: { call, k in
            try walkPaths(call.input, call.ctx) { path, _ in
                if !path.isEmpty { try k(.array(path)) }
            }
        }))
        list.append(NativeBuiltin(name: "paths", arity: 1, run: { call, k in
            try walkPaths(call.input, call.ctx) { path, value in
                try call.eval(0, value) { keep in
                    if keep.isTruthy && !path.isEmpty { try k(.array(path)) }
                }
            }
        }))
        return list
    }

    /// Visits every (path, value) pair depth first, root first.
    static func walkPaths(_ root: JSON, _ ctx: Context, _ visit: ([JSON], JSON) throws -> Void) throws {
        var stack: [([JSON], JSON)] = [([], root)]
        while let (path, value) = stack.popLast() {
            try ctx.tick()
            try visit(path, value)
            switch value {
            case .array(let a):
                for (i, item) in a.enumerated().reversed() { stack.append((path + [.number(i)], item)) }
            case .object(let o):
                for (key, item) in o.entries.reversed() { stack.append((path + [.string(key)], item)) }
            default:
                break
            }
        }
    }

    // MARK: Iteration

    static func iteration() -> [NativeBuiltin] {
        var list: [NativeBuiltin] = []

        // range/2: from outer, upto inner; counts up by one.
        list.append(NativeBuiltin(name: "range", arity: 2, run: { call, k in
            try call.eval(0, call.input) { from in
                try call.eval(1, call.input) { upto in
                    guard case .number(let f) = from, case .number(let u) = upto else {
                        throw JQRuntimeError("Range bounds must be numeric")
                    }
                    var current = f.value
                    if current < u.value {
                        try k(from)
                        current += 1
                    }
                    while current < u.value {
                        try call.ctx.tick()
                        try k(.number(current))
                        current += 1
                    }
                }
            }
        }))

        // range/3: init, upto, by as nested `$` parameters.
        list.append(NativeBuiltin(name: "range", arity: 3, run: { call, k in
            try call.eval(0, call.input) { initial in
                try call.eval(1, call.input) { upto in
                    try call.eval(2, call.input) { by in
                        let byZero = JSON.compare(by, .number(0))
                        if byZero == 0 { return }
                        var current = initial
                        while true {
                            try call.ctx.tick()
                            let c = JSON.compare(current, upto)
                            if byZero > 0 ? !(c < 0) : !(c > 0) { return }
                            try k(current)
                            current = try Ops.add(current, by)
                        }
                    }
                }
            }
        }))

        list.append(NativeBuiltin(name: "repeat", arity: 1, run: { call, k in
            while true {
                try call.ctx.tick()
                try call.eval(0, call.input, k)
            }
        }))

        list.append(NativeBuiltin(name: "while", arity: 2, run: { call, k in
            try whileLoop(call, call.input, k)
        }))

        list.append(NativeBuiltin(name: "until", arity: 2, run: { call, k in
            try untilLoop(call, call.input, k)
        }))

        list.append(NativeBuiltin(name: "limit", arity: 2, run: { call, k in
            try call.eval(0, call.input) { nValue in
                let n = nValue.doubleValue ?? 0
                let sign = JSON.compare(nValue, .number(0))
                if sign <= 0 {
                    if sign < 0 { try call.eval(1, call.input, k) }
                    return
                }
                _ = call.ctx.makeLabel()
                var count = 0.0
                let stop = FirstOutputStop()
                try call.args[1].emitUntilStopped(call.input, call.env, call.ctx, stop) { v in
                    count += 1
                    try k(v)
                    if count >= n { throw stop }
                }
            }
        }, paths: { call, input, k in
            try call.eval(0, input.value) { nValue in
                let n = nValue.doubleValue ?? 0
                let sign = JSON.compare(nValue, .number(0))
                if sign <= 0 {
                    if sign < 0 { try call.args[1].paths(input, call.env, call.ctx, k) }
                    return
                }
                _ = call.ctx.makeLabel()
                var count = 0.0
                let stop = FirstOutputStop()
                do {
                    try call.args[1].paths(input, call.env, call.ctx) { pv in
                        count += 1
                        try k(pv)
                        if count >= n { throw stop }
                    }
                } catch let s as FirstOutputStop where s === stop {
                }
            }
        }))

        list.append(NativeBuiltin(name: "first", arity: 1, run: { call, k in
            _ = call.ctx.makeLabel()
            let stop = FirstOutputStop()
            try call.args[0].emitUntilStopped(call.input, call.env, call.ctx, stop) { v in
                try k(v)
                throw stop
            }
        }, paths: { call, input, k in
            _ = call.ctx.makeLabel()
            let stop = FirstOutputStop()
            do {
                try call.args[0].paths(input, call.env, call.ctx) { pv in
                    try k(pv)
                    throw stop
                }
            } catch let s as FirstOutputStop where s === stop {
            }
        }))

        // isempty(g): first((g|false), true)
        list.append(NativeBuiltin(name: "isempty", arity: 1, run: { call, k in
            _ = call.ctx.makeLabel()
            let stop = FirstOutputStop()
            var produced = false
            try call.args[0].emitUntilStopped(call.input, call.env, call.ctx, stop) { _ in
                produced = true
                try k(.false)
                throw stop
            }
            if !produced { try k(.true) }
        }))

        // recurse(f): the input, then recurse(f) on each output of f.
        list.append(NativeBuiltin(name: "recurse", arity: 1, run: { call, k in
            try recurse(call, call.input, cond: nil, k)
        }, paths: { call, input, k in
            try recursePaths(call, input, cond: nil, k)
        }))
        list.append(NativeBuiltin(name: "recurse", arity: 2, run: { call, k in
            try recurse(call, call.input, cond: 1, k)
        }, paths: { call, input, k in
            try recursePaths(call, input, cond: 1, k)
        }))
        list.append(NativeBuiltin(name: "recurse", arity: 0, run: { call, k in
            try RecurseAllNode(range: call.node.range).eval(call.input, call.env, call.ctx, k)
        }, paths: { call, input, k in
            try RecurseAllNode.walkPaths(input, call.ctx, k)
        }))
        return list
    }


    /// `def _while: if cond then ., (update | _while) else empty end;`
    /// Iterative while every step has a single condition and update output.
    static func whileLoop(_ call: NativeCall, _ start: JSON, _ k: Emit) throws {
        var current = start
        while true {
            try call.ctx.tick()
            let conds = try call.collect(0, current)
            if conds.count != 1 {
                for c in conds where c.isTruthy {
                    try k(current)
                    try call.eval(1, current) { next in try whileLoop(call, next, k) }
                }
                return
            }
            guard conds[0].isTruthy else { return }
            try k(current)
            let nexts = try call.collect(1, current)
            if nexts.count != 1 {
                try call.ctx.checkStack()
                for n in nexts { try whileLoop(call, n, k) }
                return
            }
            current = nexts[0]
        }
    }

    /// `def _until: if cond then . else (next|_until) end;`
    static func untilLoop(_ call: NativeCall, _ start: JSON, _ k: Emit) throws {
        var current = start
        while true {
            try call.ctx.tick()
            let conds = try call.collect(0, current)
            if conds.count != 1 {
                try call.ctx.checkStack()
                for c in conds {
                    if c.isTruthy {
                        try k(current)
                    } else {
                        try call.eval(1, current) { next in try untilLoop(call, next, k) }
                    }
                }
                return
            }
            if conds[0].isTruthy {
                try k(current)
                return
            }
            let nexts = try call.collect(1, current)
            if nexts.count != 1 {
                try call.ctx.checkStack()
                for n in nexts { try untilLoop(call, n, k) }
                return
            }
            current = nexts[0]
        }
    }

    /// Depth-first `recurse(f)` / `recurse(f; cond)` with an explicit stack.
    static func recurse(_ call: NativeCall, _ root: JSON, cond: Int?, _ k: Emit) throws {
        var stack: [JSON] = [root]
        while let value = stack.popLast() {
            try call.ctx.tick()
            try k(value)
            var children: [JSON] = []
            try call.eval(0, value) { child in
                if let cond {
                    try call.eval(cond, child) { keep in
                        if keep.isTruthy { children.append(child) }
                    }
                } else {
                    children.append(child)
                }
            }
            stack.append(contentsOf: children.reversed())
        }
    }

    static func recursePaths(_ call: NativeCall, _ root: PathValue, cond: Int?, _ k: PathEmit) throws {
        var stack: [PathValue] = [root]
        while let pv = stack.popLast() {
            try call.ctx.tick()
            try k(pv)
            var children: [PathValue] = []
            try call.args[0].paths(pv, call.env, call.ctx) { child in
                if let cond {
                    try call.eval(cond, child.value) { keep in
                        if keep.isTruthy { children.append(child) }
                    }
                } else {
                    children.append(child)
                }
            }
            stack.append(contentsOf: children.reversed())
        }
    }

    // MARK: Math

    static func math() -> [NativeBuiltin] {
        var list: [NativeBuiltin] = []
        func number(_ v: JSON) throws -> Double {
            guard case .number(let n) = v else { throw Ops.typeError(v, "number required") }
            return n.value
        }
        let oneArg: [(String, (Double) -> Double)] = [
            ("floor", { Foundation.floor($0) }), ("sqrt", { Foundation.sqrt($0) }), ("ceil", { Foundation.ceil($0) }),
            ("round", { Foundation.round($0) }), ("trunc", { Foundation.trunc($0) }), ("fabs", { Foundation.fabs($0) }),
            ("nearbyint", { Foundation.nearbyint($0) }), ("rint", { Foundation.rint($0) }),
            ("exp", { Foundation.exp($0) }), ("exp2", { Foundation.exp2($0) }), ("exp10", { Foundation.pow(10, $0) }),
            ("pow10", { Foundation.pow(10, $0) }), ("expm1", { Foundation.expm1($0) }),
            ("log", { Foundation.log($0) }), ("log2", { Foundation.log2($0) }), ("log10", { Foundation.log10($0) }),
            ("log1p", { Foundation.log1p($0) }), ("logb", { Foundation.logb($0) }), ("cbrt", { Foundation.cbrt($0) }),
            ("sin", { Foundation.sin($0) }), ("cos", { Foundation.cos($0) }), ("tan", { Foundation.tan($0) }),
            ("asin", { Foundation.asin($0) }), ("acos", { Foundation.acos($0) }), ("atan", { Foundation.atan($0) }),
            ("sinh", { Foundation.sinh($0) }), ("cosh", { Foundation.cosh($0) }), ("tanh", { Foundation.tanh($0) }),
            ("asinh", { Foundation.asinh($0) }), ("acosh", { Foundation.acosh($0) }), ("atanh", { Foundation.atanh($0) }),
            ("gamma", { Foundation.tgamma($0) }), ("tgamma", { Foundation.tgamma($0) }), ("lgamma", { Foundation.lgamma($0) }),
            ("erf", { Foundation.erf($0) }), ("erfc", { Foundation.erfc($0) }),
            ("j0", { Foundation.j0($0) }), ("j1", { Foundation.j1($0) }), ("y0", { Foundation.y0($0) }), ("y1", { Foundation.y1($0) }),
            ("significand", { x in
                if x == 0 || !x.isFinite { return x }
                var e: Int32 = 0
                return 2 * Foundation.frexp(x, &e)
            })
        ]
        for (name, f) in oneArg {
            list.append(unary(name) { v, _ in .number(f(try number(v))) })
        }
        let twoArgs: [(String, (Double, Double) -> Double)] = [
            ("pow", { Foundation.pow($0, $1) }), ("atan2", { Foundation.atan2($0, $1) }),
            ("fmod", { Foundation.fmod($0, $1) }), ("hypot", { Foundation.hypot($0, $1) }),
            ("fmin", { Foundation.fmin($0, $1) }), ("fmax", { Foundation.fmax($0, $1) }),
            ("fdim", { Foundation.fdim($0, $1) }), ("copysign", { Foundation.copysign($0, $1) }),
            ("nextafter", { Foundation.nextafter($0, $1) }), ("nexttoward", { Foundation.nextafter($0, $1) }),
            ("remainder", { Foundation.remainder($0, $1) }), ("drem", { Foundation.remainder($0, $1) }),
            ("ldexp", { Foundation.scalbn($0, Int(Ops.clampToInt32($1))) }),
            ("scalb", { $0 * Foundation.pow(2, $1) }),
            ("scalbln", { Foundation.scalbn($0, Int(Ops.clampToInt32($1))) }),
            ("jn", { Foundation.jn(Int32(Ops.clampToInt32($0)), $1) }),
            ("yn", { Foundation.yn(Int32(Ops.clampToInt32($0)), $1) })
        ]
        for (name, f) in twoArgs {
            list.append(valued(name, 2) { _, a, _ in .number(f(try number(a[0]), try number(a[1]))) })
        }
        list.append(valued("fma", 3) { _, a, _ in
            .number(Foundation.fma(try number(a[0]), try number(a[1]), try number(a[2])))
        })
        list.append(unary("frexp") { v, _ in
            var e: Int32 = 0
            let m = Foundation.frexp(try number(v), &e)
            return .array([.number(m), .number(Int(e))])
        })
        list.append(unary("modf") { v, _ in
            let x = try number(v)
            let (whole, fraction) = Foundation.modf(x)
            return .array([.number(fraction), .number(whole)])
        })
        list.append(unary("lgamma_r") { v, _ in
            let (value, sign) = Foundation.lgamma(try number(v))
            return .array([.number(value), .number(sign)])
        })
        return list
    }
}

extension JSON {
    var isBool: Bool {
        if case .bool = self { return true }
        return false
    }
}
