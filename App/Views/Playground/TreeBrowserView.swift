import JQEngine
import SwiftUI

/// The input as a collapsible tree (R6.4). Tapping a value inserts its path,
/// such as `.data.items[3].name`, at the cursor in the filter. Inside an
/// array the wrappers `.[]`, `map` and `select` are offered too (R6.5).
/// Rows are built only when their parent is expanded (R6.6).
struct TreeBrowserView: View {
    @Environment(AppModel.self) private var app
    @State private var expanded: Set<String> = []
    @State private var pendingSuggestions: [JQPathBuilder.Suggestion] = []
    @State private var isChoosingSuggestion = false

    /// Multiple input values (JSON Lines) show up to this many roots.
    private static let rootLimit = 100

    var body: some View {
        let model = app.playground
        Group {
            switch model.parsedInput {
            case .values(let values) where model.inputByteCount <= RunLimits.treeBrowserInputLimit:
                treeList(roots(for: values, slurp: model.slurp))
            case .values:
                unavailable(String(localized: "The input is too large for the tree. Type paths in the filter instead."))
            case .failure(let error):
                unavailable(error.message)
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: app.dismissalGeneration) {
            isChoosingSuggestion = false
        }
        .confirmationDialog("Insert into the filter", isPresented: $isChoosingSuggestion, titleVisibility: .visible) {
            ForEach(pendingSuggestions) { suggestion in
                Button {
                    app.playground.insertIntoFilter(suggestion.expression)
                } label: {
                    Text("\(suggestion.title): \(suggestion.expression)")
                }
            }
        }
    }

    private func roots(for values: [JSON], slurp: Bool) -> [(title: String?, node: JSONTreeNode)] {
        if slurp || values.count == 1 {
            return [(nil, JSONTree.root(slurp ? .array(values) : values[0]))]
        }
        return values.prefix(Self.rootLimit).enumerated().map { index, value in
            (String(localized: "Input value \(index + 1)"), JSONTree.root(value))
        }
    }

    private func treeList(_ roots: [(title: String?, node: JSONTreeNode)]) -> some View {
        List {
            ForEach(Array(roots.enumerated()), id: \.offset) { index, root in
                Section {
                    ForEach(JSONTree.visibleRows(root: root.node, expanded: expandedSet(for: index))) { node in
                        TreeRow(node: node, isExpanded: expanded.contains(key(index, node))) {
                            toggle(index, node)
                        } onSelect: {
                            select(node)
                        }
                    }
                } header: {
                    if let title = root.title {
                        Text(title)
                    }
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("treeBrowser")
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("No Tree", systemImage: "list.bullet.indent")
        } description: {
            Text(message)
        }
    }

    // Expansion is tracked per root, keyed by "root index|node id".
    private func key(_ root: Int, _ node: JSONTreeNode) -> String {
        "\(root)|\(node.id)"
    }

    private func expandedSet(for root: Int) -> Set<String> {
        let prefix = "\(root)|"
        var ids = Set(expanded.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        ids.insert(".")
        return ids
    }

    private func toggle(_ root: Int, _ node: JSONTreeNode) {
        let id = key(root, node)
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private func select(_ node: JSONTreeNode) {
        if case .range = node.kind { return }
        let suggestions = JQPathBuilder.suggestions(for: node.components, value: node.value)
        if suggestions.count == 1 {
            app.playground.insertIntoFilter(suggestions[0].expression)
        } else {
            pendingSuggestions = suggestions
            isChoosingSuggestion = true
        }
    }
}

private struct TreeRow: View {
    let node: JSONTreeNode
    let isExpanded: Bool
    var onToggle: () -> Void
    var onSelect: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if node.isContainer, node.depth > 0 {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 20, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isExpanded ? Text("Collapse") : Text("Expand"))
            } else {
                Color.clear.frame(width: 20, height: 1)
            }
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Text(node.label)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundStyle(.primary)
                    Text(JSONTree.preview(node))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(JSONTree.accessibilityLabel(node))
            .accessibilityHint(Text("Inserts this path into the filter"))
        }
        .padding(.leading, CGFloat(max(node.depth - 1, 0)) * 14)
    }
}
