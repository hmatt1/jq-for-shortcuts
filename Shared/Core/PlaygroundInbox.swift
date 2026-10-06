import Foundation

/// Hands shared content from the share extension to the app's Playground
/// (R7.1). The extension leaves one item in the App Group container; the app
/// takes it the next time it becomes active and deletes it at once, so the
/// input is never kept (R2.11).
enum PlaygroundInbox {
    struct Item: Sendable, Equatable {
        var data: Data
        var name: String?
    }

    private struct Metadata: Codable {
        var name: String?
        var date: Date
    }

    /// Items older than this are discarded unread.
    static let maximumAge: TimeInterval = 60 * 60

    private static var directory: URL {
        AppGroup.containerURL.appendingPathComponent("Inbox", isDirectory: true)
    }

    private static var dataURL: URL { directory.appendingPathComponent("input.json") }
    private static var metadataURL: URL { directory.appendingPathComponent("metadata.json") }

    static func deposit(_ data: Data, name: String?) throws {
        try prepare()
        try data.write(to: dataURL, options: .atomic)
        try writeMetadata(name: name)
    }

    /// Copies a file into the inbox without reading it into memory, for
    /// large files shared from Files.
    static func depositFile(at url: URL, name: String?) throws {
        try prepare()
        try? FileManager.default.removeItem(at: dataURL)
        try FileManager.default.copyItem(at: url, to: dataURL)
        try writeMetadata(name: name)
    }

    private static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try? folder.setResourceValues(values)
        #endif
    }

    private static func writeMetadata(name: String?) throws {
        let metadata = Metadata(name: name, date: Date())
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
    }

    /// The waiting item, removed from the inbox. Nil when there is none.
    static func take(now: Date = Date()) -> Item? {
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let data = try? Data(contentsOf: dataURL) else { return nil }
        let metadata = (try? Data(contentsOf: metadataURL)).flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
        if let metadata, now.timeIntervalSince(metadata.date) > maximumAge {
            return nil
        }
        return Item(data: data, name: metadata?.name)
    }

    static var hasItem: Bool {
        FileManager.default.fileExists(atPath: dataURL.path)
    }
}
