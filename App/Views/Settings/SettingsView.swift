import SwiftUI

/// Settings, Help and About: the app's only screens besides the three tabs
/// (R6.16).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var historySize = 0
    @State private var historyCount = 0

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section {
                    Toggle("Input History", isOn: $app.isInputHistoryEnabled)
                        .accessibilityIdentifier("historyToggle")
                    if historyCount > 0 {
                        LabeledContent("Stored") {
                            Text("\(historyCount) runs, \(ByteCount.describe(historySize))")
                        }
                        Button("Clear Input History", role: .destructive) {
                            InputHistoryStore.shared.clear()
                            refresh()
                        }
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Off by default. When on, the app keeps the filter, arguments and input of the last \(InputHistoryStore.maximumEntries) runs from Shortcuts, so you can open them in the Playground. Inputs over \(ByteCount.describe(InputHistoryStore.maximumInputBytes)) are not kept, history stays out of device backups, and turning it off deletes it.")
                }

                Section {
                    NavigationLink {
                        HelpView()
                    } label: {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: app.isInputHistoryEnabled) {
                refresh()
            }
            .onAppear { refresh() }
        }
    }

    private func refresh() {
        let entries = InputHistoryStore.shared.entries()
        historyCount = entries.count
        historySize = entries.filter(\.inputStored).reduce(0) { $0 + $1.inputByteCount }
    }
}
