import Foundation
import JQEngine

/// One filter run, from any entry point: an action, the Playground, the share
/// extension or the clipboard runner. Every entry point goes through
/// `FilterRunner`, so they share the engine and the limits (R7.5, R7.7).
struct FilterRequest: Sendable {
    var filter: String
    /// JSON text: one value, or several separated by whitespace (R2.3).
    var input: Data
    /// A JSON object whose keys become `$name` variables (R2.7).
    var argumentsText: String?
    var slurp = false
    var timeout: Double = RunLimits.defaultTimeout
    var context: RunContext
    /// Whether turning on Run in app could help, for the next step in messages.
    var canRunInApp = false
    /// Collects `debug` and `stderr` output for the Playground (R4.9).
    var collectMessages = false
    /// Stops the run after this many results (the Playground's display limit).
    var resultLimit: Int?
    /// Input values parsed earlier. The Playground parses its input once and
    /// reuses it for every keystroke; `input` is then ignored.
    var parsedInput: [JSON]?
}

struct FilterOutcome: Sendable {
    var results: [JSON] = []
    var messages: [JQMessage] = []
    var error: FilterError?
    /// `halt` ended the run; the results so far stand (R4.10).
    var halted = false
    /// The run stopped at the request's result limit.
    var truncated = false
    var inputValueCount = 0
    var duration: TimeInterval = 0

    static func failure(_ error: FilterError) -> FilterOutcome {
        FilterOutcome(error: error)
    }
}

enum FilterRunner {
    /// Runs the request on a dedicated engine thread. Cancelling the calling
    /// task stops the filter within a few milliseconds (R9.10).
    static func run(_ request: FilterRequest) async -> FilterOutcome {
        let started = Date()
        var outcome = await prepareAndRun(request)
        outcome.duration = Date().timeIntervalSince(started)
        return outcome
    }

    private static func prepareAndRun(_ request: FilterRequest) async -> FilterOutcome {
        if request.filter.allSatisfy(\.isWhitespace) {
            return .failure(.emptyFilter)
        }
        let arguments: [String: JSON]
        do {
            arguments = try FilterArguments.parse(request.argumentsText)
        } catch {
            return .failure(error as? FilterError ?? .argumentsNotDictionary(found: String(localized: "unreadable")))
        }
        if request.parsedInput == nil,
           let failure = InputCheck.failure(byteCount: request.input.count, context: request.context,
                                            canRunInApp: request.canRunInApp) {
            return .failure(failure)
        }
        let compiled: JQFilter
        do {
            // The parser recurses per nesting level; the Swift concurrency
            // pool's 512 KB stacks overflow on it, so compile on the engine thread.
            let source = request.filter
            let argumentNames = arguments.keys.sorted()
            compiled = try await JQThread.run { try JQFilter(source, argumentNames: argumentNames) }
        } catch let error as JQCompileError {
            return .failure(FilterErrorMapper.compile(error, source: request.filter))
        } catch {
            return .failure(.emptyFilter)
        }

        let timeout = RunLimits.effectiveTimeout(requested: request.timeout, context: request.context)
        let job = FilterJob(
            compiled: compiled,
            request: request,
            arguments: arguments,
            budget: RunBudget(timeout: timeout.seconds, memoryLimit: RunLimits.memoryLimit(for: request.context))
        )
        let raw = await job.start()
        return raw.outcome(for: request, timeout: timeout)
    }
}

/// Input checks every run makes before reading the input (R2.6, R9.9).
enum InputCheck {
    static func failure(byteCount: Int, context: RunContext, canRunInApp: Bool) -> FilterError? {
        let limit = RunLimits.inputLimit(for: context)
        if byteCount > limit {
            return .inputTooLarge(bytes: byteCount, limit: limit, context: context, canRunInApp: canRunInApp)
        }
        if RunLimits.inputLikelyExceedsMemory(bytes: byteCount) {
            return .memoryLimit(canRunInApp: context == .background && canRunInApp)
        }
        return nil
    }
}

/// The time and memory one run may use, across every input value.
struct RunBudget: Sendable {
    var timeout: Double
    var memoryLimit: UInt64
}

/// Runs a compiled filter over every input value on a large-stack thread,
/// with one deadline and one memory budget for the whole input.
final class FilterJob: Sendable {
    let compiled: JQFilter
    let request: FilterRequest
    let arguments: [String: JSON]
    let budget: RunBudget
    let cancellation = JQCancellation()

    init(compiled: JQFilter, request: FilterRequest, arguments: [String: JSON], budget: RunBudget) {
        self.compiled = compiled
        self.request = request
        self.arguments = arguments
        self.budget = budget
    }

    func start() async -> RawRun {
        do {
            return try await withTaskCancellationHandler {
                try await JQThread.run { self.execute() }
            } onCancel: {
                self.cancellation.cancel()
            }
        } catch {
            return RawRun(failure: .stop(.cancelled))
        }
    }

    private struct ResultLimitReached: Error {}

