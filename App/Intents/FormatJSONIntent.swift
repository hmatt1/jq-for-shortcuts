import AppIntents
import Foundation
import UniformTypeIdentifiers

enum FormatStyleOption: String, AppEnum {
    case pretty
    case compact

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Style")

    static let caseDisplayRepresentations: [FormatStyleOption: DisplayRepresentation] = [
        .pretty: DisplayRepresentation(title: "Pretty"),
        .compact: DisplayRepresentation(title: "Compact"),
    ]
}

/// R3.4: pretty or compact JSON as text (R5.10).
struct FormatJSONIntent: AppIntent {
    static let title: LocalizedStringResource = "Format JSON"
    static let description = IntentDescription(
        "Prints JSON with a 2-space indent, or on one line.",
        categoryName: "JSON",
        searchKeywords: ["json", "format", "pretty", "minify", "compact", "indent"],
        resultValueName: "Formatted JSON"
    )

    @Parameter(
        title: "Input",
        description: "JSON text, a JSON file, a dictionary or a list.",
        supportedContentTypes: [.json, .plainText, .text, .data],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var input: [IntentFile]

    @Parameter(title: "Style", default: .pretty)
    var style: FormatStyleOption

    @Parameter(title: "Sort Keys", default: false)
    var sortKeys: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Format \(\.$input) as \(\.$style)") {
            \.$sortKeys
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let data = try IntentInput.data(from: input, context: .background, canRunInApp: false)
        let text = try await JSONTools.format(data, pretty: style == .pretty, sortKeys: sortKeys,
                                              settings: JSONTools.Settings(context: .background))
        return .result(value: text)
    }
}
