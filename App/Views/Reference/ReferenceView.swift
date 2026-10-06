import SwiftUI

/// The Reference tab (R6.14): a searchable cheat sheet that works offline,
/// where every example runs in the Playground, and the known differences
/// from jq 1.7 (R4.12).
struct ReferenceView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let sections = app.content.cheatSheet(matching: query)
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.entries) { entry in
                            CheatSheetRow(entry: entry)
                        }
                    }
                }
                if sections.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                if query.isEmpty {
                    Section {
                        ForEach(app.content.differences) { difference in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(difference.title)
                                    .font(.body.weight(.medium))
                                Text(difference.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Differences from jq 1.7")
                    }
                }
            }
            .navigationTitle("Reference")
            .searchable(text: $query, prompt: "Search examples")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        app.sheet = .settings
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
        }
    }
}

private struct CheatSheetRow: View {
    @Environment(AppModel.self) private var app
    let entry: CheatSheetEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title)
                .font(.body.weight(.medium))
            Text(entry.filter)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tint)
                .textSelection(.enabled)
            Text(entry.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input")
                        .font(.caption.weight(.semibold))
                    Text(entry.input)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(10)
                    if let arguments = entry.arguments {
                        Text("Arguments")
                            .font(.caption.weight(.semibold))
                        Text(arguments)
                            .font(.system(.caption, design: .monospaced))
                    }
                    Text("Output")
                        .font(.caption.weight(.semibold))
                    Text(entry.expected.isEmpty ? String(localized: "(no output)") : entry.expected.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(10)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button {
                    app.openInPlayground(filter: entry.filter, input: entry.input, arguments: entry.arguments ?? "",
                                         name: entry.title)
                } label: {
                    Label("Run in Playground", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("run-\(entry.id)")
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    Label(isExpanded ? "Hide Example" : "Show Example", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
