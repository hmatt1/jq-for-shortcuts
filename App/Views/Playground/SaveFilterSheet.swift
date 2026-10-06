import SwiftUI
import WidgetKit

/// Save Filter (R1.3): a name, an optional description, and the current
/// input as the sample input. The filter appears in the Run Saved Filter
/// picker right away (R1.4), because the picker reads the same store.
struct SaveFilterSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    private var editing: SavedFilter? {
        app.playground.savedFilterID.flatMap { SavedFilterStore.shared.filter(id: $0) }
    }

    var body: some View {
        @Bindable var model = app.playground
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .accessibilityIdentifier("saveFilterName")
                    TextField("Description (optional)", text: $summary, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    Text("The name is how the filter appears in Run Saved Filter. The description shows below it.")
                }
                Section {
                    Picker("Output", selection: $model.outputMode) {
                        ForEach(OutputMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    LabeledContent("Filter") {
                        Text(model.filter)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(3)
                    }
                } footer: {
                    Text(sampleFooter)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(editing == nil ? "Save Filter" : "Update Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Save" : "Update") { save(asNew: false) }
                        .disabled(name.allSatisfy(\.isWhitespace))
                        .accessibilityIdentifier("confirmSave")
                }
                if editing != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Save as New Filter") { save(asNew: true) }
                            .disabled(name.allSatisfy(\.isWhitespace))
                    }
                }
            }
            .onAppear {
                if let editing {
                    name = editing.name
                    summary = editing.summary
                } else {
                    name = app.playground.title ?? ""
                    isNameFocused = true
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var sampleFooter: String {
        let model = app.playground
        if model.sampleInputForSaving == nil || model.inputByteCount > RunLimits.sampleInputLimit {
            return String(localized: "The input is over \(ByteCount.describe(RunLimits.sampleInputLimit)), so it is not kept as the sample input.")
        }
        return String(localized: "The current input is kept as the sample input, so the filter opens with it in the Playground.")
    }

    private func save(asNew: Bool) {
        var finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownID = asNew ? nil : editing?.id
        if let existing = SavedFilterStore.shared.filter(named: finalName), existing.id != ownID {
            // Two filters with one name would be hard to tell apart in the picker.
            finalName = SavedFilterStore.shared.uniqueName(finalName)
        }
        do {
            try app.playground.save(name: finalName, summary: summary, asNew: asNew)
            ControlCenter.shared.reloadAllControls()
            dismiss()
            let app = self.app
            Task { @MainActor in
                // Let the sheet finish closing before the gallery offer appears.
                try? await Task.sleep(nanoseconds: 600_000_000)
                app.didSaveFilter()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
