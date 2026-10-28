import AppKit

enum MarkdownClipboardAdapter {
    static let markdownType = NSPasteboard.PasteboardType("com.miaoyan.markdown")

    enum PasteMode {
        case automatic, plain, markdown
    }

    static func text(from board: NSPasteboard, mode: PasteMode, literal: Bool) -> String? {
        let plain = board.string(forType: .string)
        if literal { return plain ?? board.string(forType: markdownType) }
        switch mode {
        case .markdown:
            return board.string(forType: markdownType) ?? plain
        case .plain:
            return plain.map(escapeLiteral)
        case .automatic:
            if let markdown = board.string(forType: markdownType) { return markdown }
            if let html = board.string(forType: .html), let markdown = HtmlToMarkdown.convertIfStructured(html) {
                return markdown
            }
            return plain.map(escapeLiteral)
        }
    }

    static func escapeLiteral(_ text: String) -> String {
        let punctuation = CharacterSet(charactersIn: "\\`*_[]<>!#~|$")
        var result = ""
        var indentationOnly = true
        var orderedPrefix = true
        var hasDigits = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                result.unicodeScalars.append(scalar)
                indentationOnly = true
                orderedPrefix = true
                hasDigits = false
                continue
            }
            let marker = (scalar == "-" || scalar == "+" || scalar == "=") && indentationOnly
            let ordered = (scalar == "." || scalar == ")") && orderedPrefix && hasDigits
            if punctuation.contains(scalar) || marker || ordered { result.append("\\") }
            result.unicodeScalars.append(scalar)
            if indentationOnly && (scalar == " " || scalar == "\t") { continue }
            indentationOnly = false
            if scalar.value >= 48 && scalar.value <= 57 {
                hasDigits = true
            } else {
                orderedPrefix = false
            }
        }
        return result
    }
}
