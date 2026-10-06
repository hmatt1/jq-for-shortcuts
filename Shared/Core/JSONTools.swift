import Foundation
import JQEngine

/// The actions that are not a free-form filter: Validate JSON, Format JSON,
/// Get Value at Path, Set Value at Path and JSON to CSV. They read input with
/// the same parser and run paths on the same engine as Run JSON Filter
/// (R3.36), under the same limits.
enum JSONTools {
    struct Validation: Sendable, Equatable {
        var isValid: Bool
        /// 1-based; nil when valid.
        var line: Int?
        var column: Int?
        var message: String?
        var valueCount: Int
    }

    enum MissingValueBehavior: String, Sendable, CaseIterable {
        case stop
        case returnNothing
    }

    enum TableDelimiter: String, Sendable, CaseIterable {
        case comma
        case tab

        var fileExtension: String { self == .comma ? "csv" : "tsv" }
    }

    struct Settings: Sendable {
        var context: RunContext
        var timeout: Double = RunLimits.defaultTimeout
        var canRunInApp = false
    }

    // MARK: Validate JSON (R3.3, R5.8)

    static func validate(_ data: Data, settings: Settings) async throws -> Validation {
        try checkInput(data, settings)
        return try await EngineTask.run(settings) { checkpoint, _ in
            var count = 0
            do {
                try JSONParser.forEachValue(in: data, checkpoint: checkpoint) { _ in count += 1 }
            } catch let error as JSONParseError {
                let failure = FilterErrorMapper.input(error)
                if case .invalidInput(let line, let column, _) = failure {
                    return Validation(isValid: false, line: line, column: column, message: failure.message, valueCount: count)
                }
                return Validation(isValid: false, line: nil, column: nil, message: failure.message, valueCount: count)
            }
            if count == 0 {
                return Validation(isValid: false, line: nil, column: nil, message: FilterError.emptyInput.message, valueCount: 0)
            }
            return Validation(isValid: true, line: nil, column: nil, message: nil, valueCount: count)
        }
    }

    // MARK: Format JSON (R3.4)

    static func format(_ data: Data, pretty: Bool, sortKeys: Bool, settings: Settings) async throws -> String {
        try checkInput(data, settings)
        let options = JSONWriter.Options(indent: pretty ? 2 : nil, sortKeys: sortKeys)
        return try await EngineTask.run(settings) { checkpoint, _ in
            var blocks: [String] = []
            try JSONParser.forEachValue(in: data, checkpoint: checkpoint) { value in
                blocks.append(JSONWriter.string(value, options: options))
            }
            if blocks.isEmpty { throw FilterError.emptyInput }
            return blocks.joined(separator: "\n")
        }
    }

    // MARK: Get Value at Path (R3.5)

    /// The values at every location `path` selects, in each input value.
    static func values(atPath path: String, in data: Data, ifMissing: MissingValueBehavior,
                       settings: Settings) async throws -> [JSON] {
        let filter = try compilePath(path)
        try checkInput(data, settings)
        return try await EngineTask.run(settings) { checkpoint, limits in
            var found: [JSON] = []
            var count = 0
            try JSONParser.forEachValue(in: data, checkpoint: checkpoint) { root in
                count += 1
                let paths = try selectedPaths(filter, in: root, path: path, limits: limits())
                for components in paths {
                    if root.containsPath(components) {
                        found.append(try root.value(at: components))
                    } else if ifMissing == .stop {
                        throw FilterError.pathMissing(path: display(components, fallback: path))
                    }
                }
            }
            if count == 0 { throw FilterError.emptyInput }
            return found
        }
    }

    // MARK: Set Value at Path (R3.6)

