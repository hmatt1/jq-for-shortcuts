import SwiftUI
import UIKit

/// The example shortcut gallery (R10): six shortcuts from the six jobs the
/// app is built for. Each shows what it does, a sample input, the steps,
/// and the values to change (R10.8).
struct GalleryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.content.gallery) { entry in
                        NavigationLink {
                            GalleryDetailView(entry: entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title)
                                    .font(.body.weight(.medium))
                                Text(entry.summary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("gallery-\(entry.id)")
                    }
                } footer: {
                    Text("Each example lists its actions in order. Build it in the Shortcuts app, or add it from the link when one is available.")
                }
            }
            .navigationTitle("Example Shortcuts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct GalleryDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let entry: GalleryEntry
    @State private var copied = false

    /// A signed .shortcut file exported from the Shortcuts app and added to
    /// App/Resources/Shortcuts, named after the entry's id (R10.7).
    private var bundledShortcut: URL? {
        Bundle.main.url(forResource: entry.id, withExtension: "shortcut")
    }

    var body: some View {
        List {
            Section {
                Text(entry.summary)
            }
            Section("Steps") {
                ForEach(Array(entry.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(step)
                    }
                }
            }
            Section {
                Text(entry.filter)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = entry.filter
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Filter", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            } header: {
                Text("Filter")
            } footer: {
                if let note = entry.filterNote {
                    Text(note)
                }
            }
            Section("Change These") {
                ForEach(entry.valuesToChange, id: \.self) { value in
                    Label(value, systemImage: "pencil")
                }
            }
            Section("Sample Input") {
                Text(entry.sampleInput)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(14)
                    .textSelection(.enabled)
                Text("Result: \(entry.expected.joined(separator: "\n"))")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            Section {
                Button {
                    app.openInPlayground(filter: entry.filter, input: entry.sampleInput,
                                         outputMode: entry.outputMode, name: entry.title)
                } label: {
                    Label("Try in Playground", systemImage: "curlybraces")
                }
                if let file = bundledShortcut {
                    ShareLink(item: file) {
                        Label("Add to Shortcuts", systemImage: "square.and.arrow.down.on.square")
                    }
                } else if let link = entry.shortcutURL {
                    Button {
                        openURL(link)
                    } label: {
                        Label("Add to Shortcuts", systemImage: "square.and.arrow.down.on.square")
                    }
                } else if let shortcuts = URL(string: "shortcuts://create-shortcut") {
                    Button {
                        openURL(shortcuts)
                    } label: {
                        Label("Open Shortcuts to Build It", systemImage: "arrow.up.forward.app")
                    }
                }
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
