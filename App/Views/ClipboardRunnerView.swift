import JQEngine
import SwiftUI
import UIKit

/// Runs a Saved Filter on the copied text and shows the result with a Copy
/// button (R7.4). The system Paste button reads the clipboard without a
/// permission prompt, which settles open question 8.
struct ClipboardRunnerView: View {
    @Environment(\.dismiss) private var dismiss
    let request: ClipboardRequest
    @State private var filters: [SavedFilter] = []
    @State private var selectedID: UUID?
    @State private var outcome: FilterOutcome?
    @State private var isRunning = false
    @State private var copied = false
    /// R8.13, when the control's filter was deleted after it was set up.
    @State private var missingFilterMessage: String?

    private var selected: SavedFilter? {
        filters.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Saved Filter") {
                    if let missingFilterMessage {
                        Text(missingFilterMessage)
                            .foregroundStyle(.red)
                    }
                    if filters.isEmpty {
                        Text("Save a filter in the Playground first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Filter", selection: $selectedID) {
                            ForEach(filters) { filter in
                                Text(filter.name).tag(Optional(filter.id))
                            }
                        }
                        if let selected {
                            Text(selected.filter)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
                Section {
                    PasteButton(payloadType: String.self) { strings in
                        let text = strings.first ?? ""
                        Task { @MainActor in
                            await run(on: text)
                        }
                    }
                    .disabled(selected == nil || isRunning)
                } footer: {
                    Text("Paste runs the filter on the text you copied.")
                }
                if isRunning {
                    Section {
                        ProgressView()
                    }
                }
                if let outcome {
                    resultSection(outcome)
                }
            }
            .navigationTitle("Run on Clipboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear(perform: loadFilters)
        }
    }

    private func loadFilters() {
        let store = SavedFilterStore.shared
        filters = store.all()
        selectedID = filters.first?.id
        guard let requested = request.savedFilterID else { return }
        if filters.contains(where: { $0.id == requested }) {
            selectedID = requested
        } else if let record = store.deletedRecord(id: requested) {
            missingFilterMessage = FilterError.savedFilterDeleted(name: record.name).message
        } else {
            missingFilterMessage = FilterError.savedFilterMissing.message
        }
    }

    @ViewBuilder
    private func resultSection(_ outcome: FilterOutcome) -> some View {
        if let error = outcome.error {
            Section("Error") {
                Text(error.message)
                    .foregroundStyle(.red)
            }
        } else {
            let text = resultText(outcome)
            Section("Result") {
                Text(text.isEmpty ? String(localized: "(no output)") : text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(40)
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("copyClipboardResult")
            }
        }
    }

    private func resultText(_ outcome: FilterOutcome) -> String {
        guard let selected else { return "" }
        return ShortcutsOutput.values(for: outcome.results, mode: selected.outputMode, sortKeys: false)
            .joined(separator: "\n")
    }

    private func run(on text: String) async {
        guard let selected else { return }
        copied = false
        if text.allSatisfy(\.isWhitespace) {
            outcome = .failure(.clipboardEmpty)
            return
        }
        isRunning = true
        outcome = await FilterRunner.run(FilterRequest(
            filter: selected.filter,
            input: Data(text.utf8),
            argumentsText: selected.argumentsJSON,
            context: .foreground
        ))
        isRunning = false
    }
}
