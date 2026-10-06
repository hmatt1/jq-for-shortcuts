import SwiftUI
import WidgetKit

/// The Library (R6.12): Saved Filters to open, edit, duplicate and delete,
/// the Presets (R6.13), the example shortcut gallery (R10.9), and recent
/// runs when input history is on (R6.15).
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var filters: [SavedFilter] = []
    @State private var editing: SavedFilter?
    @State private var pendingDelete: SavedFilter?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if filters.isEmpty {
                        Text("Filters you save in the Playground appear here and in the Run Saved Filter action.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filters) { filter in
                        Button {
                            app.openSavedFilter(filter)
                        } label: {
                            SavedFilterRow(filter: filter)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            // No destructive role: it removes the row before
                            // the confirmation dialog has an answer.
                            Button {
                                pendingDelete = filter
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                            Button {
                                duplicate(filter)
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            .tint(.indigo)
                        }
                        .contextMenu {
                            Button {
                                app.openSavedFilter(filter)
                            } label: {
                                Label("Open in Playground", systemImage: "curlybraces")
                            }
                            Button {
                                editing = filter
                            } label: {
                                Label("Edit Details", systemImage: "pencil")
                            }
                            Button {
                                duplicate(filter)
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            Button(role: .destructive) {
                                pendingDelete = filter
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("savedFilter-\(filter.name)")
                    }
                } header: {
                    Text("Saved Filters")
                }

                Section {
                    Button {
                        app.sheet = .gallery
                    } label: {
                        Label("Example Shortcuts", systemImage: "square.grid.2x2")
                    }
                    .accessibilityIdentifier("openGallery")
                    if app.isInputHistoryEnabled {
                        NavigationLink {
                            HistoryList()
                        } label: {
                            Label("Recent Runs from Shortcuts", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }

                Section {
                    ForEach(app.content.presets) { preset in
                        Button {
                            app.openInPlayground(filter: preset.filter, input: preset.input,
                                                 outputMode: preset.outputMode, name: preset.name)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name)
                                    .font(.body.weight(.medium))
                                Text(preset.summary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Text(preset.filter)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("preset-\(preset.id)")
                    }
                } header: {
                    Text("Presets")
                } footer: {
                    Text("A preset opens in the Playground with a sample input that shows what it does.")
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        app.sheet = .settings
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(item: $editing) { filter in
                SavedFilterEditor(filter: filter) { reload() }
            }
            .confirmationDialog(
                "Delete \u{201C}\(pendingDelete?.name ?? "")\u{201D}?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let filter = pendingDelete { delete(filter) }
                }
            } message: {
                Text("Shortcuts that use this filter stop with an error that names it.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear { reload() }
            .onChange(of: app.dismissalGeneration) {
                editing = nil
                pendingDelete = nil
                errorMessage = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: SavedFilterStore.didChangeNotification)) { _ in
                reload()
            }
        }
    }

    private func reload() {
        filters = SavedFilterStore.shared.all()
    }

    private func duplicate(_ filter: SavedFilter) {
        do {
            try SavedFilterStore.shared.duplicate(id: filter.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ filter: SavedFilter) {
        do {
            try SavedFilterStore.shared.delete(id: filter.id)
            if app.playground.savedFilterID == filter.id {
                app.playground.detachFromSavedFilter()
            }
            ControlCenter.shared.reloadAllControls()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
        pendingDelete = nil
    }
}

private struct SavedFilterRow: View {
    let filter: SavedFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(filter.name)
                .font(.body.weight(.medium))
            if !filter.summary.isEmpty {
                Text(filter.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(filter.filter)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Rename a Saved Filter, change its description or output mode.
struct SavedFilterEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var filter: SavedFilter
    var onSave: () -> Void
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $filter.name)
                    TextField("Description (optional)", text: $filter.summary, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section {
                    Picker("Output", selection: $filter.outputMode) {
                        ForEach(OutputMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } footer: {
                    Text("Run Saved Filter uses this output mode unless the action sets another.")
                }
                Section("Filter") {
                    Text(filter.filter)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try SavedFilterStore.shared.save(filter, sampleInput: nil)
                            ControlCenter.shared.reloadAllControls()
                            onSave()
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}
