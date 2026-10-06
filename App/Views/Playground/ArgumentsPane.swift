import SwiftUI

/// The Arguments editor (R6.11): a JSON object whose keys become `$name`
/// variables, the same way the action's Arguments dictionary does (R2.7).
struct ArgumentsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.playground
        VStack(alignment: .leading, spacing: 8) {
            Text("A JSON object. Each key becomes a $variable in the filter, as the Arguments dictionary of the action does.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            CodeEditor(
                text: $model.argumentsText,
                selection: nil,
                language: .json,
                errorRange: nil,
                accessibilityLabel: String(localized: "Arguments"),
                editorIdentifier: "argumentsEditor"
            )
            .frame(minHeight: 120)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            status
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var status: some View {
        let text = app.playground.argumentsText
        if text.allSatisfy(\.isWhitespace) {
            Text("No arguments.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            switch Result(catching: { try FilterArguments.parse(text) }) {
            case .success(let arguments):
                Label(arguments.isEmpty ? String(localized: "No arguments.")
                      : String(localized: "Variables: \(arguments.keys.sorted().map { "$" + $0 }.joined(separator: ", "))"),
                      systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failure(let error):
                Label((error as? FilterError)?.message ?? error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
