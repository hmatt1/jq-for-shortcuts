import AppIntents
import Foundation
import UniformTypeIdentifiers

/// R3.2: runs a Saved Filter picked by name (R3.35). The output mode defaults
/// to the Saved Filter's own mode.
struct RunSavedFilterIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Saved Filter"
    static let description = IntentDescription(
        "Runs one of your saved jq filters on JSON and returns the results.",
        categoryName: "JSON",
        searchKeywords: ["jq", "json", "filter", "saved", "query"],
        resultValueName: "Filter Results"
    )
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Saved Filter")
    var savedFilter: SavedFilterEntity

    @Parameter(
        title: "Input",
        description: "JSON text, a JSON file, a dictionary or a list.",
        supportedContentTypes: [.json, .plainText, .text, .data],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var input: [IntentFile]

    @Parameter(title: "Output Mode", description: "Leave empty to use the saved filter's own output mode.")
    var outputMode: OutputModeOption?

    @Parameter(
        title: "Arguments",
        description: "A dictionary. Each key becomes a $variable in the filter, and replaces the value saved with the filter.",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none, multiline: true, autocorrect: false, smartQuotes: false, smartDashes: false
        )
    )
    var arguments: String?

    @Parameter(title: "Slurp", description: "Runs the filter once on a list of every input value.", default: false)
    var slurp: Bool

    @Parameter(title: "Sort Keys", description: "Sorts the keys of every object in the results.", default: false)
    var sortKeys: Bool

    @Parameter(
        title: "Timeout",
        description: "Seconds before the filter stops, from 1 to 600. A run in the background stops after 25 seconds at most, so turn on Run in App for longer runs.",
        default: 10
    )
    var timeout: Int

    @Parameter(title: "Run in App", description: "Opens the app with a progress screen, for large inputs and long runs.", default: false)
    var runInApp: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$arguments, .hasAnyValue) {
            When(\.$outputMode, .hasAnyValue) {
                Summary("Run \(\.$savedFilter) on \(\.$input) with \(\.$arguments), output \(\.$outputMode)") {
                    \.$slurp
                    \.$sortKeys
                    \.$timeout
                    \.$runInApp
                }
            } otherwise: {
                Summary("Run \(\.$savedFilter) on \(\.$input) with \(\.$arguments)") {
                    \.$outputMode
                    \.$slurp
                    \.$sortKeys
                    \.$timeout
                    \.$runInApp
                }
            }
        } otherwise: {
            When(\.$outputMode, .hasAnyValue) {
                Summary("Run \(\.$savedFilter) on \(\.$input), output \(\.$outputMode)") {
                    \.$arguments
                    \.$slurp
                    \.$sortKeys
                    \.$timeout
                    \.$runInApp
                }
            } otherwise: {
                Summary("Run \(\.$savedFilter) on \(\.$input)") {
                    \.$outputMode
                    \.$arguments
                    \.$slurp
                    \.$sortKeys
                    \.$timeout
                    \.$runInApp
                }
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let store = SavedFilterStore.shared
        guard !savedFilter.isChooseInApp, let saved = store.filter(id: savedFilter.id) else {
            if let record = store.deletedRecord(id: savedFilter.id) {
                throw FilterError.savedFilterDeleted(name: record.name)
            }
            throw FilterError.savedFilterMissing
        }
        let mode = outputMode?.mode ?? saved.outputMode
        let inApp = await continueInAppIfRequested(runInApp)
        let context: RunContext = inApp ? .foreground : .background
        let data = try IntentInput.data(from: input, context: context, canRunInApp: !runInApp, allowEmpty: true)
        let request = FilterRequest(
            filter: saved.filter,
            input: data,
            // The values saved with the filter are defaults, as in the
            // Playground, the share sheet and the clipboard runner.
            argumentsText: try FilterArguments.merging(arguments, onto: saved.argumentsJSON),
            slurp: slurp,
            timeout: IntentInput.timeout(timeout),
            context: context,
            canRunInApp: !runInApp
        )
        let outcome = await ActionRunner.run(request, actionName: String(localized: "Run Saved Filter"),
                                             outputMode: mode, showProgress: inApp)
        if let error = outcome.error {
            throw error
        }
        return .result(value: ShortcutsOutput.values(for: outcome.results, mode: mode, sortKeys: sortKeys))
    }
}
