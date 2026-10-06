import SwiftUI

/// The three tabs (R6.1), and everything that can appear over them.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("Playground", systemImage: "curlybraces", value: AppModel.Tab.playground) {
                PlaygroundView()
            }
            Tab("Library", systemImage: "books.vertical", value: AppModel.Tab.library) {
                LibraryView()
            }
            Tab("Reference", systemImage: "book", value: AppModel.Tab.reference) {
                ReferenceView()
            }
        }
        .sheet(item: $app.sheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView()
            case .gallery:
                GalleryView()
            case .clipboardRunner(let request):
                ClipboardRunnerView(request: request)
            }
        }
        .fullScreenCover(item: $app.activeRun) { progress in
            RunInAppView(progress: progress)
        }
        .alert("Add an example shortcut?", isPresented: $app.isGalleryOfferPresented) {
            Button("Show Examples") {
                app.sheet = .gallery
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Your filter is in the Run Saved Filter action now. The gallery has six example shortcuts to start from.")
        }
    }
}
