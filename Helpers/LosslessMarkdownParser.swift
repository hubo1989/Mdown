import Foundation

/// T03 原型：无损块级解析。
/// 权威 source 永远是未处理的原文；块结构由行扫描器产生（行锚定，
/// 天然可逆：所有块 range 串联覆盖全文，slices 重建 == 原文）。
/// cmark-gfm 不在本层：它作为语义对照通道由测试实测并 pin（见
/// LosslessMarkdownParserTests 的 sourcepos 对照），preview 管线照旧。
///
/// 支持范围（T03 原型）：frontmatter、ATX heading、fenced code（```/~~~，
/// 嵌套 fence 按更长闭 fence）、indented code（4 空格或 1 tab）、
/// blockquote、有序/无序列表（缩进深度）、thematic break、GFM table
/// （delimiter 行识别）、html block（`<` 标签开头行）、blank、paragraph。
/// Pending（原样保留在原文中，不做投影结构）：link reference definition
/// 的独立拆分、footnote 定义、autolink/raw inline HTML、setext heading。
struct LosslessMarkdownParser {

    enum BlockKind: Equatable {
        case frontmatter
        case heading(level: Int)
        case paragraph
        case listItem(depth: Int, ordered: Bool)
        case codeFence(info: String)
        case codeIndented
        case quote(depth: Int)
        case table
        case thematicBreak
        case htmlBlock
        case blank
    }

    struct Block: Equatable {
        let kind: BlockKind
        /// 原文 UTF-16 范围（含 marker、内容与结尾换行；末块含文件末尾）。
        let rangeUTF16: NSRange
        /// 1-based 起止行（闭区间）。
        let startLine: Int
        let endLine: Int
    }

    struct Document: Equatable {
        let source: String
        let blocks: [Block]
        /// 每行（1-based → 下标 0）起始 UTF-16 偏移；行按 \n 切分，\r 保留在行内。
        let lineStartUTF16: [Int]

        /// 无损不变量：块按序、互不重叠且联合覆盖 [0, source.utf16.count)。
        var isLossless: Bool {
            guard let first = blocks.first, first.rangeUTF16.location == 0 else { return false }
            var cursor = 0
            let total = source.utf16.count
            for block in blocks {
                guard block.rangeUTF16.location == cursor else { return false }
                cursor = block.rangeUTF16.location + block.rangeUTF16.length
            }
            return cursor == total
        }

        /// cmark 对照用：1-based (line, utf8Column) → UTF-16 偏移。
        /// cmark 列按 UTF-8 byte 计（tab 计 1 byte），本函数据此换算。
        func utf16Offset(line: Int, utf8Column: Int) -> Int? {
            guard line >= 1, line - 1 < lineStartUTF16.count else { return nil }
            let lineStart = lineStartUTF16[line - 1]
            let lineEnd = line < lineStartUTF16.count ? lineStartUTF16[line] : source.utf16.count
            guard lineEnd > lineStart else { return utf8Column <= 1 ? lineStart : nil }
            let lineText = (source as NSString).substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            guard utf8Column >= 1 else { return nil }
            let bytes = Array(lineText.utf8)
            guard utf8Column - 1 <= bytes.count else { return nil }
            // String(decoding:) 是非可选解码；规则把 bytes 前缀误判为 Data 转换
            // swiftlint:disable:next optional_data_string_conversion
            let prefix = String(decoding: bytes[0..<(utf8Column - 1)], as: UTF8.self)
            return lineStart + prefix.utf16.count
        }
    }