    /// Runs synchronously on the calling thread.
    func execute() -> RawRun {
        var run = RawRun()
        let startNanos = DispatchTime.now().uptimeNanoseconds
        let deadlineNanos = startNanos &+ UInt64(max(budget.timeout, 0.001) * 1_000_000_000)
        let baseline = MemoryProbe.footprint()
        let cancellation = self.cancellation
        let budget = self.budget

        func remainingSeconds() -> Double {
            let now = DispatchTime.now().uptimeNanoseconds
            return now >= deadlineNanos ? 0.001 : Double(deadlineNanos - now) / 1_000_000_000
        }

        /// The memory still available to this run, or nil when the platform
        /// cannot measure it.
        func remainingMemory() throws -> UInt64? {
            guard let baseline, let current = MemoryProbe.footprint() else { return nil }
            let used = current > baseline ? current - baseline : 0
            if used >= budget.memoryLimit {
                throw JQStopReason.memoryLimit(bytes: budget.memoryLimit)
            }
            return budget.memoryLimit - used
        }

        let checkpoint: () throws -> Void = {
            if cancellation.isCancelled { throw JQStopReason.cancelled }
            if DispatchTime.now().uptimeNanoseconds > deadlineNanos { throw JQStopReason.timeout(seconds: budget.timeout) }
            _ = try remainingMemory()
        }

        var messages: [JQMessage] = []
        let onMessage: ((JQMessage) -> Void)? = request.collectMessages ? { message in
            if messages.count < 1_000 { messages.append(message) }
        } : nil
        let resultLimit = request.resultLimit
        var results: [JSON] = []
        let maxCollection = Int(min(UInt64(200_000_000), max(UInt64(1_000_000), budget.memoryLimit / 16)))

        func runOne(_ value: JSON) throws {
            try checkpoint()
            let memory = try remainingMemory()
            var limits = JQLimits(timeout: remainingSeconds(), maxCollectionSize: maxCollection)
            if let memory {
                limits.memoryLimit = memory
                limits.memoryProbe = { MemoryProbe.footprint() }
            }
            try compiled.run(value, arguments: arguments, limits: limits, cancellation: cancellation, onMessage: onMessage) { result in
                results.append(result)
                if let resultLimit, results.count >= resultLimit {
                    throw ResultLimitReached()
                }
            }
        }

        do {
            if let parsed = request.parsedInput {
                run.inputValueCount = parsed.count
                if request.slurp {
                    try runOne(.array(parsed))
                } else {
                    for value in parsed {
                        try runOne(value)
                    }
                }
            } else if request.slurp {
                var all: [JSON] = []
                try JSONParser.forEachValue(in: request.input, checkpoint: checkpoint) { value in
                    all.append(value)
                    run.inputValueCount += 1
                }
                try runOne(.array(all))
            } else {
                try JSONParser.forEachValue(in: request.input, checkpoint: checkpoint) { value in
                    run.inputValueCount += 1
                    try runOne(value)
                }
            }
        } catch is ResultLimitReached {
            run.truncated = true
        } catch let error as JQRuntimeError {
            run.failure = .runtime(error)
        } catch let halt as JQHalt {
            if halt.message == nil {
                run.halted = true
            } else {
                run.failure = .halt(halt)
            }
        } catch let reason as JQStopReason {
            run.failure = .stop(reason)
        } catch let error as JSONParseError {
            run.failure = .input(error)
        } catch {
            run.failure = .stop(.cancelled)
        }
        run.results = results
        run.messages = messages
        return run
    }
}

/// What the engine thread hands back.
struct RawRun: Sendable {
    enum Failure: Sendable {
        case runtime(JQRuntimeError)
        case halt(JQHalt)
        case stop(JQStopReason)
        case input(JSONParseError)
    }

    var results: [JSON] = []
    var messages: [JQMessage] = []
    var inputValueCount = 0
    var halted = false
    var truncated = false
    var failure: Failure?

    func outcome(for request: FilterRequest, timeout: (seconds: Double, capped: Bool)) -> FilterOutcome {
        var outcome = FilterOutcome(
            results: results,
            messages: messages,
            halted: halted,
            truncated: truncated,
            inputValueCount: inputValueCount
        )
        switch failure {
        case nil:
            // R2.3: the filter runs once per input value, so an empty input
            // gives no results, as in jq. With Slurp it runs once on [].
            break
        case .runtime(let error):
            outcome.error = FilterErrorMapper.runtime(error, source: request.filter)
        case .halt(let halt):
            outcome.error = FilterErrorMapper.halt(halt)
        case .stop(let reason):
            let nextStep: FilterError.TimeoutNextStep
            switch request.context {
            case .background, .foreground: nextStep = .raiseTimeout
            case .playground, .shareExtension: nextStep = .narrow
            }
            outcome.error = FilterErrorMapper.stop(reason, timeout: timeout, nextStep: nextStep,
                                                   canRunInApp: request.context == .background && request.canRunInApp)
            // R4.8: a run stopped by a limit returns no results.
            outcome.results = []
        case .input(let error):
            outcome.error = FilterErrorMapper.input(error)
        }
        return outcome
    }
}
