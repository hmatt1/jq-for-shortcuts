import Foundation

/// A named filter (R6.12). Its sample input lives in its own file, so
/// listing filters never reads sample data.
struct SavedFilter: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// The description, shown as the subtitle in the Shortcuts picker (R3.35).
    var summary: String
    var filter: String
    var outputMode: OutputMode
    /// A JSON object the Playground uses to test `$name` variables. Empty when unused.
    var argumentsJSON: String
    var sampleInputByteCount: Int
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         summary: String = "",
         filter: String,
         outputMode: OutputMode = .itemPerResult,
         argumentsJSON: String = "",
         sampleInputByteCount: Int = 0,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.summary = summary
        self.filter = filter
        self.outputMode = outputMode
        self.argumentsJSON = argumentsJSON
        self.sampleInputByteCount = sampleInputByteCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, filter, outputMode, argumentsJSON, sampleInputByteCount, createdAt, updatedAt
    }

    /// Missing fields and output modes from a newer version fall back to
    /// defaults instead of hiding the filter.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        filter = try container.decode(String.self, forKey: .filter)
        let mode = try container.decodeIfPresent(String.self, forKey: .outputMode)
        outputMode = mode.flatMap(OutputMode.init(rawValue:)) ?? .itemPerResult
        argumentsJSON = try container.decodeIfPresent(String.self, forKey: .argumentsJSON) ?? ""
        sampleInputByteCount = try container.decodeIfPresent(Int.self, forKey: .sampleInputByteCount) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// A Saved Filter that was deleted, kept so an action that still points at it
/// can name it in its error (R8.13).
struct DeletedFilterRecord: Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var deletedAt: Date
}
