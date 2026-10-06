import Foundation
import XCTest
@testable import JQEngine

/// Design R4.8, R9.6 and R9.10: every run stops at its timeout, its memory
/// cap, a cancel, or the end of its stack, and none of them hang or crash.
final class LimitsTests: XCTestCase {
    private func stopReason(_ filter: String, input: JSON = .null, limits: JQLimits,
                            cancellation: JQCancellation? = nil) throws -> (JQStopReason?, TimeInterval) {
        let compiled = try JQFilter(filter)
        let started = Date()
        do {
            try JQThread.runAndWait {
                try compiled.run(input, limits: limits, cancellation: cancellation) { _ in }
            }
            return (nil, Date().timeIntervalSince(started))
        } catch let reason as JQStopReason {
            return (reason, Date().timeIntervalSince(started))
        }
    }

    func testRunawayCollectionStopsAtTheTimeout() throws {
        let (reason, elapsed) = try stopReason("[range(1e12)]", limits: JQLimits(timeout: 0.5))
        XCTAssertEqual(reason, .timeout(seconds: 0.5))
        XCTAssertLessThan(elapsed, 0.5 + 0.5)
    }

    func testEndlessGeneratorStopsAtTheTimeout() throws {
        let (reason, elapsed) = try stopReason("last(range(1e12))", limits: JQLimits(timeout: 0.5))
        XCTAssertEqual(reason, .timeout(seconds: 0.5))
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testEndlessRepeatStopsAtTheTimeout() throws {
        let (reason, _) = try stopReason("[repeat(1)] | length", limits: JQLimits(timeout: 0.3))
        XCTAssertEqual(reason, .timeout(seconds: 0.3))
    }

    func testUnboundedRecursionStopsBeforeTheStackRunsOut() throws {
        // A small stack makes the limit quick to reach.
        let compiled = try JQFilter("def f: f + 1; f")
        XCTAssertThrowsError(try JQThread.runAndWait(stackSize: 4 << 20) {
            try compiled.run(.null, limits: JQLimits(timeout: 20)) { _ in }
        }) { error in
            XCTAssertEqual(error as? JQStopReason, .recursionLimit)
        }
    }

    func testDeepButFiniteRecursionCompletesOnALargeStack() throws {
        let outputs = try JQThread.runAndWait {
            try TestRunner.outputs("def f: if . < 20000 then . + 1 | f else . end; f", "0")
        }
        XCTAssertEqual(outputs, ["20000"])
    }

    func testCancellationFromAnotherThreadStopsQuickly() throws {
        let cancellation = JQCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancellation.cancel() }
        let (reason, elapsed) = try stopReason("[range(1e12)] | length", limits: JQLimits(timeout: 30),
                                               cancellation: cancellation)
        XCTAssertEqual(reason, .cancelled)
        XCTAssertLessThan(elapsed, 0.2 + 0.5, "R9.10: a cancel stops the run within 500 ms")
    }

    func testCancellationBeforeTheRunStopsImmediately() throws {
        let cancellation = JQCancellation()
        cancellation.cancel()
        let (reason, _) = try stopReason(".", limits: JQLimits(timeout: 30), cancellation: cancellation)
        XCTAssertEqual(reason, .cancelled)
    }

    func testMemoryProbeStopsARunThatGrowsPastTheLimit() throws {
        // A fake footprint that grows 1 MB per reading.
        final class FakeFootprint: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes: UInt64 = 100 << 20
            func read() -> UInt64? {
                lock.lock()
                defer { lock.unlock() }
                bytes += 1 << 20
                return bytes
            }
        }
        let footprint = FakeFootprint()
        let limits = JQLimits(timeout: 30, memoryLimit: 64 << 20, memoryProbe: { footprint.read() })
        let (reason, _) = try stopReason("[range(1e12)] | length", limits: limits)
        XCTAssertEqual(reason, .memoryLimit(bytes: 64 << 20))
    }

    func testHugeStringStopsAtTheCollectionLimit() throws {
        let limits = JQLimits(timeout: 10, maxCollectionSize: 10_000_000)
        let (reason, _) = try stopReason(#""x" * 1e9 | length"#, limits: limits)
        guard case .memoryLimit = reason else {
            return XCTFail("expected the memory limit, got \(String(describing: reason))")
        }
    }

    func testHugeArrayIndexStopsInsteadOfAllocating() throws {
        let (reason, _) = try stopReason("setpath([1e9]; 1)", limits: JQLimits(timeout: 10))
        guard case .memoryLimit = reason else {
            return XCTFail("expected the memory limit, got \(String(describing: reason))")
        }
    }

    func testCatastrophicRegexStopsAtTheTimeout() throws {
        let input = JSON.string(String(repeating: "a", count: 40) + "!")
        let (reason, elapsed) = try stopReason(#"test("(a+)+$")"#, input: input, limits: JQLimits(timeout: 1))
        // The regex engine either fails fast or the run stops at the timeout.
        if let reason {
            XCTAssertEqual(reason, .timeout(seconds: 1))
        }
        XCTAssertLessThan(elapsed, 3)
    }

    func testTryDoesNotCatchLimits() throws {
        let (reason, _) = try stopReason("try [range(1e12)] catch \"caught\"", limits: JQLimits(timeout: 0.3))
        XCTAssertEqual(reason, .timeout(seconds: 0.3))
    }

    func testLimitStopsAnInfiniteGenerator() throws {
        XCTAssertEqual(try TestRunner.outputs("[limit(5; repeat(1))]"), ["[1,1,1,1,1]"])
        XCTAssertEqual(try TestRunner.outputs("first(range(1e12))"), ["0"])
    }
}
