import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Resource limits for one run. The engine checks them often enough that a
/// runaway filter stops within a few milliseconds of crossing one.
public struct JQLimits: Sendable {
    /// Wall-clock limit in seconds; nil for none.
    public var timeout: Double?
    /// Maximum growth of the process's memory footprint during the run, in
    /// bytes. Only enforced when `memoryProbe` is set.
    public var memoryLimit: UInt64?
    /// Returns the process's current memory footprint in bytes.
    public var memoryProbe: (@Sendable () -> UInt64?)?
    /// Largest string or array a single operation may build, in elements.
    public var maxCollectionSize: Int

    public init(timeout: Double? = 10,
                memoryLimit: UInt64? = nil,
                memoryProbe: (@Sendable () -> UInt64?)? = nil,
                maxCollectionSize: Int = 200_000_000) {
        self.timeout = timeout
        self.memoryLimit = memoryLimit
        self.memoryProbe = memoryProbe
        self.maxCollectionSize = maxCollectionSize
    }

    public static let unlimited = JQLimits(timeout: nil)
}

/// A thread-safe flag another thread sets to stop a run.
public final class JQCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Messages a filter writes with `debug` and `stderr`.
public enum JQMessage: Sendable, Equatable {
    case debug(String)
    case stderr(String)
}

/// State shared by every node during one run.
final class Context {
    let limits: JQLimits
    let cancellation: JQCancellation?
    let onMessage: ((JQMessage) -> Void)?
    let globals: [JSON]

    private var steps: UInt = 0
    private var labelCounter = 0
    private let startNanos: UInt64
    private let deadlineNanos: UInt64?
    private var lastMemoryCheckNanos: UInt64
    private let memoryBaseline: UInt64?
    private let stackFloor: UInt

    init(limits: JQLimits, cancellation: JQCancellation?, onMessage: ((JQMessage) -> Void)?, globals: [JSON]) {
        self.limits = limits
        self.cancellation = cancellation
        self.onMessage = onMessage
        self.globals = globals
        let now = DispatchTime.now().uptimeNanoseconds
        startNanos = now
        lastMemoryCheckNanos = now
        if let timeout = limits.timeout, timeout > 0 {
            deadlineNanos = now &+ UInt64(timeout * 1_000_000_000)
        } else {
            deadlineNanos = nil
        }
        memoryBaseline = limits.memoryLimit != nil ? limits.memoryProbe?() : nil
        stackFloor = StackBounds.current().floor
    }

    var elapsedSeconds: Double {
        Double(DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000_000
    }

    /// Called on every loop iteration and function call.
    @inline(__always)
    func tick() throws {
        steps &+= 1
        if steps & 0x3FF == 0 {
            try checkLimits()
        }
    }

    func checkLimits() throws {
        if let cancellation, cancellation.isCancelled {
            throw JQStopReason.cancelled
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if let deadlineNanos, now > deadlineNanos {
            throw JQStopReason.timeout(seconds: limits.timeout ?? 0)
        }
        if let limit = limits.memoryLimit, let baseline = memoryBaseline,
           now &- lastMemoryCheckNanos > 10_000_000 {
            lastMemoryCheckNanos = now
            if let current = limits.memoryProbe?(), current > baseline, current - baseline > limit {
                throw JQStopReason.memoryLimit(bytes: limit)
            }
        }
    }

    /// Stops deep recursion before it can overflow the thread's stack.
    @inline(__always)
    func checkStack() throws {
        var marker: UInt8 = 0
        let address = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        if address < stackFloor {
            throw JQStopReason.recursionLimit
        }
    }

    /// Checks that a collection of `count` elements may be built.
    @inline(__always)
    func checkSize(_ count: Int) throws {
        if count > limits.maxCollectionSize {
            throw JQStopReason.memoryLimit(bytes: UInt64(max(count, 0)))
        }
    }

    /// A fresh label, numbered in creation order like jq's `GENLABEL`.
    func makeLabel() -> LabelToken {
        defer { labelCounter += 1 }
        return LabelToken(number: labelCounter)
    }

    func emit(_ message: JQMessage) {
        onMessage?(message)
    }
}

/// The current thread's stack bounds, used by the recursion guard.
enum StackBounds {
    /// Space kept free below the deepest allowed frame.
    static let reserve: UInt = 192 * 1024

    static func current() -> (floor: UInt, size: UInt) {
        #if canImport(Darwin)
        let thread = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let size = UInt(pthread_get_stacksize_np(thread))
        if top > size, size > reserve * 2 {
            return (top - size + reserve, size)
        }
        #elseif canImport(Glibc)
        var attr = pthread_attr_t()
        if linux_pthread_getattr_np(pthread_self(), &attr) == 0 {
            defer { pthread_attr_destroy(&attr) }
            var address: UnsafeMutableRawPointer?
            var size: Int = 0
            if pthread_attr_getstack(&attr, &address, &size) == 0, let address, size > Int(reserve * 2) {
                return (UInt(bitPattern: address) + reserve, UInt(size))
            }
        }
        #endif
        // Unknown bounds: assume a 512 KB stack below the current frame.
        var marker: UInt8 = 0
        let here = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        let assumed: UInt = 512 * 1024
        return (here > assumed ? here - assumed + reserve : 0, assumed)
    }
}

#if canImport(Glibc)
/// A GNU extension Swift's Glibc module does not expose.
@_silgen_name("pthread_getattr_np")
private func linux_pthread_getattr_np(_ thread: pthread_t, _ attr: UnsafeMutablePointer<pthread_attr_t>) -> Int32
#endif

// MARK: - Environment

/// A lexical environment: a linked list of frames that mirrors the scopes the
/// compiler resolved, so lookups are by depth.
final class Env {
    enum Slot {
        case value(JSON)
        /// A local `def`; its body runs in this frame's environment.
        case function(CompiledFunction)
        /// A filter argument: the argument's code and the caller's environment.
        case closure(Node, Env?)
        case label(LabelToken)
    }

    let parent: Env?
    let slot: Slot

    init(_ slot: Slot, parent: Env?) {
        self.slot = slot
        self.parent = parent
    }

    @inline(__always)
    func at(_ depth: Int) -> Env {
        var e = self
        var d = depth
        while d > 0 {
            e = e.parent!
            d -= 1
        }
        return e
    }
}

/// A compiled function: jq-defined builtins, user definitions, and their
/// parameters.
final class CompiledFunction {
    let name: String
    let parameters: [FunctionDefinition.Parameter]
    let range: SourceRange
    var body: Node!

    init(name: String, parameters: [FunctionDefinition.Parameter], range: SourceRange) {
        self.name = name
        self.parameters = parameters
        self.range = range
    }

    var arity: Int { parameters.count }
}
