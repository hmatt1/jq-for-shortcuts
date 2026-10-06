import AppIntents
import Foundation

/// A Saved Filter as Shortcuts sees it. The Run Saved Filter picker lists
/// these by name with the description as the subtitle (R3.35). Compiled into
/// the app and the controls extension, which both read the shared store.
struct SavedFilterEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Saved Filter")

    static let defaultQuery = SavedFilterQuery()

    /// Stands for "no filter chosen yet" in a Lock Screen control, which must
    /// always hand its button a filter. The clipboard runner then asks.
    static let chooseInApp = SavedFilterEntity(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        name: String(localized: "Choose in App"),
        summary: ""
    )

    let id: UUID
    let name: String
    let summary: String

    var isChooseInApp: Bool { id == Self.chooseInApp.id }

    var displayRepresentation: DisplayRepresentation {
        if summary.isEmpty {
            return DisplayRepresentation(title: "\(name)")
        }
        return DisplayRepresentation(title: "\(name)", subtitle: "\(summary)")
    }

    init(id: UUID, name: String, summary: String) {
        self.id = id
        self.name = name
        self.summary = summary
    }

    init(_ filter: SavedFilter) {
        self.init(id: filter.id, name: filter.name, summary: filter.summary)
    }
}

struct SavedFilterQuery: EntityStringQuery {
    func entities(for identifiers: [SavedFilterEntity.ID]) async throws -> [SavedFilterEntity] {
        let store = SavedFilterStore.shared
        return identifiers.map { id in
            if id == SavedFilterEntity.chooseInApp.id {
                return SavedFilterEntity.chooseInApp
            }
            if let filter = store.filter(id: id) {
                return SavedFilterEntity(filter)
            }
            // A deleted filter still resolves, so the action can run and name
            // it in its error (R8.13) instead of failing without a reason.
            let name = store.deletedRecord(id: id)?.name ?? String(localized: "Deleted filter")
            return SavedFilterEntity(id: id, name: name, summary: "")
        }
    }

    func entities(matching string: String) async throws -> [SavedFilterEntity] {
        SavedFilterStore.shared.all()
            .filter { $0.name.localizedCaseInsensitiveContains(string) || $0.summary.localizedCaseInsensitiveContains(string) }
            .map(SavedFilterEntity.init)
    }

    func suggestedEntities() async throws -> [SavedFilterEntity] {
        SavedFilterStore.shared.all().map(SavedFilterEntity.init)
    }
}
