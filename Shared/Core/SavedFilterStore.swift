import Foundation

/// Saved Filters on disk in the App Group container, shared by the app, the
/// share extension, the controls extension and the actions (R7.5).
///
///     SavedFilters/Filters/<id>.json   one file per filter, without its sample
///     SavedFilters/Samples/<id>.json   the sample input (R1.3)
///     SavedFilters/Deleted/<id>.json   the name of a deleted filter (R8.13)
///
/// One file per filter, written atomically, means two processes saving
/// different filters at the same moment never overwrite each other's work,
/// and a reader always sees a complete file.
final class SavedFilterStore: @unchecked Sendable {
    static let shared = SavedFilterStore(directory: AppGroup.containerURL.appendingPathComponent("SavedFilters", isDirectory: true))

    /// Posted on the main queue in the process that changed the store.
    static let didChangeNotification = Notification.Name("SavedFilterStoreDidChange")

    enum StoreError: LocalizedError, Equatable {
        case nameRequired
        case filterRequired
        case notFound

        var errorDescription: String? {
            switch self {
            case .nameRequired: return String(localized: "Give the filter a name.")
            case .filterRequired: return String(localized: "Enter a filter to save.")
            case .notFound: return String(localized: "That saved filter no longer exists.")
            }
        }
    }

    private static let deletedRecordLimit = 200

    let directory: URL
    private let filtersDirectory: URL
    private let samplesDirectory: URL
    private let deletedDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL) {
        self.directory = directory
        filtersDirectory = directory.appendingPathComponent("Filters", isDirectory: true)
        samplesDirectory = directory.appendingPathComponent("Samples", isDirectory: true)
        deletedDirectory = directory.appendingPathComponent("Deleted", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: Reading

    /// Every Saved Filter, sorted by name.
    func all() -> [SavedFilter] {
        readAll(SavedFilter.self, in: filtersDirectory)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func filter(id: UUID) -> SavedFilter? {
        read(SavedFilter.self, at: fileURL(id, in: filtersDirectory))
    }

    /// The filter with this name, ignoring case.
    func filter(named name: String) -> SavedFilter? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return all().first { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    func sampleInput(id: UUID) -> String? {
        guard let data = try? Data(contentsOf: fileURL(id, in: samplesDirectory)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func deletedRecord(id: UUID) -> DeletedFilterRecord? {
        read(DeletedFilterRecord.self, at: fileURL(id, in: deletedDirectory))
    }

    // MARK: Writing

    /// Inserts or replaces `filter`. A nil `sampleInput` keeps the stored
    /// sample; an empty one removes it. A sample over the size limit is not
    /// kept, and the returned filter records a byte count of 0.
    @discardableResult
    func save(_ filter: SavedFilter, sampleInput: String?) throws -> SavedFilter {
        var filter = filter
        filter.name = filter.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.name.isEmpty else { throw StoreError.nameRequired }
        guard !filter.filter.allSatisfy(\.isWhitespace) else { throw StoreError.filterRequired }
        filter.updatedAt = Date()
        try prepareDirectories()

        if let sampleInput {
            let data = Data(sampleInput.utf8)
            let sampleURL = fileURL(filter.id, in: samplesDirectory)
            if data.isEmpty || data.count > RunLimits.sampleInputLimit {
                try? FileManager.default.removeItem(at: sampleURL)
                filter.sampleInputByteCount = 0
            } else {
                try data.write(to: sampleURL, options: .atomic)
                filter.sampleInputByteCount = data.count
            }
        }
        try encoder.encode(filter).write(to: fileURL(filter.id, in: filtersDirectory), options: .atomic)
        try? FileManager.default.removeItem(at: fileURL(filter.id, in: deletedDirectory))
        notifyChange()
        return filter
    }

    /// Copies a filter and its sample under a new name.
    @discardableResult
    func duplicate(id: UUID) throws -> SavedFilter {
        guard let original = filter(id: id) else { throw StoreError.notFound }
        var copy = original
        copy.id = UUID()
        copy.name = uniqueName(String(localized: "\(original.name) Copy"))
        copy.createdAt = Date()
        return try save(copy, sampleInput: sampleInput(id: id) ?? "")
    }

    func delete(id: UUID) throws {
        guard let removed = filter(id: id) else { throw StoreError.notFound }
        try prepareDirectories()
        let record = DeletedFilterRecord(id: id, name: removed.name, deletedAt: Date())
        try encoder.encode(record).write(to: fileURL(id, in: deletedDirectory), options: .atomic)
        try FileManager.default.removeItem(at: fileURL(id, in: filtersDirectory))
        try? FileManager.default.removeItem(at: fileURL(id, in: samplesDirectory))
        pruneDeletedRecords()
        notifyChange()
    }

    /// `base`, or `base 2`, `base 3`... whichever no filter uses yet.
    func uniqueName(_ base: String) -> String {
        let taken = Set(all().map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: Files

    private func fileURL(_ id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    private func prepareDirectories() throws {
        for folder in [filtersDirectory, samplesDirectory, deletedDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func readAll<T: Decodable>(_ type: T.Type, in folder: URL) -> [T] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap {
            read(T.self, at: folder.appendingPathComponent($0))
        }
    }

    private func pruneDeletedRecords() {
        let records = readAll(DeletedFilterRecord.self, in: deletedDirectory)
        guard records.count > Self.deletedRecordLimit else { return }
        for record in records.sorted(by: { $0.deletedAt > $1.deletedAt }).dropFirst(Self.deletedRecordLimit) {
            try? FileManager.default.removeItem(at: fileURL(record.id, in: deletedDirectory))
        }
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}
