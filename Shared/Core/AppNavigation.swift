import Foundation

/// A place in the app that an intent, a control, the share sheet or a link
/// can open.
enum AppDestination: Codable, Equatable, Hashable, Sendable {
    case playground
    case library
    case reference
    /// Runs a Saved Filter on the clipboard text and shows the result (R7.4).
    /// Nil lets the person pick the filter.
    case clipboardRunner(savedFilterID: UUID?)
    /// The Playground with the share extension's content waiting in the inbox.
    case sharedInput

    /// `jqforshortcuts://playground` and friends.
    static let urlScheme = "jqforshortcuts"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.urlScheme
        switch self {
        case .playground: components.host = "playground"
        case .library: components.host = "library"
        case .reference: components.host = "reference"
        case .sharedInput: components.host = "shared-input"
        case .clipboardRunner(let id):
            components.host = "clipboard"
            if let id { components.queryItems = [URLQueryItem(name: "filter", value: id.uuidString)] }
        }
        return components.url!
    }

    init?(url: URL) {
        guard url.scheme == Self.urlScheme else { return nil }
        switch url.host {
        case "playground": self = .playground
        case "library": self = .library
        case "reference": self = .reference
        case "shared-input": self = .sharedInput
        case "clipboard":
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "filter" })?.value
            self = .clipboardRunner(savedFilterID: value.flatMap(UUID.init(uuidString:)))
        default:
            return nil
        }
    }
}

/// Carries a destination to the app when the request starts in another
/// process, such as the controls extension. The app takes it when it
/// becomes active.
enum PendingNavigation {
    private static let key = "pendingNavigation"

    static func post(_ destination: AppDestination) {
        guard let data = try? JSONEncoder().encode(destination) else { return }
        AppGroup.defaults.set(data, forKey: key)
    }

    static func take() -> AppDestination? {
        let defaults = AppGroup.defaults
        guard let data = defaults.data(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return try? JSONDecoder().decode(AppDestination.self, from: data)
    }
}
