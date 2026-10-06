import Foundation

/// Regular expressions for `test`, `match`, `capture`, `scan`, `splits`,
/// `sub` and `gsub`, on ICU (NSRegularExpression). Match objects follow jq
/// 1.7.1's Oniguruma output: codepoint offsets, the same key order, and the
/// same shape for non-participating and zero-width captures.
enum Regex {
    struct Flags {
        var global = false
        var notEmpty = false
        var options: NSRegularExpression.Options = []
    }

    static func parseFlags(_ mode: JSON) throws -> Flags {
        var flags = Flags()
        switch mode {
        case .null:
            break
        case .string(let text):
            for c in text {
                switch c {
                case "g": flags.global = true
                case "i": flags.options.insert(.caseInsensitive)
                case "x": flags.options.insert(.allowCommentsAndWhitespace)
                case "m", "p": flags.options.insert(.dotMatchesLineSeparators)
                case "s": break   // ICU's default: ^ and $ anchor to the whole string.
                case "l": break   // Longest match has no ICU equivalent.
                case "n": flags.notEmpty = true
                default:
                    throw JQRuntimeError("\(text) is not a valid modifier string")
                }
            }
        default:
            throw Ops.typeError(mode, "is not a string")
        }
        return flags
    }

    // MARK: Compilation cache

    private struct CacheKey: Hashable {
        let pattern: String
        let options: UInt
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [CacheKey: (NSRegularExpression, [Int: String])] = [:]

    static func compile(_ pattern: String, _ options: NSRegularExpression.Options) throws -> (NSRegularExpression, [Int: String]) {
        let key = CacheKey(pattern: pattern, options: options.rawValue)
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        let regex: NSRegularExpression
        do {
            // ICU rejects an empty pattern; an empty group matches the same way.
            regex = try NSRegularExpression(pattern: pattern.isEmpty ? "(?:)" : pattern, options: options)
        } catch {
            throw JQRuntimeError("Regex failure: \(pattern) is not a valid regular expression")
        }
        let entry = (regex, groupNames(pattern))
        cacheLock.lock()
        if cache.count > 64 { cache.removeAll() }
        cache[key] = entry
        cacheLock.unlock()
        return entry
    }

