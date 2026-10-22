import Cocoa

@MainActor
enum CodeBlockHighlighter {
    private static var cachedCodeBlockRegex: NSRegularExpression?

    static func getCodeBlockRegex(pattern: String) -> NSRegularExpression? {
        if let cached = cachedCodeBlockRegex {
            return cached
        }

        guard
            let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.allowCommentsAndWhitespace, .anchorsMatchLines]
            )
        else {
            return nil
        }

        cachedCodeBlockRegex = regex
        return regex
    }

    static func highlightCode(
        attributedString: NSMutableAttributedString,
        range: NSRange,
        language: String? = nil
    ) {
        guard range.upperBound <= attributedString.length else {
            return
        }

        if NotesTextProcessor.shouldSkipCodeHighlighting {
            applyBasicCodeStyle(attributedString: attributedString, range: range)
            return
        }

        let maxCodeBlockSize = NotesTextProcessor.shouldUseSimplifiedHighlighting ? 500 : 3000
        if range.length > maxCodeBlockSize {
            applyBasicCodeStyle(attributedString: attributedString, range: range)
            return
        }

        let codeString = attributedString.mutableString.substring(with: range)
        let preDefinedLanguage = language ?? NotesTextProcessor.getLanguage(codeString)

        // T15:NativeCodeHighlighter token(UTF-16 子区间)上色,正文不变;
        // 未知语言返回 nil → 基础 code 样式。
        guard
            let tokens = NativeCodeHighlighter.highlight(
                code: codeString, language: preDefinedLanguage)
        else {
            applyBasicCodeStyle(attributedString: attributedString, range: range)
            return
        }

        applyBasicCodeStyle(attributedString: attributedString, range: range)
        let palette = tokenPalette(isDark: AppEnvironment.current.userData.isDark)
        for tk in tokens {
            let fixed = NSRange(location: range.location + tk.range.location, length: tk.range.length)
            guard fixed.length > 0, NSMaxRange(fixed) <= attributedString.length else { continue }
            if let color = palette[tk.kind] {
                attributedString.addAttribute(.foregroundColor, value: color, range: fixed)
            }
        }

        attributedString.addAttribute(.codeBlock, value: true, range: range)
        if let language = preDefinedLanguage {
            attributedString.addAttribute(.codeLanguage, value: language, range: range)
        } else {
            attributedString.removeAttribute(.codeLanguage, range: range)
        }

        attributedString.fixAttributes(in: range)
    }

    static func highlightFencedAndIndentCodeBlocks(attributedString: NSMutableAttributedString, pattern: String) {
        let range = NSRange(0..<attributedString.length)
        guard range.length > 0 else { return }

        guard let regex = getCodeBlockRegex(pattern: pattern) else {
            return
        }

        regex.enumerateMatches(in: attributedString.string, range: range) { result, _, _ in
            guard let codeRange = result?.range,
                codeRange.upperBound <= attributedString.length
            else {
                return
            }
            highlightCode(attributedString: attributedString, range: codeRange)
        }
    }

    /// token 类别 → 主题色(明暗两套;与既有 code 基色同风格的手挑值)。
    static func tokenPalette(isDark: Bool) -> [NativeCodeTokenKind: NSColor] {
        isDark
            ? [
                .keyword: NSColor(calibratedRed: 0.78, green: 0.55, blue: 0.96, alpha: 1),
                .string: NSColor(calibratedRed: 0.79, green: 0.82, blue: 0.48, alpha: 1),
                .number: NSColor(calibratedRed: 0.87, green: 0.63, blue: 0.44, alpha: 1),
                .comment: NSColor(calibratedRed: 0.45, green: 0.50, blue: 0.56, alpha: 1),
                .type: NSColor(calibratedRed: 0.55, green: 0.80, blue: 0.90, alpha: 1),
                .property: NSColor(calibratedRed: 0.55, green: 0.80, blue: 0.90, alpha: 1),
                .tag: NSColor(calibratedRed: 0.55, green: 0.80, blue: 0.90, alpha: 1),
                .attribute: NSColor(calibratedRed: 0.79, green: 0.82, blue: 0.48, alpha: 1),
                .literal: NSColor(calibratedRed: 0.87, green: 0.63, blue: 0.44, alpha: 1),
            ]
            : [
                .keyword: NSColor(calibratedRed: 0.53, green: 0.18, blue: 0.72, alpha: 1),
                .string: NSColor(calibratedRed: 0.36, green: 0.46, blue: 0.10, alpha: 1),
                .number: NSColor(calibratedRed: 0.70, green: 0.25, blue: 0.10, alpha: 1),
                .comment: NSColor(calibratedRed: 0.45, green: 0.50, blue: 0.56, alpha: 1),
                .type: NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.75, alpha: 1),
                .property: NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.75, alpha: 1),
                .tag: NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.75, alpha: 1),
                .attribute: NSColor(calibratedRed: 0.36, green: 0.46, blue: 0.10, alpha: 1),
                .literal: NSColor(calibratedRed: 0.70, green: 0.25, blue: 0.10, alpha: 1),
            ]
    }

    private static func applyBasicCodeStyle(attributedString: NSMutableAttributedString, range: NSRange) {
        guard range.upperBound <= attributedString.length,
            let codeFont = NotesTextProcessor.codeFont
        else {
            return
        }

        let codeColor =
            AppEnvironment.current.userData.isDark
            ? NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0)
            : NSColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)

        attributedString.addAttribute(.font, value: codeFont, range: range)
        attributedString.addAttribute(.foregroundColor, value: codeColor, range: range)
        attributedString.addAttribute(.codeBlock, value: true, range: range)
        attributedString.removeAttribute(.codeLanguage, range: range)
        attributedString.fixAttributes(in: range)
    }
}
