import AppIntents
import Foundation
import UniformTypeIdentifiers

/// R3.3 and R5.8: Valid, Line, Column and Message, the last three empty when
/// the input is valid.
struct ValidationResultEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Validation Result")

    @Property(title: "Valid")
    var isValid: Bool

    @Property(title: "Line")
    var line: Int?

    @Property(title: "Column")
    var column: Int?

    @Property(title: "Message")
    var message: String?

    init() {
        isValid = false
        line = nil
        column = nil
        message = nil
    }

    var displayRepresentation: DisplayRepresentation {
        if isValid {
            return DisplayRepresentation(title: "Valid JSON")
        }
        return DisplayRepresentation(title: "Invalid JSON", subtitle: "\(message ?? "")")
    }
}

struct ValidateJSONIntent: AppIntent {
    static let title: LocalizedStringResource = "Validate JSON"
    static let description = IntentDescription(
        "Checks whether the input is valid JSON. When it is not, the result gives the line, the column and what is wrong.",
        categoryName: "JSON",
        searchKeywords: ["json", "validate", "check", "lint", "syntax"],
        resultValueName: "Validation Result"
    )

    @Parameter(
        title: "Input",
        description: "JSON text, a JSON file, a dictionary or a list.",
        supportedContentTypes: [.json, .plainText, .text, .data],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var input: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Validate \(\.$input)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<ValidationResultEntity> {
        let data = try IntentInput.data(from: input, context: .background, canRunInApp: false)
        let validation = try await JSONTools.validate(data, settings: JSONTools.Settings(context: .background))
        var result = ValidationResultEntity()
        result.isValid = validation.isValid
        result.line = validation.line
        result.column = validation.column
        result.message = validation.message
        return .result(value: result)
    }
}