    func parse(_ source: String) -> Document {
        let lines = splitLines(source)
        var lineStarts: [Int] = []
        var cursor = 0
        for line in lines {
            lineStarts.append(cursor)
            cursor += line.utf16.count + 1  // 行内容 + 行尾 \n（最后一行无 \n 时多计的 1 由 total 截断兜底）
        }

        var blocks: [Block] = []
        let idx = LineIndex(lines: lines, lineStarts: lineStarts, total: source.utf16.count)
        var index = 0
        let hasBOM = source.hasPrefix("\u{FEFF}")

        // frontmatter：可选 BOM 后首行 --- 到下一个 --- 行（含）
        if let fmEnd = frontmatterEndLine(lines, hasBOM: hasBOM) {
            blocks.append(makeBlock(.frontmatter, index: idx, from: 0, through: fmEnd))
            index = fmEnd + 1
        }

        while index < lines.count {
            let line = lines[index]
            let kind = classifyLine(line, previousKind: blocks.last?.kind)

            switch kind {
            case .codeFence:
                index = consumeFence(from: index, lines: lines) { kind, from, through in
                    blocks.append(idx.block(kind, from: from, through: through))
                }
            case .blank, .paragraph, .heading, .thematicBreak, .htmlBlock:
                let (block, next) = consumeSingleOrParagraph(kind, at: index, lines: lines, index: idx)
                blocks.append(block)
                index = next
            case .table:
                // delimiter 行的上一行（header）已作为 paragraph 入列——弹出并入 table
                if let last = blocks.last, last.endLine == index, case .paragraph = last.kind {
                    blocks.removeLast()
                }
                let (block, next) = consumeTable(at: index, lines: lines, index: idx)
                blocks.append(block)
                index = next
            case .quote, .listItem, .codeIndented:
                let (block, next) = consumeContainer(kind, at: index, lines: lines, index: idx)
                blocks.append(block)
                index = next
            case .frontmatter:
                // 非首位置的 --- 已由 thematicBreak/quote 等规则处理，此分支不可达
                let (block, next) = consumeSingleOrParagraph(.paragraph, at: index, lines: lines, index: idx)
                blocks.append(block)
                index = next
            }
        }

        return Document(source: source, blocks: blocks, lineStartUTF16: lineStarts)
    }

    // MARK: - 行切分（保留 \r，CRLF 是一个换行 grapheme 的两半各归其行）

    private func splitLines(_ source: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in source.unicodeScalars {
            if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        lines.append(String(current))
        return lines
    }

    // MARK: - frontmatter

    private func frontmatterEndLine(_ lines: [String], hasBOM: Bool) -> Int? {
        let first = hasBOM ? String(lines.first?.dropFirst() ?? "") : (lines.first ?? "")
        guard first.trimmingCharacters(in: .whitespacesAndNewlines) == "---", lines.count >= 2 else { return nil }
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            return i
        }
        return nil
    }

    // MARK: - 行分类

    private func classifyLine(_ rawLine: String, previousKind: BlockKind?) -> BlockKind {
        let line = (rawLine.hasPrefix("\u{FEFF}") ? String(rawLine.dropFirst()) : rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty { return .blank }

        // ATX heading
        if let level = atxHeadingLevel(trimmed) { return .heading(level: level) }

        // indented code：4 空格或 1 tab 缩进；但在列表/引用容器延续语境中，
        // 剥缩进后仍是 marker 行的属于嵌套项（CommonMark 内容列规则的原型近似）
        if line.hasPrefix("    ") || line.hasPrefix("\t") {
            if case .listItem = previousKind ?? .blank {
                let stripped = String(line.drop { $0 == " " || $0 == "\t" })
                if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") || stripped.hasPrefix("+ ")
                    || listMarker(stripped) != nil
                {
                    return .listItem(depth: indentDepth(line), ordered: listMarker(stripped)?.0 ?? false)
                }
            }
            if case .quote = previousKind ?? .blank, line.drop { $0 == " " }.hasPrefix(">") {
                return .quote(depth: 1)
            }
            return .codeIndented
        }

        // fence（优先于 thematic break：``` 也是 fence）。缩进 ≤3 空格的开
        // fence 是合法 fence；≥4 空格/tab 的已被上面的 indented code 承接
        // （CommonMark 内容列规则）。
        if let info = fenceInfo(trimmed) { return .codeFence(info: info) }

        // quote
        if line.hasPrefix(">") {
            let depth = quoteDepth(line)
            return .quote(depth: depth)
        }

        // list item
        if let (ordered, _) = listMarker(trimmed) {
            return .listItem(depth: indentDepth(line), ordered: ordered)
        }

        // thematic break：--- / *** / ___（3+，仅同字符）
        if isThematicBreak(trimmed) { return .thematicBreak }

        // html block：`<` + 字母
        if trimmed.hasPrefix("<"), trimmed.dropFirst().first?.isLetter == true { return .htmlBlock }

        // GFM table：上一非空行是 header 且本行是 delimiter
        if isTableDelimiter(trimmed), case .paragraph = previousKind { return .table }

        return .paragraph
    }

    private func atxHeadingLevel(_ trimmed: String) -> Int? {
        guard let first = trimmed.first, first == "#" else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard level <= 6 else { return nil }
        let after = trimmed.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return level
    }

    private func fenceInfo(_ trimmed: String) -> String? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var count = 0
        for ch in trimmed {
            if ch == first { count += 1 } else { break }
        }
        guard count >= 3 else { return nil }
        let info = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        if first == "`" && info.contains("`") { return nil }
        return info
    }

