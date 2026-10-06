import Foundation

/// One run from Shortcuts, kept only while input history is on (R9.5).
struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var date: Date
    /// The action that ran, such as "Run JSON Filter".
    var actionName: String
    var filter: String
    var argumentsJSON: String
    var outputMode: OutputMode
    var inputByteCount: Int
    /// False when the input was over the per-input limit and only its size was kept.
    var inputStored: Bool
    /// The error message, or nil when the run succeeded.
    var errorMessage: String?
}

/// Input history (R9.5, R6.15): off by default, the last 10 runs, at most
/// 1 MB per input and 20 MB in total, kept out of device backups, and cleared
/// with one tap. Only the app process writes it, from the actions.
final class InputHistoryStore: @unchecked Sendable {
    static let shared = InputHistoryStore(directory: AppGroup.containerURL.appendingPathComponent("InputHistory", isDirectory: true))

    static let didChangeNotification = Notification.Name("InputHistoryStoreDidChange")

    static let maximumEntries = 10
    static let maximumInputBytes = 1 << 20
    static let maximumTotalBytes = 20 << 20

    let directory: URL
    private let indexURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let isEnabled: () -> Bool

    init(directory: URL, isEnabled: @escaping () -> Bool = { AppSettings.inputHistoryEnabled }) {
        self.directory = directory
        self.isEnabled = isEnabled
        indexURL = directory.appendingPathComponent("index.json")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func entries() -> [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return readIndex()
    }

    func input(for entry: HistoryEntry) -> Data? {
        guard entry.inputStored else { return nil }
        return try? Data(contentsOf: inputURL(entry.id))
    }

    /// Records a run when history is on, and does nothing otherwise, so a
    /// fresh install stores no input (R2.11).
    func record(actionName: String, filter: String, argumentsJSON: String?, outputMode: OutputMode,
                input: Data, errorMessage: String?) {
        guard isEnabled() else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            try prepareDirectory()
            let stored = input.count <= Self.maximumInputBytes
            let entry = HistoryEntry(
                id: UUID(), date: Date(), actionName: actionName, filter: filter,
                argumentsJSON: argumentsJSON ?? "", outputMode: outputMode,
                inputByteCount: input.count, inputStored: stored, errorMessage: errorMessage
            )
            if stored {
                try input.write(to: inputURL(entry.id), options: .atomic)
            }
            var all = readIndex()
            all.insert(entry, at: 0)
            try encoder.encode(trim(all)).write(to: indexURL, options: .atomic)
        } catch {
            // History is a convenience; failing to record must never fail a run.
        }
        notifyChange()
    }

    /// Removes every entry and its input in one step.
    func clear() {
        lock.lock()
        try? FileManager.default.removeItem(at: directory)
        lock.unlock()
        notifyChange()
    }

    var totalBytes: Int {
        entries().filter(\.inputStored).reduce(0) { $0 + $1.inputByteCount }
    }

    // MARK: Files

    private func inputURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
        #endif
    }

    private func readIndex() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    /// Keeps the newest entries within the count and size limits, and deletes
    /// the inputs of the rest.
    private func trim(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        var kept: [HistoryEntry] = []
        var total = 0
        for entry in entries {
            let size = entry.inputStored ? entry.inputByteCount : 0
            if kept.count < Self.maximumEntries, total + size <= Self.maximumTotalBytes {
                kept.append(entry)
                total += size
            } else {
                try? FileManager.default.removeItem(at: inputURL(entry.id))
            }
        }
        return kept
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}