    /// Capture group index -> name, by scanning the pattern for `(?<name>`
    /// and `(?'name'` groups. Escapes and character classes are skipped.
    static func groupNames(_ pattern: String) -> [Int: String] {
        let chars = Array(pattern)
        var names: [Int: String] = [:]
        var group = 0
        var i = 0
        var inClass = false
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i += 2
                continue
            }
            if inClass {
                if c == "]" { inClass = false }
                i += 1
                continue
            }
            if c == "[" {
                inClass = true
                i += 1
                if i < chars.count, chars[i] == "^" { i += 1 }
                if i < chars.count, chars[i] == "]" { i += 1 }
                continue
            }
            if c == "(" {
                if i + 1 < chars.count, chars[i + 1] == "?" {
                    if i + 2 < chars.count, chars[i + 2] == "<" || chars[i + 2] == "'",
                       i + 3 < chars.count, chars[i + 3] != "=", chars[i + 3] != "!" {
                        let close: Character = chars[i + 2] == "<" ? ">" : "'"
                        var j = i + 3
                        var name = ""
                        while j < chars.count, chars[j] != close {
                            name.append(chars[j])
                            j += 1
                        }
                        group += 1
                        names[group] = name
                        i = j
                    } else if i + 2 < chars.count, chars[i + 2] == "P", i + 3 < chars.count, chars[i + 3] == "<" {
                        var j = i + 4
                        var name = ""
                        while j < chars.count, chars[j] != ">" {
                            name.append(chars[j])
                            j += 1
                        }
                        group += 1
                        names[group] = name
                        i = j
                    }
                } else {
                    group += 1
                }
            }
            i += 1
        }
        return names
    }

    // MARK: Matching

    /// One match: codepoint ranges of the whole match and each group.
    struct Match {
        var offset: Int
        var length: Int
        var string: String
        /// nil for a group that did not participate.
        var groups: [(offset: Int, length: Int, string: String)?]
    }

    /// Converts UTF-16 offsets to codepoint offsets.
    struct OffsetMap {
        let isASCII: Bool
        let table: [Int]

        init(_ ns: NSString, _ s: String) {
            isASCII = s.utf8.count == s.utf16.count
            if isASCII {
                table = []
                return
            }
            var t = [Int](repeating: 0, count: ns.length + 1)
            var scalarIndex = 0
            var u = 0
            for scalar in s.unicodeScalars {
                let width = scalar.value > 0xFFFF ? 2 : 1
                for w in 0..<width { t[u + w] = scalarIndex }
                u += width
                scalarIndex += 1
            }
            t[ns.length] = scalarIndex
            table = t
        }

        @inline(__always)
        func codepoint(_ utf16: Int) -> Int {
            isASCII ? utf16 : table[utf16]
        }
    }

    static func matches(_ input: String, pattern: String, flags: Flags, ctx: Context, firstOnly: Bool) throws -> [Match] {
        let (regex, _) = try compile(pattern, flags.options)
        let ns = input as NSString
        let map = OffsetMap(ns, input)
        var result: [Match] = []
        let full = NSRange(location: 0, length: ns.length)
        var stopped = false
        // reportProgress calls the block during long matches too, so a
        // pattern that backtracks without end still stops at the timeout.
        regex.enumerateMatches(in: input, options: [.reportProgress], range: full) { found, _, stop in
            guard let found else {
                if (try? ctx.checkLimits()) == nil {
                    stop.pointee = true
                    stopped = true
                }
                return
            }
            if flags.notEmpty && found.range.length == 0 { return }
            let start = map.codepoint(found.range.location)
            let end = map.codepoint(found.range.location + found.range.length)
            var groups: [(offset: Int, length: Int, string: String)?] = []
            for g in 1..<max(found.numberOfRanges, 1) where found.numberOfRanges > 1 {
                let r = found.range(at: g)
                if r.location == NSNotFound {
                    groups.append(nil)
                } else {
                    let gs = map.codepoint(r.location)
                    let ge = map.codepoint(r.location + r.length)
                    groups.append((gs, ge - gs, ns.substring(with: r)))
                }
            }
            result.append(Match(offset: start, length: end - start, string: ns.substring(with: found.range), groups: groups))
            if firstOnly || !flags.global {
                stop.pointee = true
                stopped = true
            }
            if result.count & 0xFFF == 0, (try? ctx.checkLimits()) == nil {
                stop.pointee = true
                stopped = true
            }
        }
        _ = stopped
        try ctx.checkLimits()
        return result
    }

    /// The match object jq builds for one match.
    static func matchObject(_ m: Match, names: [Int: String]) -> JSON {
        var captures: [JSON] = []
        for (i, group) in m.groups.enumerated() {
            let name: JSON = names[i + 1].map { .string($0) } ?? .null
            var cap = JSONObject()
            if m.length == 0 {
                cap["offset"] = .number(m.offset)
                cap["string"] = .string("")
                cap["length"] = .number(0)
                cap["name"] = name
            } else if let g = group {
                if g.length == 0 {
                    cap["offset"] = .number(g.offset)
                    cap["string"] = .string("")
                    cap["length"] = .number(0)
                    cap["name"] = name
                } else {
                    cap["offset"] = .number(g.offset)
                    cap["length"] = .number(g.length)
                    cap["string"] = .string(g.string)
                    cap["name"] = name
                }
            } else {
                cap["offset"] = .number(-1)
                cap["string"] = .null
                cap["length"] = .number(0)
                cap["name"] = name
            }
            captures.append(.object(cap))
        }
        var object = JSONObject()
        object["offset"] = .number(m.offset)
        object["length"] = .number(m.length)
        object["string"] = .string(m.string)
        object["captures"] = .array(captures)
        return .object(object)
    }

    /// `_match_impl(re; mode; test)`.
    static func matchImpl(_ input: JSON, _ re: JSON, _ mode: JSON, _ test: JSON, _ ctx: Context) throws -> JSON {
        guard case .string(let s) = input else {
            throw Ops.typeError(input, "cannot be matched, as it is not a string")
        }
        guard case .string(let pattern) = re else {
            throw Ops.typeError(re, "is not a string")
        }
        let flags = try parseFlags(mode)
        let testMode = test == .true
        let found = try matches(s, pattern: pattern, flags: flags, ctx: ctx, firstOnly: testMode)
        if testMode { return .bool(!found.isEmpty) }
        let (_, names) = try compile(pattern, flags.options)
        return .array(found.map { matchObject($0, names: names) })
    }

    // MARK: Builtins

    static func builtins() -> [NativeBuiltin] {
        var list: [NativeBuiltin] = []
        list.append(Builtins.valued("_match_impl", 3) { input, a, ctx in
            try matchImpl(input, a[0], a[1], a[2], ctx)
        })

        // sub($re; s; $flags) with jq 1.7.1's semantics, in linear time.
        list.append(NativeBuiltin(name: "sub", arity: 3, run: { call, k in
            try call.eval(0, call.input) { re in
                try call.eval(2, call.input) { flagsValue in
                    try substitute(call, re: re, flagsValue: flagsValue, k)
                }
            }
        }))

        // splits($re; flags)
        list.append(NativeBuiltin(name: "splits", arity: 2, run: { call, k in
            try call.eval(0, call.input) { re in
                try call.eval(1, call.input) { flagsValue in
                    let mode = try Ops.add(.string("g"), flagsValue)
                    let found = try matchImpl(call.input, re, mode, .false, call.ctx)
                    guard case .string(let s) = call.input, case .array(let objects) = found else { return }
                    let scalars = Array(s.unicodeScalars)
                    var boundaries: [Int] = [0]
                    for object in objects {
                        guard case .object(let o) = object,
                              let offset = o["offset"]?.doubleValue, let length = o["length"]?.doubleValue else { continue }
                        boundaries.append(Int(offset))
                        boundaries.append(Int(offset + length))
                    }
                    boundaries.append(scalars.count)
                    var i = 0
                    while i + 1 < boundaries.count {
                        try call.ctx.tick()
                        try k(.string(slice(scalars, boundaries[i], boundaries[i + 1])))
                        i += 2
                    }
                }
            }
        }))
        return list
    }

    /// A codepoint slice with jq's clamping (`end < start` gives "").
    static func slice(_ scalars: [Unicode.Scalar], _ start: Int, _ end: Int) -> String {
        let s = max(0, min(start, scalars.count))
        let e = max(s, min(end, scalars.count))
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[s..<e])
        return String(view)
    }

    private static func substitute(_ call: NativeCall, re: JSON, flagsValue: JSON, _ k: Emit) throws {
        let input = call.input
        let found = try matchImpl(input, re, flagsValue, .false, call.ctx)
        guard case .string(let s) = input, case .array(let objects) = found else { return }
        let scalars = Array(s.unicodeScalars)
        var results: [JSON] = []
        var previous = 0
        for object in objects {
            try call.ctx.tick()
            guard case .object(let edit) = object,
                  let offset = edit["offset"]?.doubleValue, let length = edit["length"]?.doubleValue else { continue }
            let gap = JSON.string(slice(scalars, previous, Int(offset)))
            var captureObject = JSONObject()
            if case .array(let caps)? = edit["captures"] {
                for cap in caps {
                    guard case .object(let c) = cap, let name = c["name"], case .string(let n) = name else { continue }
                    captureObject.set(n, c["string"] ?? .null)
                }
            }
            let inserts = try call.collect(1, .object(captureObject))
            for (ix, insert) in inserts.enumerated() {
                let piece = try Ops.add(gap, insert)
                while results.count <= ix { results.append(.null) }
                results[ix] = try Ops.add(results[ix], piece)
            }
            previous = Int(offset + length)
        }
        let rest = JSON.string(slice(scalars, previous, scalars.count))
        var emitted = false
        for r in results {
            let out = try Ops.add(r, rest)
            if out.isTruthy {
                emitted = true
                try k(out)
            }
        }
        if !emitted {
            try k(input)
        }
    }
}
