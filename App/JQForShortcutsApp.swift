import AppIntents
import SwiftUI

@main
struct JQForShortcutsApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let model: AppModel

    init() {
        // Actions can run in the background before any window exists, so
        // everything they need is set up here rather than in a view.
        model = AppModel.shared
        model.installIntentNavigation()
        JQShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in
                    model.handle(url: url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.becameActive()
                    }
                }
        }
    }
}
