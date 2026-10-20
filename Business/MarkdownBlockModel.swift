import Foundation

private func ascii16(_ c: Character) -> unichar {
    unichar(c.unicodeScalars.first!.value)
}

// MARK: - T12 行级结构模型（SPEC §4.3 结构事务）

/// 从 source 单行解析出的结构前缀：quote 前缀、list marker（含 task）。
/// 混合嵌套行（`> - x`）一次解析出 quote 层与内层 list/task：kind 取
/// 内层结构，quotePrefixText/quoteDepth 携带外层（结构命令「由内向外」
/// 逐层退）。
/// 纯函数派生层——source 是唯一权威，本类型不做序列化回写；所有操作
/// 只产出原子 `SourcePatch`，交给 `MarkdownPatchApplier` 验证应用。
struct MarkdownBlockLine: Equatable {
    enum MarkerKind: Equatable {
        case none
        case bullet(symbol: Character)  // - + *
        case ordered(number: Int, closer: Character)  // 1. 1)
        case quote(depth: Int)  // > 及嵌套 >>（纯 quote，无内层 list）
    }

    /// task 状态：marker 后紧跟 `[ ]`/`[x]` + 空白（GFM task 项）。
    struct TaskState: Equatable {
        /// 括号内单字符（空格/x）的绝对 source 偏移。
        let checkOffsetUTF16: Int
        let checked: Bool
    }

    /// 行区间（含行尾换行，`NSString.lineRange` 自然形态）。
    let fullLineRangeUTF16: NSRange
    /// 行内容区间（不含行尾换行）。
    let contentLineRangeUTF16: NSRange
    let kind: MarkerKind
    /// 内层 marker 前的空白 unit 数（quote 混合行为 quote 前缀之后的缩进）。
    let indentUTF16: Int
    /// 内容起点相对行首偏移 = quote 前缀 + 缩进 + 符号 + task + 尾随空白。
    let prefixLength: Int
    let task: TaskState?
    /// quote 前缀字面（`> > ` 含层间空白）；非 quote 行为 nil。
    let quotePrefixText: String?
    /// quote 深度（`>` 个数）；非 quote 行为 0。
    let quoteDepth: Int
    /// 内层 list marker 符号相对行首偏移（纯 list 行 == indentUTF16）。
    let markerOffsetUTF16: Int

    /// 行首结构前缀的 source 区间（不含行尾换行）。
    var prefixRange: NSRange {
        NSRange(location: contentLineRangeUTF16.location, length: prefixLength)
    }

    /// 内容起点（绝对）。
    var contentStartUTF16: Int { contentLineRangeUTF16.location + prefixLength }

    /// 内容（前缀之后、行尾换行之前）是否为空。
    var contentIsEmpty: Bool { prefixLength >= contentLineRangeUTF16.length }

    /// 内层 list marker 区间（不含 quote 前缀；纯 list 行即 marker+task+空白）。
    var innerMarkerRange: NSRange {
        let start = contentLineRangeUTF16.location + markerOffsetUTF16
        return NSRange(location: start, length: contentStartUTF16 - start)
    }

    /// 是否携带内层 list 结构（混合行或纯 list 行）。
    var hasListMarker: Bool {
        switch kind {
        case .bullet, .ordered: return true
        case .none, .quote: return false
        }
    }
}

enum MarkdownBlockModel {

    /// 解析单行（lineRange 须为完整行区间，含或不含行尾换行均可）。
    static func parseLine(_ source: NSString, lineRange: NSRange) -> MarkdownBlockLine {
        let contentEnd = strippedContentEnd(source, lineRange: lineRange)
        let contentRange = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
        let length = contentRange.length

        // 缩进
        var i = 0
        while i < length {
            let c = source.character(at: lineRange.location + i)
            if c == ascii16(" ") || c == ascii16("\t") { i += 1 } else { break }
        }
        let indent = i
        guard i < length else {
            return MarkdownBlockLine(
                fullLineRangeUTF16: lineRange, contentLineRangeUTF16: contentRange,
                kind: .none, indentUTF16: indent, prefixLength: 0, task: nil,
                quotePrefixText: nil, quoteDepth: 0, markerOffsetUTF16: 0)
        }

        // quote：连续 `>`（每层间允许空格）；前缀之后的内层 list/task
        // 递归解析（混合嵌套行 `> - x`，NE-07）
        if source.character(at: lineRange.location + i) == ascii16(">") {
            return parseQuoteLine(
                source, lineRange: lineRange, contentRange: contentRange,
                contentEnd: contentEnd, indent: indent)
        }

        return parseListLine(
            source, lineRange: lineRange, contentRange: contentRange, indent: indent)
    }

