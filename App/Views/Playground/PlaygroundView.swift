import SwiftUI
import UniformTypeIdentifiers

/// The Playground (R6.2): a Filter pane, a Result pane, and an Input pane
/// with the tree browser and the Arguments editor. On a phone the lower half
/// switches between them; on a wide screen the input sits beside the filter.
struct PlaygroundView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var pane: Pane = .result
    @State private var sidePane: Pane = .input
    @State private var isSaveSheetPresented = false

    enum Pane: String, CaseIterable, Identifiable {
        case result
        case input
        case tree
        case arguments

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .result: return "Result"
            case .input: return "Input"
            case .tree: return "Tree"
            case .arguments: return "Arguments"
            }
        }
    }

    var body: some View {
        let model = app.playground
        NavigationStack {
            Group {
                if horizontalSizeClass == .regular {
                    wideLayout
                } else {
                    compactLayout
                }
            }
            .navigationTitle(model.title ?? String(localized: "Playground"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $isSaveSheetPresented) {
                SaveFilterSheet()
            }
            .onChange(of: app.dismissalGeneration) {
                isSaveSheetPresented = false
            }
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            FilterSection(onTreeRequested: { pane = .tree })
            Picker("Pane", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            paneContent(pane)
                .frame(maxHeight: .infinity)
        }
    }

    private var wideLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker("Input pane", selection: $sidePane) {
                    Text(Pane.input.title).tag(Pane.input)
                    Text(Pane.tree.title).tag(Pane.tree)
                    Text(Pane.arguments.title).tag(Pane.arguments)
                }
                .pickerStyle(.segmented)
                .padding()
                paneContent(sidePane)
            }
            .frame(maxWidth: .infinity)
            Divider()
            VStack(spacing: 0) {
                FilterSection(onTreeRequested: { sidePane = .tree })
                Divider()
                ResultPane()
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func paneContent(_ pane: Pane) -> some View {
        switch pane {
        case .result: ResultPane()
        case .input: InputPane()
        case .tree: TreeBrowserView()
        case .arguments: ArgumentsPane()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = app.playground
        ToolbarItem(placement: .topBarLeading) {
            Button {
                app.sheet = .settings
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Output", selection: $model.outputMode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Slurp", isOn: $model.slurp)
                Toggle("Sort Keys", isOn: $model.sortKeys)
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            Button {
                isSaveSheetPresented = true
            } label: {
                Label("Save Filter", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("saveFilter")
        }
    }
}
