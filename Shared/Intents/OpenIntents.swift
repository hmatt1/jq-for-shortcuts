import AppIntents
import Foundation

/// The app's three tabs, for intents that open the app.
enum AppScreen: String, AppEnum {
    case playground
    case library
    case reference

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Screen")

    static let caseDisplayRepresentations: [AppScreen: DisplayRepresentation] = [
        .playground: DisplayRepresentation(title: "Playground"),
        .library: DisplayRepresentation(title: "Library"),
        .reference: DisplayRepresentation(title: "Reference"),
    ]

    var destination: AppDestination {
        switch self {
        case .playground: return .playground
        case .library: return .library
        case .reference: return .reference
        }
    }
}

/// Routes navigation from an intent to the app's UI. The app installs the
/// handler at launch; in another process the request waits in the App Group
/// until the app becomes active.
@MainActor
enum IntentNavigation {
    static var handler: (@MainActor (AppDestination) -> Void)?

    static func open(_ destination: AppDestination) {
        if let handler {
            handler(destination)
        } else {
            PendingNavigation.post(destination)
        }
    }
}

/// Opens the app at a tab. Backs the Open Playground App Shortcut, which can
/// be bound to the Action Button (R7.3), and the Open Playground control
/// (R7.4). A control that opens its app needs an OpenIntent compiled into
/// both the app and the controls extension.
struct OpenAppScreenIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Playground"
    static let description = IntentDescription("Opens JQ for Shortcuts at the Playground, the Library or the Reference.")

    @Parameter(title: "Screen", default: .playground)
    var target: AppScreen

    init() {}

    init(screen: AppScreen) {
        target = screen
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentNavigation.open(target.destination)
        return .result()
    }
}

/// Opens the app and runs a Saved Filter on the copied text there, which
/// shows the result with a Copy button (R7.4). Backs the Lock Screen control.
struct RunSavedFilterOnClipboardIntent: OpenIntent {
    static let title: LocalizedStringResource = "Run Saved Filter on Clipboard"
    static let description = IntentDescription("Opens JQ for Shortcuts and runs a saved filter on the text you copied.")
    static let isDiscoverable = false

    @Parameter(title: "Saved Filter")
    var target: SavedFilterEntity

    init() {}

    init(filter: SavedFilterEntity) {
        target = filter
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentNavigation.open(.clipboardRunner(savedFilterID: target.isChooseInApp ? nil : target.id))
        return .result()
    }
}

/// The choice behind the Run Saved Filter control.
struct RunSavedFilterControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Run Saved Filter on Clipboard"
    static let description = IntentDescription("Choose the saved filter the control runs on the text you copied.")
    static let isDiscoverable = false

    @Parameter(title: "Saved Filter")
    var savedFilter: SavedFilterEntity?

    init() {}

    func perform() async throws -> some IntentResult {
        .result()
    }
}
