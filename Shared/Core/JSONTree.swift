import Foundation
import JQEngine

/// One row of the tree browser (R6.4). Children are built only when a row is
/// expanded (R6.6), and containers with many children are split into
/// ranges of at most 100 rows, so a large input opens without a stall.
struct JSONTreeNode: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case object(count: Int)
        case array(count: Int)
        case string
        case number
        case boolean
        case null
        /// A range of a large container's children, such as `[100…199]`.
        case range(Range<Int>)
    }

    /// Unique within one tree: the path expression, or the path plus a range.
    let id: String
    let components: [JQPathBuilder.Component]
    let label: String
    let kind: Kind
    let value: JSON
    let depth: Int

    var path: String { JQPathBuilder.expression(components) }

    var isContainer: Bool {
        switch kind {
        case .object(let count), .array(let count): return count > 0
        case .range: return true
        default: return false
        }
    }

    static func == (lhs: JSONTreeNode, rhs: JSONTreeNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum JSONTree {
    static let rangeSize = 100

    static func root(_ value: JSON) -> JSONTreeNode {
        node(value, components: [], label: ".", depth: 0)
    }

    static func children(of node: JSONTreeNode) -> [JSONTreeNode] {
        let depth = node.depth + 1
        switch (node.kind, node.value) {
        case (.range(let range), .array(let items)):
            return rows(for: range, depth: depth, parent: node) { index in
                Self.node(items[index], components: node.components + [.index(index)], label: "[\(index)]", depth: depth)
            }
        case (.range(let range), .object(let object)):
            return rows(for: range, depth: depth, parent: node) { position in
                let key = object.keys[position]
                return Self.node(object.values[position], components: node.components + [.key(key)], label: key, depth: depth)
            }
        case (.array(let count), .array(let items)):
            return rows(for: 0..<count, depth: depth, parent: node) { index in
                Self.node(items[index], components: node.components + [.index(index)], label: "[\(index)]", depth: depth)
            }
        case (.object(let count), .object(let object)):
            return rows(for: 0..<count, depth: depth, parent: node) { position in
                let key = object.keys[position]
                return Self.node(object.values[position], components: node.components + [.key(key)], label: key, depth: depth)
            }
        default:
            return []
        }
    }

    /// The rows for `range`: the children themselves when there are at most
    /// 100, otherwise sub-ranges whose size is a power of 100.
    private static func rows(for range: Range<Int>, depth: Int, parent: JSONTreeNode,
                             makeChild: (Int) -> JSONTreeNode) -> [JSONTreeNode] {
        if range.count <= rangeSize {
            return range.map(makeChild)
        }
        var step = rangeSize
        while (range.count + step - 1) / step > rangeSize {
            step *= rangeSize
        }
        return stride(from: range.lowerBound, to: range.upperBound, by: step).map { start in
            let sub = start..<min(start + step, range.upperBound)
            let label = "[\(sub.lowerBound)…\(sub.upperBound - 1)]"
            return JSONTreeNode(
                id: parent.path + "#" + "\(sub.lowerBound)-\(sub.upperBound)",
                components: parent.components,
                label: label,
                kind: .range(sub),
                value: parent.value,
                depth: depth
            )
        }
    }

    private static func node(_ value: JSON, components: [JQPathBuilder.Component], label: String, depth: Int) -> JSONTreeNode {
        let kind: JSONTreeNode.Kind
        switch value {
        case .object(let object): kind = .object(count: object.count)
        case .array(let items): kind = .array(count: items.count)
        case .string: kind = .string
        case .number: kind = .number
        case .bool: kind = .boolean
        case .null: kind = .null
        }
        return JSONTreeNode(id: JQPathBuilder.expression(components), components: components, label: label,
                            kind: kind, value: value, depth: depth)
    }

    /// A one-line summary of a node's value.
    static func preview(_ node: JSONTreeNode) -> String {
        switch node.kind {
        case .object(let count):
            return count == 1 ? String(localized: "{1 key}") : String(localized: "{\(count) keys}")
        case .array(let count):
            return count == 1 ? String(localized: "[1 item]") : String(localized: "[\(count) items]")
        case .range(let range):
            return String(localized: "\(range.count) items")
        case .string:
            let text = JSONWriter.string(node.value)
            return text.count > 80 ? String(text.prefix(79)) + "…\"" : text
        case .number, .boolean, .null:
            return JSONWriter.string(node.value)
        }
    }

    /// What VoiceOver reads for a row: its path first (R9.11).
    static func accessibilityLabel(_ node: JSONTreeNode) -> String {
        if case .range = node.kind {
            return String(localized: "\(node.path), items \(node.label)")
        }
        return String(localized: "\(node.path), \(preview(node))")
    }

    /// The rows to show: the root and every child of an expanded row, in order.
    static func visibleRows(root: JSONTreeNode, expanded: Set<String>, limit: Int = 20_000) -> [JSONTreeNode] {
        var rows: [JSONTreeNode] = []
        var stack: [JSONTreeNode] = [root]
        while let node = stack.popLast(), rows.count < limit {
            rows.append(node)
            if node.isContainer, expanded.contains(node.id) {
                stack.append(contentsOf: children(of: node).reversed())
            }
        }
        return rows
    }
}