    /// 剥行尾换行（CRLF 整体剥，保持 grapheme 边界语义）。
    private static func strippedContentEnd(_ source: NSString, lineRange: NSRange) -> Int {
        var contentEnd = NSMaxRange(lineRange)
        if contentEnd > lineRange.location {
            let last = source.character(at: contentEnd - 1)
            if last == ascii16("\n") {
                contentEnd -= 1
                if contentEnd > lineRange.location, source.character(at: contentEnd - 1) == ascii16("\r") {
                    contentEnd -= 1
                }
            }
        }
        return contentEnd
    }

    /// quote 行：扫描 `>` 深度，之后的内容递归跑 list/task 解析。
    private static func parseQuoteLine(
        _ source: NSString, lineRange: NSRange, contentRange: NSRange,
        contentEnd: Int, indent: Int
    ) -> MarkdownBlockLine {
        let length = contentRange.length
        var j = indent
        var depth = 0
        while j < length {
            let c = source.character(at: lineRange.location + j)
            if c == ascii16(">") {
                depth += 1
                j += 1
            } else if c == ascii16(" ") || c == ascii16("\t") {
                j += 1
            } else {
                break
            }
        }
        let quoteText = source.substring(with: NSRange(location: lineRange.location, length: j))
        let innerRange = NSRange(location: lineRange.location + j, length: contentEnd - (lineRange.location + j))
        let inner = innerRange.length > 0 ? parseLine(source, lineRange: innerRange) : nil
        if let inner, inner.kind != .none {
            return MarkdownBlockLine(
                fullLineRangeUTF16: lineRange, contentLineRangeUTF16: contentRange,
                kind: inner.kind, indentUTF16: inner.indentUTF16,
                prefixLength: j + inner.prefixLength, task: inner.task,
                quotePrefixText: quoteText, quoteDepth: depth,
                markerOffsetUTF16: j + inner.markerOffsetUTF16)
        }
        return MarkdownBlockLine(
            fullLineRangeUTF16: lineRange, contentLineRangeUTF16: contentRange,
            kind: .quote(depth: depth), indentUTF16: indent, prefixLength: j, task: nil,
            quotePrefixText: quoteText, quoteDepth: depth, markerOffsetUTF16: j)
    }

