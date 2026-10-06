import AppIntents
import Foundation
import UniformTypeIdentifiers

enum DelimiterOption: String, AppEnum {
    case comma
    case tab

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Delimiter")

    static let caseDisplayRepresentations: [DelimiterOption: DisplayRepresentation] = [
        .comma: DisplayRepresentation(title: "Comma"),
        .tab: DisplayRepresentation(title: "Tab"),
    ]

    var delimiter: JSONTools.TableDelimiter {
        self == .comma ? .comma : .tab
    }
}

/// R3.7 and R5.9: a CSV or TSV file from an array of objects.
struct JSONToCSVIntent: AppIntent {
    static let title: LocalizedStringResource = "JSON to CSV"
    static let description = IntentDescription(
        "Turns a list of objects into a CSV or TSV file, one row per object. Objects and lists inside a cell are written as JSON.",
        categoryName: "JSON",
        searchKeywords: ["json", "csv", "tsv", "spreadsheet", "table", "export"],
        resultValueName: "Table"
    )

    @Parameter(
        title: "Input",
        description: "A list of objects, as JSON text, a JSON file or a list.",
        supportedContentTypes: [.json, .plainText, .text, .data],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var input: [IntentFile]

    @Parameter(title: "Columns", description: "The keys to include, in order. Leave empty for every key of the first object.")
    var columns: [String]?

    @Parameter(title: "Delimiter", default: .comma)
    var delimiter: DelimiterOption

    @Parameter(title: "Header Row", default: true)
    var includeHeader: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$input) to CSV with columns \(\.$columns)") {
            \.$delimiter
            \.$includeHeader
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let data = try IntentInput.data(from: input, context: .background, canRunInApp: false)
        let table = try await JSONTools.table(from: data, columns: columns, delimiter: delimiter.delimiter,
                                              includeHeader: includeHeader, settings: JSONTools.Settings(context: .background))
        let type: UTType = delimiter == .comma ? .commaSeparatedText : .tabSeparatedText
        let file = IntentFile(data: Data(table.utf8), filename: "Table.\(delimiter.delimiter.fileExtension)", type: type)
        return .result(value: file)
    }
}
