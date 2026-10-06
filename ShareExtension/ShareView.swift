import JQEngine
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Reads the shared JSON and runs the two share sheet choices.
@MainActor
@Observable
final class ShareModel {
    enum Content {
        case loading
        /// The shared input: a file copied out of the share sheet, or text.
        case ready(file: URL?, data: Data?, name: String?, byteCount: Int)
        case failed(String)
    }

    private(set) var content: Content = .loading
    private(set) var filters: [SavedFilter] = []
    private(set) var outcome: FilterOutcome?
    private(set) var runningFilter: SavedFilter?
    private(set) var isRunning = false
    /// Set after Open in Playground when the app could not be opened.
    private(set) var savedForLater = false
    /// Why Open in Playground could not hand the input over.
    private(set) var openError: String?

    private let items: [NSExtensionItem]
    private let openApp: (URL) -> Bool
    private let complete: () -> Void
    /// The shared file, copied out of the share sheet's temporary location.
    @ObservationIgnored private var temporaryCopy: URL?

    init(items: [NSExtensionItem], openApp: @escaping (URL) -> Bool, complete: @escaping () -> Void) {
        self.items = items
        self.openApp = openApp
        self.complete = complete
    }

    /// Ends the share sheet. No input stays behind (R2.11).
    func finish() {
        removeTemporaryCopy()
        complete()
    }

    func removeTemporaryCopy() {
        if let temporaryCopy {
            try? FileManager.default.removeItem(at: temporaryCopy)
            self.temporaryCopy = nil
        }
    }

    func load() async {
        filters = SavedFilterStore.shared.all()
        let providers = items.flatMap { $0.attachments ?? [] }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.json.identifier) }) {
            await loadFile(provider, type: .json)
        } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            await loadText(provider)
        } else {
            content = .failed(String(localized: "Share JSON text or a .json file."))
        }
    }

    private func loadFile(_ provider: NSItemProvider, type: UTType) async {
        let name = provider.suggestedName.map { $0.hasSuffix(".json") ? $0 : $0 + ".json" }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let copied: Bool = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // The file only exists inside this callback, so copy it now.
                guard let url, (try? FileManager.default.copyItem(at: url, to: copy)) != nil else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: true)
            }
        }
        if copied {
            temporaryCopy = copy
            let size = (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            content = .ready(file: copy, data: nil, name: name, byteCount: size)
        } else {
            await loadText(provider, type: type)
        }
    }

    private func loadText(_ provider: NSItemProvider, type: UTType = .plainText) async {
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        if let data {
            content = .ready(file: nil, data: data, name: nil, byteCount: data.count)
        } else {
            content = .failed(String(localized: "The shared item could not be read."))
        }
    }

    // MARK: Open in Playground (R7.1)

    func openInPlayground() {
        guard case .ready(let file, let data, let name, let byteCount) = content else { return }
        openError = nil
        // The app reads the whole input, so a file it would refuse stays here.
        if byteCount > RunLimits.foregroundInputLimit {
            openError = FilterError.inputTooLarge(bytes: byteCount, limit: RunLimits.foregroundInputLimit,
                                                  context: .playground, canRunInApp: false).message
            return
        }
        do {
            if let file {
                try PlaygroundInbox.depositFile(at: file, name: name)
            } else if let data {
                try PlaygroundInbox.deposit(data, name: name)
            }
        } catch {
            openError = error.localizedDescription
            return
        }
        if openApp(AppDestination.sharedInput.url) {
            finish()
        } else {
            savedForLater = true
        }
    }

    // MARK: Run Saved Filter (R7.2)

    func run(_ filter: SavedFilter) async {
        guard case .ready(let file, let data, _, let byteCount) = content else { return }
        runningFilter = filter
        outcome = nil
        if let failure = InputCheck.failure(byteCount: byteCount, context: .shareExtension, canRunInApp: false) {
            outcome = .failure(failure)
            return
        }
        guard let input = data ?? file.flatMap({ try? Data(contentsOf: $0) }) else {
            outcome = .failure(.emptyInput)
            return
        }
        isRunning = true
        outcome = await FilterRunner.run(FilterRequest(
            filter: filter.filter,
            input: input,
            argumentsText: filter.argumentsJSON,
            context: .shareExtension
        ))
        isRunning = false
    }

    var resultText: String {
        guard let outcome, let runningFilter else { return "" }
        return ShortcutsOutput.values(for: outcome.results, mode: runningFilter.outputMode, sortKeys: false)
            .joined(separator: "\n")
    }

    func clearRun() {
        outcome = nil
        runningFilter = nil
    }
}

struct ShareView: View {
    let model: ShareModel
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.content {
                case .loading:
                    ProgressView()
                case .failed(let message):
                    ContentUnavailableView("Nothing to Open", systemImage: "doc.questionmark", description: Text(message))
                case .ready(_, _, let name, let byteCount):
                    if let filter = model.runningFilter {
                        result(for: filter)
                    } else {
                        choices(name: name, byteCount: byteCount)
                    }
                }
            }
            .navigationTitle("JQ for Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { model.finish() }
                }
            }
        }
    }

    private func choices(name: String?, byteCount: Int) -> some View {
        List {
            Section {
                Label(name ?? String(localized: "Shared text"), systemImage: "doc.text")
                Text(ByteCount.describe(byteCount))
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    model.openInPlayground()
                } label: {
                    Label("Open in Playground", systemImage: "curlybraces")
                }
                if let error = model.openError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if model.savedForLater {
                    Text("Open JQ for Shortcuts to see it in the Playground.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Run Saved Filter") {
                if model.filters.isEmpty {
                    Text("Save a filter in the app to run it from here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.filters) { filter in
                    Button {
                        Task { await model.run(filter) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(filter.name)
                            if !filter.summary.isEmpty {
                                Text(filter.summary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func result(for filter: SavedFilter) -> some View {
        List {
            Section(filter.name) {
                if model.isRunning {
                    ProgressView()
                } else if let error = model.outcome?.error {
                    Text(error.message)
                        .foregroundStyle(.red)
                } else {
                    let text = model.resultText
                    Text(text.isEmpty ? String(localized: "(no output)") : text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(60)
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
            Section {
                Button("Run Another Filter") {
                    copied = false
                    model.clearRun()
                }
            }
        }
    }
}
