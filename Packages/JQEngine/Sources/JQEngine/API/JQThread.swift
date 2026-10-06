import Foundation

/// Runs engine work on a dedicated thread with a large stack.
///
/// The engine evaluates filters recursively, so a filter like
/// `def f: if . < 50000 then . + 1 | f else . end; f` needs far more stack
/// than the 512 KB a secondary thread gets by default. When the stack does
/// run low, the engine stops with `JQStopReason.recursionLimit` instead of
/// crashing; a larger stack only moves that limit further out.
public enum JQThread {
    /// 256 MB of address space. Pages are committed only as the stack grows,
    /// so an ordinary filter uses a few hundred kilobytes of it.
    public static let defaultStackSize = 256 << 20

    /// Runs `body` on a new thread and blocks the caller until it returns.
    public static func runAndWait<T>(stackSize: Int = defaultStackSize, _ body: @escaping () throws -> T) throws -> T {
        let work = Handoff(body)
        let outcome = Handoff<Result<T, Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            outcome.value = Result { try work.value() }
            done.signal()
        }
        thread.stackSize = stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
        done.wait()
        return try outcome.value!.get()
    }

    /// Runs `body` on a new thread and resumes the caller when it returns,
    /// without holding a Swift concurrency thread while the filter runs.
    public static func run<T: Sendable>(stackSize: Int = defaultStackSize,
                                        _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let thread = Thread {
                continuation.resume(with: Result { try body() })
            }
            thread.stackSize = stackSize
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Carries a value to the worker thread and back. The semaphore in
    /// `runAndWait` orders every access, so no lock is needed.
    private final class Handoff<Value>: @unchecked Sendable {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }
}
