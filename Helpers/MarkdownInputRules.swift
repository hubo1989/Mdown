import Foundation

private func ascii16(_ c: Character) -> unichar {
    unichar(c.unicodeScalars.first!.value)
}

// MARK: - T12 输入规则（SPEC §4.3「空段起始输入前缀」）

/// 一次 typing 输入构成的结构前缀转换（NE-08）。
struct InputRuleMatch: Equatable {
    enum Kind: String, Equatable {
        case heading  // # ~ ######
        case bulletList  // - + *
        case orderedList  // 1. 1)
        case quote  // >
    }

    let kind: Kind
    /// heading 级别（1–6），其余为 nil。
    let headingLevel: Int?
    /// 整个前缀的 source 区间（缩进 + 符号 + 触发空格）。
    let prefixRangeUTF16: NSRange
}

enum MarkdownInputRules {

    /// 判定一次**单空格纯插入**是否完成了段首结构前缀。条件（SPEC §4.3
    /// 「合法前缀完成才结构转换」）：
    /// - 插入的是 1 个空格（前缀的完成字符；多字符插入是粘贴/IME，不触发）；
    /// - 所在行是「缩进 + 符号 + 该空格」且行内无其他内容（空段起始）；
    /// - 插入点不在保护块（code/math/table/html/frontmatter 等）内——
    ///   这些块内输入按字面处理（NE-10 保护）。
    ///
    /// 转换本身不改 source（source 即最终态，parser 在重建投影时接管）；
    /// 匹配结果用于 undo 单元重组与观察口。返回 nil 表示本次输入不构成
    /// 前缀完成。
    static func matchPrefixInsertion(
        source: String, insertedOffset: Int, protectedRanges: [NSRange]
    ) -> InputRuleMatch? {
        let ns = source as NSString
        guard insertedOffset >= 0, insertedOffset < ns.length else { return nil }
        guard ns.character(at: insertedOffset) == ascii16(" ") else { return nil }
        for range in protectedRanges
        where insertedOffset >= range.location && insertedOffset < NSMaxRange(range) {
            return nil
        }

        let lineRange = ns.lineRange(for: NSRange(location: insertedOffset, length: 0))
        let lineStart = lineRange.location
        var contentEnd = NSMaxRange(lineRange)
        if contentEnd > lineStart, ns.character(at: contentEnd - 1) == ascii16("\n") {
            contentEnd -= 1
            // CRLF 行尾整体剥（NE-03，与 MarkdownBlockModel.parseLine 同规则）
            if contentEnd > lineStart, ns.character(at: contentEnd - 1) == ascii16("\r") {
                contentEnd -= 1
            }
        }
        // 行内容必须恰为：缩进 + 符号 + 触发空格（空格在行尾）
        let contentLen = contentEnd - lineStart
        guard contentLen >= 2, contentEnd == insertedOffset + 1 else { return nil }

        var i = lineStart
        while i < contentEnd - 1, ns.character(at: i) == ascii16(" ") || ns.character(at: i) == ascii16("\t") {
            i += 1
        }
        let indentEnd = i
        let prefixRange = NSRange(location: lineStart, length: contentLen)

        // heading：#×1–6 + 空格
        var hashes = 0
        while i < insertedOffset, ns.character(at: i) == ascii16("#") {
            hashes += 1
            i += 1
        }
        if hashes >= 1, hashes <= 6, i == insertedOffset {
            return InputRuleMatch(kind: .heading, headingLevel: hashes, prefixRangeUTF16: prefixRange)
        }

        // quote：>×1–3 + 空格（手输嵌套最多认三层；缩进前缀与 heading/
        // bullet 同规则）
        i = indentEnd
        var quotes = 0
        while i < insertedOffset, ns.character(at: i) == ascii16(">") {
            quotes += 1
            i += 1
        }
        if quotes >= 1, quotes <= 3, i == insertedOffset {
            return InputRuleMatch(kind: .quote, headingLevel: nil, prefixRangeUTF16: prefixRange)
        }

        // 无序：- + * 单符号
        i = indentEnd
        if i == insertedOffset - 1 {
            let c = ns.character(at: i)
            if c == ascii16("-") || c == ascii16("+") || c == ascii16("*") {
                return InputRuleMatch(kind: .bulletList, headingLevel: nil, prefixRangeUTF16: prefixRange)
            }
        }

        // 有序：数字串 + ./)
        i = indentEnd
        var digits = 0
        while i < insertedOffset, ns.character(at: i) >= ascii16("0"), ns.character(at: i) <= ascii16("9") {
            digits += 1
            i += 1
        }
        if digits >= 1, digits <= 9, i == insertedOffset - 1 {
            let c = ns.character(at: i)
            if c == ascii16(".") || c == ascii16(")") {
                return InputRuleMatch(kind: .orderedList, headingLevel: nil, prefixRangeUTF16: prefixRange)
            }
        }
        return nil
    }
}
