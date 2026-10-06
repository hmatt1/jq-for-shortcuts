import Foundation
import JQEngine
import Observation

/// The Playground's state (R6.2). The result updates as the person types,
/// and a new keystroke cancels the run before it (R1.2, R9.10).
@MainActor
@Observable
final class PlaygroundModel {
    /// The input as editable text, or a large file shown read-only.
    enum Input: Equatable {
        case text(String)
        case file(name: String, data: Data)

        var data: Data {
            switch self {
            case .text(let text): return Data(text.utf8)
            case .file(_, let data): return data
            }
        }
    }

    /// The input after parsing, for runs and for the tree browser.
    enum ParsedInput {
        case values([JSON])
        case failure(FilterError)
    }

    var filter: String {
        get { filterText }
        set {
            guard newValue != filterText else { return }
            filterText = newValue
            scheduleRun()
        }
    }
    private var filterText = ""
    /// The filter editor's selection, in UTF-16 units, where the tree browser
    /// inserts paths (R6.4).
    var filterSelection = NSRange(location: 0, length: 0)

    private(set) var input: Input = .text("")
    var argumentsText: String {
        get { argumentsStorage }
        set {
            guard newValue != argumentsStorage else { return }
            argumentsStorage = newValue
            scheduleRun()
        }
    }
    private var argumentsStorage = ""
    var outputMode: OutputMode = .itemPerResult
    var slurp: Bool {
        get { slurpStorage }
        set {
            guard newValue != slurpStorage else { return }
            slurpStorage = newValue
            scheduleRun()
        }
    }
    private var slurpStorage = false
    var sortKeys = false

    private(set) var outcome: FilterOutcome?
    private(set) var isRunning = false
    private(set) var parsedInput: ParsedInput?
    /// The Saved Filter being edited, when the Playground was opened from one.
    private(set) var savedFilterID: UUID?
    /// The name shown in the title: a Saved Filter, preset or shared file.
    private(set) var title: String?

    private var runTask: Task<Void, Never>?
    private var parseTask: Task<Void, Never>?

    init() {
        let sample = ContentLibrary.shared.sample
        load(filter: sample.filter, input: sample.input, arguments: "", outputMode: sample.outputMode,
             savedFilterID: nil, name: nil)
    }

    // MARK: Input

    var inputText: String {
        get {
            if case .text(let text) = input { return text }
            return ""
        }
        set {
            input = .text(newValue)
            // Typing in a large input would otherwise parse it on every key.
            parseInput(after: 150_000_000)
        }
    }

    var isInputEditable: Bool {
        if case .text = input { return true }
        return false
    }

    var inputByteCount: Int {
        switch input {
        case .text(let text): return text.utf8.count
        case .file(_, let data): return data.count
        }
    }

    /// Loads shared, imported or pasted content (R6.3). Small UTF-8 text
    /// stays editable; anything larger opens read-only.
    func loadInput(_ data: Data, name: String?) {
        if data.count <= RunLimits.editableInputLimit, let text = String(data: data, encoding: .utf8) {
            input = .text(text)
        } else {
            input = .file(name: name ?? String(localized: "Imported file"), data: data)
        }
        if let name { title = name }
        parseInput()
    }

    func clearInput() {
        input = .text("")
        parseInput()
    }

    // MARK: Loading

    func load(filter: String, input text: String, arguments: String, outputMode: OutputMode,
              savedFilterID: UUID?, name: String?) {
        self.savedFilterID = savedFilterID
        self.title = name
        self.outputMode = outputMode
        self.argumentsText = arguments
        self.filter = filter
        self.filterSelection = NSRange(location: (filter as NSString).length, length: 0)
        self.input = .text(text)
        parseInput()
    }

    func detachFromSavedFilter() {
        savedFilterID = nil
        title = nil
    }

    // MARK: Editing

    /// Replaces the selection in the filter with `text`, as the tree browser
    /// and the cheat sheet do.
    func insertIntoFilter(_ text: String) {
        let current = filter as NSString
        let location = min(filterSelection.location, current.length)
        let length = min(filterSelection.length, current.length - location)
        filter = current.replacingCharacters(in: NSRange(location: location, length: length), with: text)
        filterSelection = NSRange(location: location + (text as NSString).length, length: 0)
    }

    /// Adds a missing `$name` to Arguments, for the undefined-variable error.
    func addArgument(_ name: String) {
        argumentsText = FilterArguments.adding(name, to: argumentsText)
    }

    // MARK: Running

    func runNow() {
        scheduleRun(delay: 0)
    }

    private func parseInput(after nanoseconds: UInt64 = 0) {
        parseTask?.cancel()
        runTask?.cancel()
        parsedInput = nil
        isRunning = true
        let snapshot = input
        parseTask = Task { [weak self] in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
            }
            let parsed = await Self.parse(snapshot.data)
            guard !Task.isCancelled, let self else { return }
            self.parsedInput = parsed
            self.scheduleRun(delay: 0)
        }
    }

    private static func parse(_ data: Data) async -> ParsedInput {
        if let failure = InputCheck.failure(byteCount: data.count, context: .playground, canRunInApp: false) {
            return .failure(failure)
        }
        do {
            let values = try await JQThread.run { try JSONParser.parseAll(data) }
            return values.isEmpty ? .failure(.emptyInput) : .values(values)
        } catch let error as JSONParseError {
            return .failure(FilterErrorMapper.input(error))
        } catch {
            return .failure(.cancelled)
        }
    }

    private func scheduleRun(delay nanoseconds: UInt64 = 60_000_000) {
        runTask?.cancel()
        guard let parsedInput else { return }
        isRunning = true
        if case .failure(let error) = parsedInput {
            outcome = .failure(error)
            isRunning = false
            return
        }
        guard case .values(let values) = parsedInput else { return }
        let request = FilterRequest(
            filter: filter,
            input: Data(),
            argumentsText: argumentsText,
            slurp: slurp,
            timeout: RunLimits.defaultTimeout,
            context: .playground,
            canRunInApp: false,
            collectMessages: true,
            resultLimit: RunLimits.playgroundResultLimit,
            parsedInput: values
        )
        runTask = Task { [weak self] in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled else { return }
            let outcome = await FilterRunner.run(request)
            guard !Task.isCancelled, let self else { return }
            self.outcome = outcome
            self.isRunning = false
        }
    }

    // MARK: Results

    /// What Shortcuts would receive in the current output mode.
    var shortcutsItems: [ShortcutsItem] {
        guard let outcome else { return [] }
        return ShortcutsOutput.items(for: outcome.results, mode: outputMode, sortKeys: sortKeys)
    }

    /// The results as text to copy.
    var copyText: String {
        shortcutsItems.map(\.text).joined(separator: "\n")
    }

    // MARK: Saving (R1.3)

    var sampleInputForSaving: String? {
        switch input {
        case .text(let text): return text
        case .file(_, let data):
            return data.count <= RunLimits.sampleInputLimit ? String(data: data, encoding: .utf8) : nil
        }
    }

    @discardableResult
    func save(name: String, summary: String, asNew: Bool) throws -> SavedFilter {
        let store = SavedFilterStore.shared
        var saved: SavedFilter
        if !asNew, let id = savedFilterID, let existing = store.filter(id: id) {
            saved = existing
        } else {
            saved = SavedFilter(name: name, filter: filter)
        }
        saved.name = name
        saved.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.filter = filter
        saved.outputMode = outputMode
        saved.argumentsJSON = argumentsText
        let result = try store.save(saved, sampleInput: sampleInputForSaving ?? "")
        savedFilterID = result.id
        title = result.name
        return result
    }
}
