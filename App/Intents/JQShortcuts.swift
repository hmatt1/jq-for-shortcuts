import AppIntents

/// One Siri phrase per action, each with the app name (R7.8), and the Open
/// Playground shortcut that can be bound to the Action Button (R7.3).
struct JQShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenAppScreenIntent(),
            phrases: ["Open the Playground in \(.applicationName)"],
            shortTitle: "Open Playground",
            systemImageName: "curlybraces"
        )
        AppShortcut(
            intent: RunJSONFilterIntent(),
            phrases: ["Run a JSON filter with \(.applicationName)"],
            shortTitle: "Run JSON Filter",
            systemImageName: "line.3.horizontal.decrease.circle"
        )
        AppShortcut(
            intent: RunSavedFilterIntent(),
            phrases: ["Run a saved filter with \(.applicationName)"],
            shortTitle: "Run Saved Filter",
            systemImageName: "bookmark"
        )
        AppShortcut(
            intent: ValidateJSONIntent(),
            phrases: ["Validate JSON with \(.applicationName)"],
            shortTitle: "Validate JSON",
            systemImageName: "checkmark.seal"
        )
        AppShortcut(
            intent: FormatJSONIntent(),
            phrases: ["Format JSON with \(.applicationName)"],
            shortTitle: "Format JSON",
            systemImageName: "text.alignleft"
        )
        AppShortcut(
            intent: GetValueAtPathIntent(),
            phrases: ["Get a JSON value with \(.applicationName)"],
            shortTitle: "Get Value at Path",
            systemImageName: "arrow.down.right.circle"
        )
        AppShortcut(
            intent: SetValueAtPathIntent(),
            phrases: ["Set a JSON value with \(.applicationName)"],
            shortTitle: "Set Value at Path",
            systemImageName: "pencil.circle"
        )
        AppShortcut(
            intent: JSONToCSVIntent(),
            phrases: ["Convert JSON to CSV with \(.applicationName)"],
            shortTitle: "JSON to CSV",
            systemImageName: "tablecells"
        )
    }
}
