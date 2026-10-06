import JQEngine
import SwiftUI

/// The filter editor, the run status, and the error under the editor with
/// its position underlined (R6.10).
struct FilterSection: View {
    @Environment(AppModel.self) private var app
    var onTreeRequested: () -> Void

    var body: some View {
        @Bindable var model = app.playground
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Filter")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                status
                Button(action: onTreeRequested) {
                    Label("Pick a path from the input", systemImage: "list.bullet.indent")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
            CodeEditor(
                text: $model.filter,
                selection: $model.filterSelection,
                language: .filter,
                errorRange: model.outcome?.error?.highlight,
                accessibilityLabel: String(localized: "Filter"),
                editorIdentifier: "filterEditor"
            )
            .frame(minHeight: 72, idealHeight: 110, maxHeight: 180)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            if let error = model.outcome?.error {
                ErrorPanel(error: error, onAddArgument: { name in
                    model.addArgument(name)
                })
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var status: some View {
        let model = app.playground
        if model.isRunning {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Running")
        } else if let outcome = model.outcome, outcome.error == nil {
            Text(Self.summary(outcome))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    static func summary(_ outcome: FilterOutcome) -> String {
        let count = outcome.results.count
        let milliseconds = Int((outcome.duration * 1000).rounded())
        let results = count == 1 ? String(localized: "1 result") : String(localized: "\(count) results")
        if outcome.truncated {
            return String(localized: "First \(count) results")
        }
        return String(localized: "\(results) · \(milliseconds) ms")
    }
}

/// An R8 message, with a shortcut to fix the undefined-variable case.
struct ErrorPanel: View {
    let error: FilterError
    var onAddArgument: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(error.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if case .undefinedVariable(let name, _) = error, let onAddArgument {
                Button {
                    onAddArgument(name)
                } label: {
                    Label("Add $\(name) to Arguments", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("filterError")
    }
}