    /// Each input value with `newValue` at every location `path` selects.
    static func settingValue(_ newValue: JSON, atPath path: String, in data: Data,
                             settings: Settings) async throws -> [JSON] {
        let filter = try compilePath(path)
        try checkInput(data, settings)
        return try await EngineTask.run(settings) { checkpoint, limits in
            var updated: [JSON] = []
            try JSONParser.forEachValue(in: data, checkpoint: checkpoint) { root in
                var value = root
                for components in try selectedPaths(filter, in: root, path: path, limits: limits()) {
                    try checkpoint()
                    do {
                        value = try value.setting(newValue, at: components)
                    } catch let error as JQRuntimeError {
                        throw FilterErrorMapper.pathRuntime(error, source: path)
                    }
                }
                updated.append(value)
            }
            if updated.isEmpty { throw FilterError.emptyInput }
            return updated
        }
    }

    // MARK: JSON to CSV (R3.7, R5.9)

    static func table(from data: Data, columns: [String]?, delimiter: TableDelimiter, includeHeader: Bool,
                      settings: Settings) async throws -> String {
        try checkInput(data, settings)
        return try await EngineTask.run(settings) { checkpoint, _ in
            var values: [JSON] = []
            try JSONParser.forEachValue(in: data, checkpoint: checkpoint) { values.append($0) }
            guard let first = values.first else { throw FilterError.emptyInput }
            // Several values (JSON Lines) are rows of one table.
            let input = values.count == 1 ? first : .array(values)
            return try TableWriter.table(from: input, columns: columns, delimiter: delimiter,
                                         includeHeader: includeHeader, checkpoint: checkpoint)
        }
    }

    // MARK: Helpers

    private static func checkInput(_ data: Data, _ settings: Settings) throws {
        if let failure = InputCheck.failure(byteCount: data.count, context: settings.context,
                                            canRunInApp: settings.canRunInApp) {
            throw failure
        }
    }

    private static func compilePath(_ path: String) throws -> JQFilter {
        if path.allSatisfy(\.isWhitespace) {
            throw FilterError.pathSelectsNothing
        }
        do {
            return try JQFilter(path)
        } catch let error as JQCompileError {
            throw FilterErrorMapper.compile(error, source: path, isPath: true)
        }
    }

