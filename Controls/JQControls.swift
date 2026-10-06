import AppIntents
import SwiftUI
import WidgetKit

/// Lock Screen and Control Center controls (R7.4). Both open the app: one at
/// the Playground, one at the clipboard runner for a chosen Saved Filter.
@main
struct JQControls: WidgetBundle {
    var body: some Widget {
        OpenPlaygroundControl()
        RunSavedFilterControl()
    }
}

struct OpenPlaygroundControl: ControlWidget {
    static let kind = "com.hmatt1.jqforshortcuts.controls.open-playground"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenAppScreenIntent(screen: .playground)) {
                Label("Playground", systemImage: "curlybraces")
            }
        }
        .displayName("Open Playground")
        .description("Opens the JQ for Shortcuts Playground.")
    }
}

struct RunSavedFilterControl: ControlWidget {
    static let kind = "com.hmatt1.jqforshortcuts.controls.run-saved-filter"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, intent: RunSavedFilterControlConfiguration.self) { configuration in
            ControlWidgetButton(action: RunSavedFilterOnClipboardIntent(filter: configuration.savedFilter ?? SavedFilterEntity.chooseInApp)) {
                Label(configuration.savedFilter?.name ?? String(localized: "Run Filter"), systemImage: "doc.on.clipboard")
            }
        }
        .displayName("Run Saved Filter on Clipboard")
        .description("Runs a saved filter on the text you copied and shows the result to copy.")
        .promptsForUserConfiguration()
    }
}