    private func quoteDepth(_ line: String) -> Int {
        var depth = 0
        var rest = Substring(line)
        while true {
            let t = rest.drop { $0 == " " || $0 == "\t" }
            guard t.hasPrefix(">") else { break }
            depth += 1
            rest = t.dropFirst().drop { $0 == " " }
        }
        return max(depth, 1)
    }

    private func listMarker(_ trimmed: String) -> (ordered: Bool, marker: String)? {
        // 无序：- + * 后跟空格
        if let first = trimmed.first, "-+*".contains(first) {
            let after = trimmed.dropFirst()
            if after.isEmpty || after.first == " " || after.first == "\t" {
                return (false, String(first))
            }
        }
        // 有序：1-9 位数字 + . 或 ) + 空格
        var digits = 0
        for ch in trimmed {
            if ch.isNumber { digits += 1; if digits > 9 { return nil } } else { break }
        }
        if digits > 0 {
            let afterDigits = trimmed.dropFirst(digits)
            if let mark = afterDigits.first, mark == "." || mark == ")" {
                let after = afterDigits.dropFirst()
                if after.isEmpty || after.first == " " || after.first == "\t" {
                    return (true, "\(trimmed.prefix(digits))\(mark)")
                }
            }
        }
        return nil
    }

    private func indentDepth(_ line: String) -> Int {
        // 每 2 空格或 1 tab 一级（原型约定，G0 三层 list 够用）
        var depth = 0
        for ch in line {
            if ch == " " {
                depth += 1
            } else if ch == "\t" {
                depth += 2
            } else {
                break
            }
        }
        return depth / 2
    }

    private func isThematicBreak(_ trimmed: String) -> Bool {
        let chars = Set(trimmed.filter { !$0.isWhitespace })
        guard chars.count == 1, let only = chars.first, "-*_".contains(only) else { return false }
        return trimmed.filter { $0 == only }.count >= 3
    }

    private func isTableDelimiter(_ trimmed: String) -> Bool {
        let t = trimmed.hasPrefix("|") ? String(trimmed.dropFirst()) : trimmed
        let body = t.hasSuffix("|") ? String(t.dropLast()) : t
        guard !body.isEmpty else { return false }
        let cells = body.split(separator: "|", omittingEmptySubsequences: false)
        return !cells.isEmpty
            && cells.allSatisfy { cell in
                let c = cell.trimmingCharacters(in: .whitespaces)
                return !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" } && c.contains("-")
            }
    }

    // MARK: - 块消费

    /// 行索引上下文：lines 与其 UTF-16 起点、全文长度打包，避免参数超限。
    private struct LineIndex {
        let lines: [String]
        let lineStarts: [Int]
        let total: Int

        func block(_ kind: BlockKind, from: Int, through: Int) -> Block {
            let lower = lineStarts[from]
            let upper = through + 1 < lineStarts.count ? lineStarts[through + 1] : total
            return Block(
                kind: kind,
                rangeUTF16: NSRange(location: lower, length: upper - lower),
                startLine: from + 1, endLine: through + 1
            )
        }
    }

    private func makeBlock(
        _ kind: BlockKind, index: LineIndex, from: Int, through: Int
    ) -> Block {
        index.block(kind, from: from, through: through)
    }