    /// list/task 行：无序 `- + *`、有序 `1. 1)`（紧贴内容不是 marker）。
    private static func parseListLine(
        _ source: NSString, lineRange: NSRange, contentRange: NSRange, indent: Int
    ) -> MarkdownBlockLine {
        let length = contentRange.length
        var afterMarker = indent
        let kind: MarkdownBlockLine.MarkerKind
        let c = source.character(at: lineRange.location + indent)
        if c == ascii16("-") || c == ascii16("+") || c == ascii16("*") {
            kind = .bullet(symbol: Character(UnicodeScalar(c) ?? "?"))
            afterMarker = indent + 1
        } else {
            var digits = 0
            var j = indent
            while j < length, isDigit(source.character(at: lineRange.location + j)) {
                digits += 1
                j += 1
            }
            if digits > 0, j < length,
                source.character(at: lineRange.location + j) == ascii16(".")
                    || source.character(at: lineRange.location + j) == ascii16(")")
            {
                let digitsText = source.substring(
                    with: NSRange(location: lineRange.location + indent, length: digits))
                let number = Int(digitsText) ?? 1
                let closerUnit = source.character(at: lineRange.location + j)
                kind = .ordered(number: number, closer: Character(UnicodeScalar(closerUnit) ?? "."))
                afterMarker = j + 1
            } else {
                return MarkdownBlockLine(
                    fullLineRangeUTF16: lineRange, contentLineRangeUTF16: contentRange,
                    kind: .none, indentUTF16: indent, prefixLength: 0, task: nil,
                    quotePrefixText: nil, quoteDepth: 0, markerOffsetUTF16: 0)
            }
        }
        let scanned = scanTrailingWhitespaceAndTask(
            source, lineRange: lineRange, contentRange: contentRange, afterMarker: afterMarker)
        if let task = scanned.task {
            return MarkdownBlockLine(
                fullLineRangeUTF16: lineRange, contentLineRangeUTF16: contentRange,
                kind: kind, indentUTF16: indent, prefixLength: scanned.prefixLength,
                task: task, quotePrefixText: nil, quoteDepth: 0,
                markerOffsetUTF16: indent)
        }
        if scanned.isMarker {
            return MarkdownBlockLine(
                fullLineRangeUTF16: lineRange, contentLineRangeUTF16: contentRange,
                kind: kind, indentUTF16: indent, prefixLength: scanned.prefixLength,
                task: nil, quotePrefixText: nil, quoteDepth: 0, markerOffsetUTF16: indent)
        }
        // "-x"/"1.x"：不是 marker，整行退回 none
        return MarkdownBlockLine(
            fullLineRangeUTF16: lineRange, contentLineRangeUTF16: contentRange,
            kind: .none, indentUTF16: indent, prefixLength: 0, task: nil,
            quotePrefixText: nil, quoteDepth: 0, markerOffsetUTF16: 0)
    }

    private struct TrailingScan {
        let prefixLength: Int
        let task: MarkdownBlockLine.TaskState?
        /// false = marker 后紧贴内容，整行不是 marker。
        let isMarker: Bool
    }

    /// marker 后尾随空白与 task 后缀扫描（`- [x] ` 前缀、`]' 后须有空格
    /// 或行尾；紧贴内容 "- [x]abc" 不是 task）。
    private static func scanTrailingWhitespaceAndTask(
        _ source: NSString, lineRange: NSRange, contentRange: NSRange, afterMarker: Int
    ) -> TrailingScan {
        let length = contentRange.length
        var k = afterMarker
        if k < length {
            let n = source.character(at: lineRange.location + k)
            if n != ascii16(" ") && n != ascii16("\t") {
                return TrailingScan(prefixLength: 0, task: nil, isMarker: false)
            }
            while k < length {
                let n = source.character(at: lineRange.location + k)
                if n == ascii16(" ") || n == ascii16("\t") { k += 1 } else { break }
            }
        }
        if k + 3 <= length,
            source.character(at: lineRange.location + k) == ascii16("["),
            [ascii16(" "), ascii16("x"), ascii16("X")].contains(source.character(at: lineRange.location + k + 1)),
            source.character(at: lineRange.location + k + 2) == ascii16("]")
        {
            var m = k + 3
            var isTask = m >= length  // 行尾 "- [x]" 也是合法 task 空项
            if !isTask {
                let n = source.character(at: lineRange.location + m)
                if n == ascii16(" ") || n == ascii16("\t") {
                    isTask = true
                    while m < length {
                        let n = source.character(at: lineRange.location + m)
                        if n == ascii16(" ") || n == ascii16("\t") { m += 1 } else { break }
                    }
                }
            }
            if isTask {
                return TrailingScan(
                    prefixLength: m,
                    task: MarkdownBlockLine.TaskState(
                        checkOffsetUTF16: lineRange.location + k + 1,
                        checked: source.character(at: lineRange.location + k + 1) != ascii16(" ")),
                    isMarker: true)
            }
        }
        return TrailingScan(prefixLength: k, task: nil, isMarker: true)
    }

    private static func isDigit(_ c: unichar) -> Bool {
        c >= ascii16("0") && c <= ascii16("9")
    }

    // MARK: - patch 规划

    /// 一次结构操作的规划结果。patches 为空表示「吞掉按键但无操作」
    /// （如最外层 Shift+Tab）；nil（在各 plan 函数返回 Optional 时）表示
    /// 该场景不归结构命令管，走默认行为。
    struct Plan: Equatable {
        let patches: [SourcePatch]
        let caretAfterUTF16: Int
        let name: String
    }

