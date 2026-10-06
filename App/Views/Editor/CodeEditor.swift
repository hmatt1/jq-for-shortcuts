import JQEngine
import SwiftUI
import UIKit

/// A plain-text code editor: monospaced, with autocorrect, smart punctuation
/// and automatic capitalization turned off (R6.7). In filter mode it colors
/// jq syntax, marks the bracket that matches the one at the cursor (R6.9),
/// underlines the error position (R6.10), and shows the symbol row above
/// the keyboard (R6.8).
struct CodeEditor: UIViewRepresentable {
    enum Language {
        case filter
        case json
    }

    @Binding var text: String
    var selection: Binding<NSRange>?
    var language: Language
    /// UTF-8 byte range in `text` to underline.
    var errorRange: SourceRange?
    var accessibilityLabel: String
    var isEditable = true
    /// Set on the text view itself, where UI tests find it.
    var editorIdentifier: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let coordinator = context.coordinator
        // Setting the text below moves the selection, and the delegate must
        // not write that back into SwiftUI state during this update.
        coordinator.isApplyingUpdate = true
        defer { coordinator.isApplyingUpdate = false }
        let view = UITextView()
        view.delegate = coordinator
        view.font = CodeStyle.font
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardType = .default
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        view.isEditable = isEditable
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityIdentifier = editorIdentifier
        if language == .filter {
            view.inputAccessoryView = SymbolBar.make(for: view)
        }
        view.text = text
        coordinator.restyle(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.isApplyingUpdate = true
        defer { coordinator.isApplyingUpdate = false }
        view.isEditable = isEditable
        // While a keyboard composes characters, such as Japanese, the text
        // view owns its text and selection. Restyling or moving the cursor
        // then would cancel the composition.
        let isComposing = view.markedTextRange != nil
        if view.text != text, !isComposing {
            view.text = text
            coordinator.restyle(view)
        } else if coordinator.lastErrorRange != errorRange, !isComposing {
            coordinator.restyle(view)
        }
        if let selection, !isComposing, view.selectedRange != selection.wrappedValue,
           NSMaxRange(selection.wrappedValue) <= (view.text as NSString).length {
            view.selectedRange = selection.wrappedValue
            coordinator.restyle(view)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        var lastErrorRange: SourceRange?
        /// True while SwiftUI pushes state into the view, so the delegate
        /// does not write the same state back during the update.
        var isApplyingUpdate = false
        private var isRestyling = false

        init(parent: CodeEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingUpdate else { return }
            parent.text = textView.text
            parent.selection?.wrappedValue = textView.selectedRange
            if textView.markedTextRange == nil {
                restyle(textView)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingUpdate, !isRestyling, textView.markedTextRange == nil else { return }
            if let selection = parent.selection, selection.wrappedValue != textView.selectedRange {
                selection.wrappedValue = textView.selectedRange
            }
            if parent.language == .filter {
                restyle(textView)
            }
        }

        /// Re-applies colors in place. Only attributes change, so the cursor
        /// and the undo stack stay where they are.
        func restyle(_ textView: UITextView) {
            isRestyling = true
            defer { isRestyling = false }
            lastErrorRange = parent.errorRange
            let text = textView.text ?? ""
            let storage = textView.textStorage
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: CodeStyle.font, .foregroundColor: UIColor.label], range: full)
            switch parent.language {
            case .filter:
                styleFilter(text, storage: storage, cursor: textView.selectedRange)
            case .json:
                if storage.length <= 200_000 {
                    styleJSON(text, storage: storage)
                }
            }
            if let errorRange = parent.errorRange {
                underline(errorRange, in: text, storage: storage)
            }
            storage.endEditing()
        }

        private func styleFilter(_ text: String, storage: NSTextStorage, cursor: NSRange) {
            let offsets = UTF16Offsets(text)
            let analysis = JQSyntaxHighlighter.analyze(text)
            for token in analysis.tokens {
                guard let color = CodeStyle.color(for: token.kind) else { continue }
                storage.addAttribute(.foregroundColor, value: color, range: offsets.range(token.range))
            }
            // Bracket matching: mark the pair next to the cursor.
            let cursorByte = offsets.utf8Offset(forUTF16: cursor.location)
            if cursor.length == 0, let pair = analysis.bracketPair(near: cursorByte) {
                for offset in [pair.open, pair.close].compactMap({ $0 }) {
                    storage.addAttribute(.backgroundColor, value: CodeStyle.bracketMatch,
                                         range: offsets.range(SourceRange(offset, offset + 1)))
                }
            }
        }

        private func styleJSON(_ text: String, storage: NSTextStorage) {
            let offsets = UTF16Offsets(text)
            for token in JSONHighlighter.tokens(text) {
                storage.addAttribute(.foregroundColor, value: token.color, range: offsets.range(token.range))
            }
        }

        private func underline(_ range: SourceRange, in text: String, storage: NSTextStorage) {
            let offsets = UTF16Offsets(text)
            var target = offsets.range(range)
            if target.length == 0 {
                // An empty range, such as the end of the filter: mark the
                // character before it.
                guard target.location > 0 else { return }
                target = NSRange(location: target.location - 1, length: 1)
            }
            guard NSMaxRange(target) <= storage.length else { return }
            storage.addAttributes([
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: UIColor.systemRed,
                .backgroundColor: CodeStyle.errorBackground,
            ], range: target)
        }
    }
}

/// Colors and fonts for code. Color is never the only cue: errors are also
/// underlined and described in text (R9.11).
enum CodeStyle {
    static var font: UIFont {
        let base = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    }

    static let bracketMatch = UIColor.systemYellow.withAlphaComponent(0.35)
    static let errorBackground = UIColor.systemRed.withAlphaComponent(0.12)

