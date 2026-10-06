import SwiftUI
import UniformTypeIdentifiers

/// The input: pasted, imported from Files, shared from another app (R6.3),
/// or loaded from a recent Shortcuts run when input history is on (R6.15).
struct InputPane: View {
    @Environment(AppModel.self) private var app
    @State private var isImporterPresented = false
    @State private var isHistoryPresented = false
    @State private var importError: String?

    var body: some View {
        @Bindable var model = app.playground
        VStack(alignment: .leading, spacing: 8) {
            actions
            switch model.input {
            case .text:
                CodeEditor(
                    text: $model.inputText,
                    selection: nil,
                    language: .json,
                    errorRange: nil,
                    accessibilityLabel: String(localized: "Input JSON"),
                    editorIdentifier: "inputEditor"
                )
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            case .file(let name, let data):
                LargeInputSummary(name: name, data: data)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.json, .plainText, .text, .data]) { result in
            importFile(result)
        }
        .sheet(isPresented: $isHistoryPresented) {
            HistoryView()
        }
        .onChange(of: app.dismissalGeneration) {
            isImporterPresented = false
            isHistoryPresented = false
            importError = nil
        }
        .alert("Could not open the file", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in
                        app.playground.loadInput(Data(text.utf8), name: nil)
                    }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Import", systemImage: "folder")
                }
                Button {
                    let sample = app.content.sample
                    app.playground.loadInput(Data(sample.input.utf8), name: nil)
                } label: {
                    Label("Sample", systemImage: "doc.text")
                }
                if app.isInputHistoryEnabled {
                    Button {
                        isHistoryPresented = true
                    } label: {
                        Label("Recent Runs", systemImage: "clock.arrow.circlepath")
                    }
                }
                Button(role: .destructive) {
                    app.playground.clearInput()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.vertical, 2)
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > RunLimits.foregroundInputLimit {
                    importError = FilterError.inputTooLarge(bytes: size, limit: RunLimits.foregroundInputLimit,
                                                            context: .playground, canRunInApp: false).message
                    return
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                app.playground.loadInput(data, name: url.lastPathComponent)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}

/// A large input opens read-only, so the editor never holds megabytes of text.
private struct LargeInputSummary: View {
    let name: String
    let data: Data

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(name, systemImage: "doc")
                .font(.headline)
            Text("\(ByteCount.describe(data.count)), too large to edit here. Filters run on the whole file.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(String(decoding: data.prefix(2_000), as: UTF8.self))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