    /// fence 块：开 fence 行到匹配闭 fence（同字符且长度 ≥ 开 fence）行；无闭则到 EOF。
    private func consumeFence(
        from start: Int, lines: [String], append: (BlockKind, Int, Int) -> Void
    ) -> Int {
        let open = lines[start]
        // openLen 必须按 trimmed 行计算：开 fence 行可带 ≤3 空格缩进，
        // 按原始行计数时前导空白使 openLen=0，闭 fence 判定退化为恒真
        // （首个空行即提前闭合）且 info 串入反引号。
        let openTrimmed = open.trimmingCharacters(in: .whitespaces)
        let openChar = openTrimmed.first!
        let openLen = openTrimmed.prefix { $0 == openChar }.count
        let info = String(openTrimmed.dropFirst(openLen)).trimmingCharacters(in: .whitespaces)
        var i = start + 1
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.prefix { $0 == openChar }.count >= openLen,
                t.allSatisfy({ $0 == openChar || $0.isWhitespace })
            {
                append(.codeFence(info: info), start, i)
                return i + 1
            }
            i += 1
        }
        append(.codeFence(info: info), start, lines.count - 1)
        return lines.count
    }

    /// 单行块（blank/heading/hr/html）或段落（延续到空行/新块开始）。
    private func consumeSingleOrParagraph(
        _ kind: BlockKind, at start: Int, lines: [String], index: LineIndex
    ) -> (Block, Int) {
        switch kind {
        case .blank, .heading, .thematicBreak, .htmlBlock:
            return (makeBlock(kind, index: index, from: start, through: start), start + 1)
        default:
            var i = start + 1
            while i < lines.count {
                let next = classifyLine(lines[i], previousKind: .paragraph)
                switch next {
                case .paragraph, .listItem, .quote:
                    i += 1  // 懒延续（原型简化：列表/引用前导行并入段落）
                default:
                    var end = i - 1
                    // 段落末尾的连续 blank 行不属于段落
                    while end > start, case .blank = classifyLine(lines[end], previousKind: nil) { end -= 1 }
                    return (makeBlock(.paragraph, index: index, from: start, through: end), end + 1)
                }
            }
            return (makeBlock(.paragraph, index: index, from: start, through: lines.count - 1), lines.count)
        }
    }

    /// table：header 行 + delimiter 行 + 连续含 | 的行。
    private func consumeTable(at start: Int, lines: [String], index: LineIndex) -> (Block, Int) {
        let header = start - 1  // delimiter 的上一行（由调用方保证是 paragraph 末行）
        var i = start + 1
        while i < lines.count {
            let t = lines[i]
            if t.contains("|") && !t.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
            } else {
                break
            }
        }
        return (makeBlock(.table, index: index, from: header, through: i - 1), i)
    }

    /// 容器（quote/list/indented code）：连续同 kind 行并入一个块（原型简化，
    /// 不做完整 CommonMark 容器延续；跨容器结构在支持表中列为 pending）。
    private func consumeContainer(
        _ kind: BlockKind, at start: Int, lines: [String], index: LineIndex
    ) -> (Block, Int) {
        var i = start + 1
        var end = start
        while i < lines.count {
            let next = classifyLine(lines[i], previousKind: kind)
            let continues: Bool
            switch (kind, next) {
            case (.quote, .quote), (.quote, .paragraph), (.quote, .blank),
                (.listItem, .listItem), (.listItem, .paragraph), (.listItem, .blank),
                (.codeIndented, .codeIndented), (.codeIndented, .blank):
                // quote 行不被并入列表容器（引用开始新块；引用内列表由 quote 容器承接）
                continues = true
            default:
                continues = false
            }
            if continues {
                end = i
                i += 1
            } else {
                break
            }
        }
        // 尾部 blank 不并入容器
        while end > start, case .blank = classifyLine(lines[end], previousKind: nil) { end -= 1 }
        return (makeBlock(kind, index: index, from: start, through: end), end + 1)
    }
}

/// T03: revision-guarded parse 结果发布器。
/// parse 在后台异步完成时，旧 revision 的结果到达必须丢弃，最新的
/// document 最终收敛；字符操作同步推进的局部 map 在 T04 视图层叠加。
@MainActor
final class LosslessParseCoordinator {
    private(set) var currentRevision: UInt64 = 0
    private(set) var currentDocument: LosslessMarkdownParser.Document?

    /// 发布 parse 结果。revision 必须严格递增；旧 revision 一律拒绝返回 false。
    @discardableResult
    func publish(_ document: LosslessMarkdownParser.Document, revision: UInt64) -> Bool {
        guard revision > currentRevision else { return false }
        currentRevision = revision
        currentDocument = document
        return true
    }
}
