import SwiftUI

struct HelpView: View {
    private struct Topic: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let body: LocalizedStringKey
    }

    private let topics: [Topic] = [
        Topic(id: "run", title: "Run a filter in Shortcuts",
              body: "Add Run JSON Filter after the action that gets your JSON, such as Get Contents of URL. Type a filter, such as .items[] | .name, and pick an output. The action works without opening the app first."),
        Topic(id: "output", title: "Output modes",
              body: "One item per result gives each result as its own item, and a single list result as its items. One JSON array gives one list with every result. Raw text lines gives text with one result per line, strings without quotes. Compact JSON and Pretty JSON give the results as JSON text. Objects and lists arrive as JSON text, which Get Dictionary Value and other dictionary actions read directly."),
        Topic(id: "arguments", title: "Arguments",
              body: "Pass a Dictionary in Arguments to give the filter values without building it from text. Each key becomes a variable: the key limit is $limit in the filter. Pass a Number to get a number, and text to get a string. Run Saved Filter starts from the arguments saved with the filter, and the action's Arguments replace any of them."),
        Topic(id: "saved", title: "Saved filters",
              body: "Tap Save Filter in the Playground to name a filter. It appears in the Run Saved Filter action right away, and in the Library, where you can edit, duplicate or delete it."),
        Topic(id: "large", title: "Large inputs and long runs",
              body: "An action that runs in the background takes inputs up to 50 MB and stops after its Timeout, at most 25 seconds. Turn on Run in App under Show More for larger inputs and longer runs: the app opens with a progress screen and hands the result back to the shortcut."),
        Topic(id: "share", title: "Share sheet, Lock Screen and Action Button",
              body: "Share JSON text or a .json file to JQ for Shortcuts to open it in the Playground or run a saved filter on it. Add the Open Playground or Run Saved Filter on Clipboard controls to the Lock Screen or Control Center, or set the Action Button to Open Playground in Settings."),
        Topic(id: "errors", title: "When a run fails",
              body: "Every error names the position or the value involved and suggests one next step. In the Playground, the part of the filter that failed is underlined, and results from before the error stay visible."),
        Topic(id: "privacy", title: "Privacy",
              body: "Filters run on this device. The app has no accounts and makes no network requests, so your JSON never leaves the device. Input history is off unless you turn it on in Settings."),
    ]

    var body: some View {
        List(topics) { topic in
            VStack(alignment: .leading, spacing: 6) {
                Text(topic.title)
                    .font(.headline)
                Text(topic.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Help")
    }
}