    static func color(for kind: JQSyntaxToken.Kind) -> UIColor? {
        switch kind {
        case .keyword: return .systemPurple
        case .literal: return .systemPurple
        case .number: return .systemOrange
        case .string: return .systemGreen
        case .interpolation: return .systemTeal
        case .field: return .systemBlue
        case .variable: return .systemTeal
        case .function: return .systemIndigo
        case .format: return .systemPink
        case .operator: return .secondaryLabel
        case .bracket: return nil
        case .comment: return .tertiaryLabel
        case .invalid: return .systemRed
        }
    }
}

/// Converts the engine's UTF-8 byte offsets into the UTF-16 offsets text
/// views use.
struct UTF16Offsets {
    private let utf8ToUTF16: [Int]

    init(_ text: String) {
        var table: [Int] = [0]
        table.reserveCapacity(text.utf8.count + 1)
        var utf16 = 0
        for scalar in text.unicodeScalars {
            let width = UTF8.width(scalar)
            let units = UTF16.width(scalar)
            for _ in 1..<width { table.append(utf16) }
            utf16 += units
            table.append(utf16)
        }
        utf8ToUTF16 = table
    }

    func utf16(_ utf8Offset: Int) -> Int {
        utf8ToUTF16[min(max(utf8Offset, 0), utf8ToUTF16.count - 1)]
    }

    func range(_ range: SourceRange) -> NSRange {
        let start = utf16(range.start)
        return NSRange(location: start, length: max(0, utf16(range.end) - start))
    }

    func utf8Offset(forUTF16 target: Int) -> Int {
        // The table is sorted, so the first byte that reaches `target` wins.
        var low = 0
        var high = utf8ToUTF16.count - 1
        while low < high {
            let mid = (low + high) / 2
            if utf8ToUTF16[mid] < target { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// Light coloring for JSON input: keys, strings, numbers and literals.
enum JSONHighlighter {
    struct Token {
        var range: SourceRange
        var color: UIColor
    }

    static func tokens(_ text: String) -> [Token] {
        let bytes = Array(text.utf8)
        var tokens: [Token] = []
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") {
                let start = i
                i += 1
                while i < bytes.count, bytes[i] != UInt8(ascii: "\"") {
                    i += bytes[i] == UInt8(ascii: "\\") ? 2 : 1
                }
                i = min(i + 1, bytes.count)
                var next = i
                while next < bytes.count, bytes[next] == 0x20 || bytes[next] == 0x0A || bytes[next] == 0x09 || bytes[next] == 0x0D {
                    next += 1
                }
                let isKey = next < bytes.count && bytes[next] == UInt8(ascii: ":")
                tokens.append(Token(range: SourceRange(start, i), color: isKey ? .systemBlue : .systemGreen))
            } else if c == UInt8(ascii: "-") || (c >= 0x30 && c <= 0x39) {
                let start = i
                while i < bytes.count, "0123456789+-.eE".utf8.contains(bytes[i]) { i += 1 }
                tokens.append(Token(range: SourceRange(start, i), color: .systemOrange))
            } else if c == UInt8(ascii: "t") || c == UInt8(ascii: "f") || c == UInt8(ascii: "n") {
                let start = i
                while i < bytes.count, bytes[i] >= UInt8(ascii: "a"), bytes[i] <= UInt8(ascii: "z") { i += 1 }
                tokens.append(Token(range: SourceRange(start, i), color: .systemPurple))
            } else {
                i += 1
            }
        }
        return tokens
    }
}

/// The symbol row above the keyboard (R6.8).
enum SymbolBar {
    private struct Symbol {
        let title: String
        let insert: String
        /// Where the cursor goes, counted from the start of `insert`.
        let cursorOffset: Int
        let accessibilityLabel: String
    }

    private static let symbols: [Symbol] = [
        Symbol(title: "|", insert: " | ", cursorOffset: 3, accessibilityLabel: String(localized: "Pipe")),
        Symbol(title: ".", insert: ".", cursorOffset: 1, accessibilityLabel: String(localized: "Dot")),
        Symbol(title: "[ ]", insert: "[]", cursorOffset: 1, accessibilityLabel: String(localized: "Square brackets")),
        Symbol(title: "{ }", insert: "{}", cursorOffset: 1, accessibilityLabel: String(localized: "Braces")),
        Symbol(title: "\"", insert: "\"\"", cursorOffset: 1, accessibilityLabel: String(localized: "Quotes")),
        Symbol(title: "$", insert: "$", cursorOffset: 1, accessibilityLabel: String(localized: "Dollar sign")),
        Symbol(title: "( )", insert: "()", cursorOffset: 1, accessibilityLabel: String(localized: "Parentheses")),
    ]

    @MainActor
    static func make(for textView: UITextView) -> UIView {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        var items: [UIBarButtonItem] = []
        for symbol in symbols {
            let action = UIAction(title: symbol.title) { [weak textView] _ in
                guard let textView else { return }
                let start = textView.selectedRange.location
                textView.insertText(symbol.insert)
                let utf16Offset = (String(symbol.insert.prefix(symbol.cursorOffset)) as NSString).length
                textView.selectedRange = NSRange(location: start + utf16Offset, length: 0)
            }
            let item = UIBarButtonItem(primaryAction: action)
            item.accessibilityLabel = symbol.accessibilityLabel
            items.append(item)
            items.append(UIBarButtonItem(systemItem: .flexibleSpace))
        }
        let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak textView] _ in
            textView?.resignFirstResponder()
        })
        items.append(done)
        bar.items = items
        bar.sizeToFit()
        return bar
    }
}
