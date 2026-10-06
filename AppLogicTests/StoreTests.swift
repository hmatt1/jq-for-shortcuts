import Foundation
import JQEngine
import XCTest
#if canImport(AppCore)
@testable import AppCore
#endif

/// Saved Filters (R1.3, R6.12, R8.13) and input history (R9.5).
final class StoreTests: XCTestCase {
    private func makeStore() -> SavedFilterStore {
        SavedFilterStore(directory: useTemporaryContainer().appendingPathComponent("SavedFilters"))
    }

    func testSaveAndListSortedByName() throws {
        let store = makeStore()
        try store.save(SavedFilter(name: "zeta", filter: ".z"), sampleInput: nil)
        try store.save(SavedFilter(name: "Alpha", summary: "first", filter: ".a"), sampleInput: #"{"a": 1}"#)
        let all = store.all()
        XCTAssertEqual(all.map(\.name), ["Alpha", "zeta"])
        XCTAssertEqual(all[0].summary, "first")
        XCTAssertEqual(store.sampleInput(id: all[0].id), #"{"a": 1}"#)
        XCTAssertEqual(all[0].sampleInputByteCount, 8)
    }

    func testSaveNeedsANameAndAFilter() {
        let store = makeStore()
        XCTAssertThrowsError(try store.save(SavedFilter(name: "  ", filter: "."), sampleInput: nil)) {
            XCTAssertEqual($0 as? SavedFilterStore.StoreError, .nameRequired)
        }
        XCTAssertThrowsError(try store.save(SavedFilter(name: "x", filter: " \n"), sampleInput: nil)) {
            XCTAssertEqual($0 as? SavedFilterStore.StoreError, .filterRequired)
        }
    }

    func testEditingKeepsTheSampleUnlessReplaced() throws {
        let store = makeStore()
        var saved = try store.save(SavedFilter(name: "x", filter: "."), sampleInput: "[1]")
        saved.filter = ".[0]"
        try store.save(saved, sampleInput: nil)
        XCTAssertEqual(store.sampleInput(id: saved.id), "[1]")
        XCTAssertEqual(store.filter(id: saved.id)?.filter, ".[0]")
        try store.save(saved, sampleInput: "")
        XCTAssertNil(store.sampleInput(id: saved.id))
    }

    func testOversizedSampleIsNotKept() throws {
        let store = makeStore()
        let big = String(repeating: " ", count: RunLimits.sampleInputLimit + 1)
        let saved = try store.save(SavedFilter(name: "x", filter: "."), sampleInput: big)
        XCTAssertEqual(saved.sampleInputByteCount, 0)
        XCTAssertNil(store.sampleInput(id: saved.id))
    }

    func testDuplicateUsesAFreeName() throws {
        let store = makeStore()
        let original = try store.save(SavedFilter(name: "Latest release", filter: ".[0]"), sampleInput: "[1]")
        let copy = try store.duplicate(id: original.id)
        XCTAssertEqual(copy.name, "Latest release Copy")
        XCTAssertEqual(store.sampleInput(id: copy.id), "[1]")
        let second = try store.duplicate(id: original.id)
        XCTAssertEqual(second.name, "Latest release Copy 2")
    }

    func testDeleteRemembersTheName() throws {
        let store = makeStore()
        let saved = try store.save(SavedFilter(name: "Latest release tag", filter: ".[0]"), sampleInput: "[1]")
        try store.delete(id: saved.id)
        XCTAssertNil(store.filter(id: saved.id))
        XCTAssertNil(store.sampleInput(id: saved.id))
        XCTAssertEqual(store.deletedRecord(id: saved.id)?.name, "Latest release tag")
        XCTAssertEqual(FilterError.savedFilterDeleted(name: "Latest release tag").message,
                       "Saved filter \"Latest release tag\" was deleted. Pick another one.")
    }

    func testFindsFiltersByNameIgnoringCase() throws {
        let store = makeStore()
        try store.save(SavedFilter(name: "Webhook cleanup", filter: "{id}"), sampleInput: nil)
        XCTAssertNotNil(store.filter(named: "webhook CLEANUP "))
        XCTAssertNil(store.filter(named: "webhook"))
    }

    // MARK: Input history

    private func makeHistory(enabled: Bool) -> InputHistoryStore {
        InputHistoryStore(directory: useTemporaryContainer().appendingPathComponent("InputHistory"), isEnabled: { enabled })
    }

    func testHistoryStoresNothingWhenOff() {
        let history = makeHistory(enabled: false)
        history.record(actionName: "Run JSON Filter", filter: ".", argumentsJSON: nil, outputMode: .itemPerResult,
                       input: Data("{}".utf8), errorMessage: nil)
        XCTAssertTrue(history.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.directory.path))
    }

    func testHistoryKeepsTheLastTenRuns() {
        let history = makeHistory(enabled: true)
        for index in 0..<12 {
            history.record(actionName: "Run JSON Filter", filter: ".[\(index)]", argumentsJSON: nil, outputMode: .itemPerResult,
                           input: Data("[\(index)]".utf8), errorMessage: nil)
        }
        let entries = history.entries()
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(entries.first?.filter, ".[11]")
        XCTAssertEqual(history.input(for: entries[0]).map { String(decoding: $0, as: UTF8.self) }, "[11]")
    }

    func testLargeInputsAreNotStored() {
        let history = makeHistory(enabled: true)
        let big = Data(count: InputHistoryStore.maximumInputBytes + 1)
        history.record(actionName: "Run JSON Filter", filter: ".", argumentsJSON: "{}", outputMode: .rawLines,
                       input: big, errorMessage: "failed")
        let entry = history.entries()[0]
        XCTAssertFalse(entry.inputStored)
        XCTAssertNil(history.input(for: entry))
        XCTAssertEqual(entry.errorMessage, "failed")
    }

    func testHistoryStaysUnderTheTotalSize() {
        let history = makeHistory(enabled: true)
        let oneMegabyte = Data(repeating: 0x20, count: InputHistoryStore.maximumInputBytes)
        for _ in 0..<25 {
            history.record(actionName: "Run JSON Filter", filter: ".", argumentsJSON: nil, outputMode: .itemPerResult,
                           input: oneMegabyte, errorMessage: nil)
        }
        XCTAssertLessThanOrEqual(history.totalBytes, InputHistoryStore.maximumTotalBytes)
    }

    func testClearRemovesEverything() {
        let history = makeHistory(enabled: true)
        history.record(actionName: "Run JSON Filter", filter: ".", argumentsJSON: nil, outputMode: .itemPerResult,
                       input: Data("{}".utf8), errorMessage: nil)
        history.clear()
        XCTAssertTrue(history.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.directory.path))
    }
}