    private static func selectedPaths(_ filter: JQFilter, in root: JSON, path: String, limits: JQLimits) throws -> [[JSON]] {
        var paths: [[JSON]] = []
        do {
            try filter.runPaths(root, limits: limits) { paths.append($0) }
        } catch let error as JQRuntimeError where error.kind == .invalidPath {
            throw FilterError.notAPath(path: path.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let error as JQRuntimeError {
            throw FilterErrorMapper.pathRuntime(error, source: path)
        }
        if paths.isEmpty {
            throw FilterError.pathSelectsNothing
        }
        return paths
    }

    /// `["data","items",3]` as `.data.items[3]`, or the text the person wrote
    /// when a step is not a plain key or index.
    static func display(_ components: [JSON], fallback: String) -> String {
        var built: [JQPathBuilder.Component] = []
        for component in components {
            switch component {
            case .string(let key):
                built.append(.key(key))
            case .number(let number):
                guard let index = number.intValue else { return fallback }
                built.append(.index(index))
            default:
                return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return JQPathBuilder.expression(built)
    }
}

/// Writes CSV and TSV the way jq's `@csv` and `@tsv` do, except that an
/// object or array in a cell is written as compact JSON text instead of
/// failing (R5.9).
enum TableWriter {
    static func table(from value: JSON, columns requested: [String]?, delimiter: JSONTools.TableDelimiter,
                      includeHeader: Bool, checkpoint: () throws -> Void = {}) throws -> String {
        let rows: [JSON]
        switch value {
        case .array(let items): rows = items
        case .object: rows = [value]
        default: throw FilterError.tableInput(type: value.typeName)
        }
        let columns = resolveColumns(requested, rows: rows)
        let separator = delimiter == .comma ? "," : "\t"
        var lines: [String] = []
        lines.reserveCapacity(rows.count + 1)
        if includeHeader, !columns.isEmpty {
            lines.append(columns.map { cell(.string($0), delimiter) }.joined(separator: separator))
        }
        for (index, row) in rows.enumerated() {
            if index & 0x3FF == 0 { try checkpoint() }
            let cells: [JSON]
            switch row {
            case .object(let object): cells = columns.map { object[$0] ?? .null }
            case .array(let items): cells = items
            default: cells = [row]
            }
            lines.append(cells.map { cell($0, delimiter) }.joined(separator: separator))
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// The requested columns, or every key of the first object in its order.
    static func resolveColumns(_ requested: [String]?, rows: [JSON]) -> [String] {
        let cleaned = (requested ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !cleaned.isEmpty { return cleaned }
        for row in rows {
            if case .object(let object) = row { return object.keys }
        }
        return []
    }

    static func cell(_ value: JSON, _ delimiter: JSONTools.TableDelimiter) -> String {
        switch value {
        case .null:
            return ""
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            return number.jqText
        case .string(let text):
            return delimiter == .comma ? quoteCSV(text) : escapeTSV(text)
        case .array, .object:
            let json = JSONWriter.string(value)
            return delimiter == .comma ? quoteCSV(json) : escapeTSV(json)
        }
    }

    private static func quoteCSV(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func escapeTSV(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(character)
            }
        }
        return out
    }
}

/// Runs work on the engine's large-stack thread, tied to the calling task's
/// cancellation, with one deadline and memory budget, and maps every engine
/// failure to a `FilterError`.
enum EngineTask {
    typealias Checkpoint = () throws -> Void

    static func run<T: Sendable>(_ settings: JSONTools.Settings,
                                 _ body: @escaping @Sendable (_ checkpoint: @escaping Checkpoint, _ limits: () -> JQLimits) throws -> T) async throws -> T {
        let timeout = RunLimits.effectiveTimeout(requested: settings.timeout, context: settings.context)
        let memoryLimit = RunLimits.memoryLimit(for: settings.context)
        let cancellation = JQCancellation()
        let result: Result<T, FilterError> = await withTaskCancellationHandler {
            do {
                return try await JQThread.run { () -> Result<T, FilterError> in
                    let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(timeout.seconds * 1_000_000_000)
                    let baseline = MemoryProbe.footprint()
                    let checkpoint: Checkpoint = {
                        if cancellation.isCancelled { throw JQStopReason.cancelled }
                        if DispatchTime.now().uptimeNanoseconds > deadline { throw JQStopReason.timeout(seconds: timeout.seconds) }
                        if let baseline, let current = MemoryProbe.footprint(), current > baseline,
                           current - baseline > memoryLimit {
                            throw JQStopReason.memoryLimit(bytes: memoryLimit)
                        }
                    }
                    let limits: () -> JQLimits = {
                        let now = DispatchTime.now().uptimeNanoseconds
                        let remaining = now >= deadline ? 0.001 : Double(deadline - now) / 1_000_000_000
                        var limits = JQLimits(timeout: remaining)
                        if baseline != nil {
                            limits.memoryLimit = memoryLimit
                            limits.memoryProbe = { MemoryProbe.footprint() }
                        }
                        return limits
                    }
                    do {
                        return .success(try body(checkpoint, limits))
                    } catch {
                        return .failure(map(error, timeout: timeout, settings: settings))
                    }
                }
            } catch {
                return .failure(.cancelled)
            }
        } onCancel: {
            cancellation.cancel()
        }
        return try result.get()
    }

    static func map(_ error: Error, timeout: (seconds: Double, capped: Bool), settings: JSONTools.Settings) -> FilterError {
        switch error {
        case let failure as FilterError:
            return failure
        case let reason as JQStopReason:
            // These actions have no filter and no Timeout to raise.
            return FilterErrorMapper.stop(reason, timeout: timeout, nextStep: .smallerInput,
                                          canRunInApp: settings.context == .background && settings.canRunInApp)
        case let parse as JSONParseError:
            return FilterErrorMapper.input(parse)
        case let runtime as JQRuntimeError:
            return FilterErrorMapper.runtime(runtime, source: "")
        default:
            return .cancelled
        }
    }
}
