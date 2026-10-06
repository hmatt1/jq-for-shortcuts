import AppIntents
import Foundation
import UniformTypeIdentifiers

/// R3.1: runs a filter typed into the action, or one passed in from Ask for
/// Input, the clipboard or a previous action (R3.32).
struct RunJSONFilterIntent: AppIntent {
    static let title: LocalizedStringResource = "Run JSON Filter"
    static let description = IntentDescription(
        "Runs a jq filter on JSON and returns the results. Objects and arrays come back as JSON text, which dictionary and list actions read directly.",
        categoryName: "JSON",
        searchKeywords: ["jq", "json", "filter", "query", "transform", "select"],
        resultValueName: "Filter Results"
    )
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(
        title: "Filter",
        description: "A jq filter, such as .items[] | .name",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none, multiline: true, autocorrect: false, smartQuotes: false, smartDashes: false
        )
    )
    var filter: String

    @Parameter(
        title: "Input",
        description: "JSON text, a JSON file, a dictionary or a list.",
        supportedContentTypes: [.json, .plainText, .text, .data],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var input: [IntentFile]

    @Parameter(title: "Output Mode", default: .itemPerResult)
    var outputMode: OutputModeOption

    @Parameter(
        title: "Arguments",
        description: "A dictionary. Each key becomes a $variable in the filter.",
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
            Summary("Run Filter \(\.$filter) on \(\.$input) with \(\.$arguments), output \(\.$outputMode)") {
                \.$slurp
                \.$sortKeys
                \.$timeout
                \.$runInApp
            }
        } otherwise: {
            Summary("Run Filter \(\.$filter) on \(\.$input), output \(\.$outputMode)") {
                \.$arguments
                \.$slurp
                \.$sortKeys
                \.$timeout
                \.$runInApp
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let inApp = await continueInAppIfRequested(runInApp)
        let context: RunContext = inApp ? .foreground : .background
        // When Run in App is on but the app could not come forward, the run
        // goes on in the background, and messages must not suggest turning
        // Run in App on.
        let data = try IntentInput.data(from: input, context: context, canRunInApp: !runInApp, allowEmpty: true)
        let request = FilterRequest(
            filter: filter,
            input: data,
            argumentsText: arguments,
            slurp: slurp,
            timeout: IntentInput.timeout(timeout),
            context: context,
            canRunInApp: !runInApp
        )
        let outcome = await ActionRunner.run(request, actionName: String(localized: "Run JSON Filter"),
                                             outputMode: outputMode.mode, showProgress: inApp)
        if let error = outcome.error {
            throw error
        }
        return .result(value: ShortcutsOutput.values(for: outcome.results, mode: outputMode.mode, sortKeys: sortKeys))
    }
}