    /// Enter：内容非空 → 拆分（caret 后内容归新项，前缀照抄，有序编号
    /// 只新项 +1，task 复位）；内容空 → 由内向外退一层（list 缩进 →
    /// list marker → quote 层 → 删行退出，SPEC §4.3）。
    static func planEnter(line: MarkdownBlockLine, source: NSString, caret: Int) -> Plan? {
        switch line.kind {
        case .none:
            return nil
        default:
            break
        }
        if line.contentIsEmpty {
            return planEmptyLineExit(line, source: source)
        }
        let newPrefix = splitPrefixText(line, source: source)
        let insertAt = clamp(caret, line.contentStartUTF16, NSMaxRange(line.contentLineRangeUTF16))
        return Plan(
            patches: [
                SourcePatch(
                    rangeUTF16: NSRange(location: insertAt, length: 0),
                    expectedText: "", replacement: "\n" + newPrefix)
            ],
            caretAfterUTF16: insertAt + 1 + (newPrefix as NSString).length,
            name: line.hasListMarker ? "list-split" : "quote-split")
    }

    /// 空结构行 Enter 的退层序：内层 list 缩进 → list marker（quote 混合
    /// 行先退成纯 quote）→ quote 层 → 删行退出最外层。
    private static func planEmptyLineExit(_ line: MarkdownBlockLine, source: NSString) -> Plan? {
        if line.hasListMarker {
            if line.indentUTF16 >= 2 {
                let two = NSRange(
                    location: line.contentLineRangeUTF16.location + line.markerOffsetUTF16 - 2, length: 2)
                let removed = source.substring(with: two)
                guard removed.utf16.count == 2,
                    removed.allSatisfy({ $0 == " " || $0 == "\t" })
                else { return deleteFullLine(line, source: source, name: "list-exit") }
                return Plan(
                    patches: [SourcePatch(rangeUTF16: two, expectedText: removed, replacement: "")],
                    caretAfterUTF16: two.location,
                    name: "list-outdent-level")
            }
            if line.quoteDepth > 0 {
                return unmarkInnerList(line, source: source)
            }
            return deleteFullLine(line, source: source, name: "list-exit")
        }
        // 纯 quote 行
        if line.quoteDepth >= 2 {
            return removeOuterQuoteLayer(line, source: source, name: "quote-outdent")
        }
        return deleteFullLine(line, source: source, name: "quote-exit")
    }

    /// 剥内层 list marker（quote 混合空项退成纯 quote 行）。
    private static func unmarkInnerList(_ line: MarkdownBlockLine, source: NSString) -> Plan {
        let range = line.innerMarkerRange
        let text = source.substring(with: range)
        return Plan(
            patches: [SourcePatch(rangeUTF16: range, expectedText: text, replacement: "")],
            caretAfterUTF16: range.location,
            name: "quote-list-unmark")
    }

    /// 删 quote 前缀最后一个 `>`（`>> ` → `> `，`> x` → `x`）。仍有上层
    /// 时补一个空格保住内容列（`>> ab` → `> ab`）。
    private static func removeOuterQuoteLayer(
        _ line: MarkdownBlockLine, source: NSString, name: String
    ) -> Plan {
        let lineStart = line.contentLineRangeUTF16.location
        let quoteLen = line.quotePrefixText?.utf16.count ?? 0
        let cutEnd = lineStart + quoteLen
        var cutStart = cutEnd - 1
        while cutStart >= lineStart, source.character(at: cutStart) != ascii16(">") {
            cutStart -= 1
        }
        cutStart = max(cutStart, lineStart)
        let cut = NSRange(location: cutStart, length: cutEnd - cutStart)
        let removed = source.substring(with: cut)
        // cutStart 之前还有 `>` → 退层后仍是 quote 行，补空格分隔
        var stillQuote = false
        var probe = cutStart - 1
        while probe >= lineStart {
            if source.character(at: probe) == ascii16(">") { stillQuote = true; break }
            probe -= 1
        }
        return Plan(
            patches: [SourcePatch(rangeUTF16: cut, expectedText: removed, replacement: stillQuote ? " " : "")],
            caretAfterUTF16: stillQuote ? cutStart + 1 : cutStart,
            name: name)
    }

