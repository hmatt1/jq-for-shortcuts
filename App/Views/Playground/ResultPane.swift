import JQEngine
import SwiftUI
import UIKit

/// What the filter returns, shown the way the selected output mode hands it
/// to Shortcuts (R5), with `debug` and `stderr` output in a Debug area (R4.9).
struct ResultPane: View {
    @Environment(AppModel.self) private var app

    /// Each result is shown up to this many characters.
    private static let displayLimit = 20_000

    var body: some View {
        let model = app.playground
        List {
            if let outcome = model.outcome {
                Section {
                    let items = model.shortcutsItems
                    if items.isEmpty && model.outputMode.isTextMode == false {
                        Text(outcome.error == nil ? "No results. A filter with no output gives Shortcuts an empty list." : "No results before the error.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        ResultRow(index: index, item: item, mode: model.outputMode, displayLimit: Self.displayLimit)
                    }
                    // R4.4: the results from before an error, then the error.
                    if let error = outcome.error, !outcome.results.isEmpty {
                        Label {
                            Text(error.message)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                        .font(.callout)
                    }
                    if outcome.truncated {
                        Text("Showing the first \(outcome.results.count) results. Shortcuts gets all of them.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(model.outputMode.title)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = model.copyText
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .disabled(model.shortcutsItems.isEmpty)
                        .accessibilityIdentifier("copyResults")
                    }
                }
                if !outcome.messages.isEmpty {
                    Section("Debug") {
                        ForEach(Array(outcome.messages.enumerated()), id: \.offset) { _, message in
                            Text(Self.text(for: message))
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("resultPane")
    }

    static func text(for message: JQMessage) -> String {
        switch message {
        case .debug(let text): return text
        case .stderr(let text): return text
        }
    }
}

private struct ResultRow: View {
    let index: Int
    let item: ShortcutsItem
    let mode: OutputMode
    let displayLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !mode.isTextMode {
                Text("\(index + 1) · \(item.type.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(displayText)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// Objects and lists are shown indented; Shortcuts gets them compact.
    private var displayText: String {
        var text = item.text
        if !mode.isTextMode, item.type == .dictionary || item.type == .list,
           let value = try? JSONParser.parseSingle(item.text) {
            text = JSONWriter.string(value, options: .pretty)
        }
        if text.isEmpty {
            return mode.isTextMode ? String(localized: "(empty text)") : String(localized: "(empty)")
        }
        if text.count > displayLimit {
            return String(text.prefix(displayLimit)) + "\n…"
        }
        return text
    }
}
