import SwiftUI

/// Recent runs from Shortcuts, when input history is on (R6.15). Opening one
/// loads its filter, arguments and input into the Playground.
struct HistoryList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        List {
            if entries.isEmpty {
                Text("Runs of Run JSON Filter and Run Saved Filter appear here while input history is on.")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                Button {
                    app.openHistoryEntry(entry)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.actionName)
                                .font(.body.weight(.medium))
                            Spacer()
                            Text(entry.date, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.filter)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(ByteCount.describe(entry.inputByteCount))
                            if !entry.inputStored {
                                Text("input not kept")
                            }
                            if entry.errorMessage != nil {
                                Label("Failed", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Recent Runs")
        .onAppear {
            entries = InputHistoryStore.shared.entries()
        }
        .onReceive(NotificationCenter.default.publisher(for: InputHistoryStore.didChangeNotification)) { _ in
            entries = InputHistoryStore.shared.entries()
        }
    }
}

/// Recent runs as a sheet, from the Playground's input pane.
struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HistoryList()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }
}