    /// 拆分项的新前缀字面：照抄现有前缀；task 复位 `[ ]`（拆出的新内容
    /// 是待办）；有序编号只新项 +1（SPEC「不全列表重新编号」）。
    private static func splitPrefixText(_ line: MarkdownBlockLine, source: NSString) -> String {
        let prefix = source.substring(with: line.prefixRange)
        var chars = Array(prefix)
        if line.task != nil, let close = chars.lastIndex(of: "]") {
            var open = close
            while open > 0, chars[open] != "[" { open -= 1 }
            if chars[open] == "[", open + 1 < chars.count { chars[open + 1] = " " }
        }
        var out = String(chars)
        if case .ordered(_, let closer) = line.kind {
            out = incrementOrderedMarker(out, closer: closer)
        }
        return out
    }

    /// 前缀中最后一个「数字+closer」编号 +1（只动编号，其余字节原样）。
    static func incrementOrderedMarker(_ prefix: String, closer: Character) -> String {
        let cs = Array(prefix)
        var idx = cs.count - 1
        while idx >= 0 {
            if cs[idx] == closer, idx > 0 {
                var dEnd = idx - 1
                var dStart = dEnd
                while dStart >= 0, cs[dStart].isNumber { dStart -= 1 }
                dStart += 1
                if dStart <= dEnd,
                    let current = Int(cs[dStart...dEnd].map(String.init).joined())
                {
                    return String(cs[0..<dStart]) + String(current + 1) + String(cs[idx...])
                }
            }
            idx -= 1
        }
        return prefix
    }

    /// Tab/Shift+Tab：list 缩进/退级（marker 前 2 空白）；quote 混合行退级
    /// 先内层缩进再 quote 层；纯 quote 行不处理（nil → 默认行为）；
    /// 最外层 Shift+Tab 吞掉但无操作。
    static func planTab(line: MarkdownBlockLine, source: NSString, caret: Int, indent: Bool) -> Plan? {
        switch line.kind {
        case .none, .quote:
            return nil
        case .bullet, .ordered:
            let markerAt = line.contentLineRangeUTF16.location + line.markerOffsetUTF16
            if indent {
                return Plan(
                    patches: [SourcePatch(rangeUTF16: NSRange(location: markerAt, length: 0), expectedText: "", replacement: "  ")],
                    caretAfterUTF16: caret + 2,
                    name: "list-indent")
            }
            if line.indentUTF16 >= 2 {
                let two = NSRange(location: markerAt - 2, length: 2)
                let removed = source.substring(with: two)
                guard removed.utf16.count == 2,
                    removed.allSatisfy({ $0 == " " || $0 == "\t" })
                else { return Plan(patches: [], caretAfterUTF16: caret, name: "list-outdent") }
                return Plan(
                    patches: [SourcePatch(rangeUTF16: two, expectedText: removed, replacement: "")],
                    caretAfterUTF16: caret - 2,
                    name: "list-outdent")
            }
            if line.quoteDepth >= 1 {
                // quote 行内 marker 前的多余间隙先清（Tab 缩进的可逆）：
                // ">   - a" Shift+Tab → "> - a"；间隙只剩标准 1 空格时退
                // quote 层
                let lineStart = line.contentLineRangeUTF16.location
                let quoteLen = line.quotePrefixText?.utf16.count ?? 0
                var lastGt = lineStart + quoteLen - 1
                while lastGt >= lineStart, source.character(at: lastGt) != ascii16(">") {
                    lastGt -= 1
                }
                let gap = markerAt - lastGt - 1
                if gap >= 2 {
                    let two = NSRange(location: markerAt - 2, length: 2)
                    let removed = source.substring(with: two)
                    if removed.utf16.count == 2,
                        removed.allSatisfy({ $0 == " " || $0 == "\t" })
                    {
                        return Plan(
                            patches: [SourcePatch(rangeUTF16: two, expectedText: removed, replacement: "")],
                            caretAfterUTF16: caret - 2,
                            name: "quote-list-dedent")
                    }
                }
                return removeOuterQuoteLayer(line, source: source, name: "quote-outdent")
            }
            return Plan(patches: [], caretAfterUTF16: caret, name: "list-outdent")
        }
    }

