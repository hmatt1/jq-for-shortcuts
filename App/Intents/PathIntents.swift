import AppIntents
import Foundation
import UniformTypeIdentifiers

enum MissingValueOption: String, AppEnum {
    case stop
    case returnNothing

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "If Missing")

    static let caseDisplayRepresentations: [MissingValueOption: DisplayRepresentation] = [
        .stop: DisplayRepresentation(title: "Stop with error"),
        .returnNothing: DisplayRepresentation(title: "Return nothing"),
    ]

    var behavior: JSONTools.MissingValueBehavior {
        self == .stop ? .stop : .returnNothing
    }
}

/// R3.5: the value at a jq path such as `.data.items[3].name`, read on the
/// same engine as Run JSON Filter (R3.36).
struct GetValueAtPathIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Value at Path"
    static let description = IntentDescription(
        "Gets the value at a jq path, such as .data.items[3].name. A path that matches several values, such as .items[].name, returns each of them.",
        categoryName: "JSON",
        searchKeywords: ["json", "path", "get", "value", "key", "jq"],
        resultValueName: "Value"
    )

    @Parameter(
        title: "Input",
        description: "JSON text, a JSON file, a dictionary or a list.",
        supportedContentTypes: [.json, .plainText, .text, .data],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var input: [IntentFile]

    @Parameter(
        title: "Path",
        description: "A jq path, such as .data.items[3].name",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none, multiline: false, autocorrect: false, smartQuotes: false, smartDashes: false
        )
    )
    var path: String

    @Parameter(title: "If Missing", default: .stop)
    var ifMissing: MissingValueOption

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$path) from \(\.$input)") {
            \.$ifMissing
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let data = try IntentInput.data(from: input, context: .background, canRunInApp: false)
        let values = try await JSONTools.values(atPath: path, in: data, ifMissing: ifMissing.behavior,
                                                settings: JSONTools.Settings(context: .background))
        return .result(value: ShortcutsOutput.values(for: values, mode: .itemPerResult, sortKeys: false))
    }
}

/// R3.6: the input with a new value at a jq path, as JSON text (R5.10).
struct SetValueAtPathIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Value at Path"
    static let description = IntentDescription(
        "Sets the value at a jq path, such as .settings.theme, and returns the updated JSON. Missing objects and lists along the path are created.",
        categoryName: "JSON",
        searchKeywords: ["json", "path", "set", "update", "value", "jq"],
        resultValueName: "Updated JSON"
    )

    @Parameter(
        title: "Input",
        description: "JSON text, a JSON file, a dictionary or a list.",
        supportedContentTypes: [.json, .plainText, .text, .data],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var input: [IntentFile]

    @Parameter(
        title: "Path",
        description: "A jq path, such as .settings.theme",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none, multiline: false, autocorrect: false, smartQuotes: false, smartDashes: false
        )
    )
    var path: String

    @Parameter(
        title: "Value",
        description: "Any value. Text that is valid JSON, such as 42, true or [1, 2], is set as that JSON value. To keep text such as 42 as text, put it in double quotes.",
        supportedContentTypes: [.json, .plainText, .text, .data]
    )
    var value: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$path) to \(\.$value) in \(\.$input)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let data = try IntentInput.data(from: input, context: .background, canRunInApp: false)
        let newValue = try IntentInput.jsonValue(from: value)
        let updated = try await JSONTools.settingValue(newValue, atPath: path, in: data,
                                                       settings: JSONTools.Settings(context: .background))
        return .result(value: ShortcutsOutput.values(for: updated, mode: .compactJSON, sortKeys: false).joined(separator: "\n"))
    }
}