    /// Backspace 于内容首：由内向外退层——嵌套 list 先退一级缩进（项升级
    /// 为上级兄弟，不变懒延续行）；内层 marker 剥除（quote 混合退成纯
    /// quote）；quote 逐层退；最外层退出。其他 caret 位置返回 nil（普通
    /// 字符删除走 display diff 路径）。
    static func planBackspace(line: MarkdownBlockLine, source: NSString, caret: Int) -> Plan? {
        switch line.kind {
        case .none:
            return nil
        case .bullet, .ordered:
            guard caret == line.contentStartUTF16 else { return nil }
            if line.indentUTF16 >= 2 {
                let two = NSRange(
                    location: line.contentLineRangeUTF16.location + line.markerOffsetUTF16 - 2, length: 2)
                let removed = source.substring(with: two)
                guard removed.utf16.count == 2,
                    removed.allSatisfy({ $0 == " " || $0 == "\t" })
                else { return nil }
                return Plan(
                    patches: [SourcePatch(rangeUTF16: two, expectedText: removed, replacement: "")],
                    caretAfterUTF16: two.location,
                    name: "list-outdent")
            }
            return unmarkInnerList(line, source: source)
        case .quote:
            guard caret == line.contentStartUTF16 else { return nil }
            if line.quoteDepth >= 2 {
                return removeOuterQuoteLayer(line, source: source, name: "quote-unmark")
            }
            // 最外层：删最后一个 `>` 连同其后到内容起点的空白
            // （"> ab" → "ab"）。
            var cutStart = line.contentStartUTF16 - 1
            while cutStart > line.contentLineRangeUTF16.location,
                source.character(at: cutStart) == ascii16(" ")
                    || source.character(at: cutStart) == ascii16("\t")
            {
                cutStart -= 1
            }
            guard cutStart >= line.contentLineRangeUTF16.location,
                source.character(at: cutStart) == ascii16(">")
            else { return nil }
            let cut = NSRange(location: cutStart, length: line.contentStartUTF16 - cutStart)
            let removed = source.substring(with: cut)
            return Plan(
                patches: [SourcePatch(rangeUTF16: cut, expectedText: removed, replacement: "")],
                caretAfterUTF16: cutStart,
                name: "quote-unmark")
        }
    }

    /// Delete（前向）于空结构行：删除整行（与空项 Enter 退出同一 patch）。
    /// 空行的 caret 可停在内容起点前后一个 unit 内。非空行返回 nil，
    /// 走默认前向删除。
    static func planDeleteForward(line: MarkdownBlockLine, source: NSString, caret: Int) -> Plan? {
        guard line.kind != .none, line.contentIsEmpty,
            caret >= line.contentStartUTF16 - 1,
            caret <= NSMaxRange(line.fullLineRangeUTF16)
        else { return nil }
        return deleteFullLine(line, source: source, name: "line-delete-forward")
    }

    /// task 勾选翻转：只替换括号内单字符（` `↔`x`），marker 与其余字节
    /// 原样（NE-07 精确 span）。
    static func planTaskToggle(line: MarkdownBlockLine) -> SourcePatch? {
        guard let task = line.task else { return nil }
        let current = task.checked ? "x" : " "
        let next = task.checked ? " " : "x"
        return SourcePatch(
            rangeUTF16: NSRange(location: task.checkOffsetUTF16, length: 1),
            expectedText: current, replacement: next)
    }

    private static func deleteFullLine(
        _ line: MarkdownBlockLine, source: NSString, name: String
    ) -> Plan {
        let full = source.substring(with: line.fullLineRangeUTF16)
        return Plan(
            patches: [SourcePatch(rangeUTF16: line.fullLineRangeUTF16, expectedText: full, replacement: "")],
            caretAfterUTF16: line.fullLineRangeUTF16.location,
            name: name)
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(v, lo), max(lo, hi))
    }
}
