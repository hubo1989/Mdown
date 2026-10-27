import Foundation

// MARK: - T16 GFM 表格模型(PLAN T16 / SPEC NE-09 / AC-11)
//
// 纯逻辑层:把 table 块的 source 解析为 cell 的 UTF-16 区间与结构事实
// (对齐/分隔行/行列/stable IDs),一切修改以 SourcePatch 计划表达——
// 应用统一走 MarkdownPatchApplier(同 base 降序、expectedText 逐字节
// 校验),模型自身不改 source、不持有权威正文。行原文与行尾(verbatim,
// LF/CRLF/无)在 parse 时逐行缓存,patch 的 expectedText 用缓存原文,
// 保证字节精确。
//
// 管道拆分:`\|` 转义(反斜杠 run 奇偶判定)与 code span 内 `|` 不拆
// (backtick run 定长配对,``a`b`` 不失步);写入 cell 文本时只转义尚未
// 转义的管道,cell.text 往返不双转义。
//
// 结构约束(GFM):分隔行必须紧跟头行——头行后插行自动落到分隔行后;
// 头行与分隔行不可删;单列表格不可删列(删尽即破坏结构)。
//
// stable IDs:行 UUID + 列 UUID 数组,快照内可作定位键。跨 parse 的
// ID 稳定性需要视图层按编辑事务传播(当前视图层按 index 定位,见
// README 的 remaining UI 限制)。

enum MarkdownTableAlignment: String, Equatable {
    case none
    case left
    case center
    case right
}

struct MarkdownTableCell: Equatable {
    /// cell 文本(不含边界管道与分隔空格)在整篇 source 内的区间。
    let rangeUTF16: NSRange
    /// source 切片原文(`\|` 保持转义形态,不做 unescape)。
    let text: String
}

struct MarkdownTableRow: Equatable {
    /// 快照内稳定的行标识(parse 时分配)。
    let id: UUID
    /// 行内容(不含行尾)区间。
    let rangeUTF16: NSRange
    /// 行内容 + 行尾换行(存在时)的区间(deleteRow 用)。
    let fullRangeUTF16: NSRange
    /// 行内容原文(parse 时缓存,expectedText 用;不含 CR/LF)。
    let lineText: String
    /// 行尾 verbatim("\n" / "\r\n" / "" 末行无换行)。
    let lineEnding: String
    let cells: [MarkdownTableCell]
    let isDelimiter: Bool
}

/// 一次表格结构修改:patch 组(同 base 坐标)+ 应用后 caret 落点
/// (source 坐标;视图层经投影映射)。
struct MarkdownTablePlan: Equatable {
    let patches: [SourcePatch]
    let caretAfterUTF16: Int?
}

struct MarkdownTableModel: Equatable {
    let rangeUTF16: NSRange
    let rows: [MarkdownTableRow]
    /// 列对齐;来自分隔行,不足列按 .none。
    let alignments: [MarkdownTableAlignment]
    /// 列标识(快照内稳定;count = columnCount)。
    let columnIDs: [UUID]

    var columnCount: Int {
        rows.first(where: { !$0.isDelimiter })?.cells.count
            ?? rows.first?.cells.count ?? 0
    }

    /// 行 ID → rows 下标(快照内定位;未知 ID 返回 nil)。
    func rowIndex(of id: UUID) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    /// 头行下标(GFM 表格首行;无有效表格结构时 nil)。
    var headerIndex: Int? {
        guard let first = rows.first, !first.isDelimiter else { return nil }
        return 0
    }

    /// 分隔行下标。
    var delimiterIndex: Int? {
        rows.firstIndex(where: \.isDelimiter)
    }

    // MARK: - 解析

    /// 解析 blockRange 内的 table 块(逐行;调用方保证块类型是 table)。
    /// blockRange 非法(越界/负长度)返回空模型,调用方按普通块处理。
    static func parse(source: String, blockRange: NSRange) -> MarkdownTableModel {
        let ns = source as NSString
        guard blockRange.location >= 0, blockRange.length >= 0,
            NSMaxRange(blockRange) <= ns.length
        else {
            return MarkdownTableModel(
                rangeUTF16: blockRange, rows: [], alignments: [], columnIDs: [])
        }
        var rows: [MarkdownTableRow] = []
        var lineLoc = blockRange.location
        let blockEnd = NSMaxRange(blockRange)
        while lineLoc < blockEnd {
            let lineRange = ns.lineRange(for: NSRange(location: lineLoc, length: 0))
            guard NSMaxRange(lineRange) <= blockEnd else { break }
            // 行内容 = 去掉行尾换行(LF,或 CRLF 的两个 code unit)
            var contentEnd = NSMaxRange(lineRange)
            if contentEnd > lineRange.location, ns.character(at: contentEnd - 1) == 0x0A {
                contentEnd -= 1
                if contentEnd > lineRange.location, ns.character(at: contentEnd - 1) == 0x0D {
                    contentEnd -= 1
                }
            }
            let contentRange = NSRange(
                location: lineRange.location, length: contentEnd - lineRange.location)
            let lineText = ns.substring(with: contentRange)
            let ending = ns.substring(
                with: NSRange(
                    location: contentEnd, length: NSMaxRange(lineRange) - contentEnd))
            let cells = parseCells(ns: ns, lineRange: contentRange)
            let isDelimiter = !cells.isEmpty && cells.allSatisfy { isDelimiterCell($0.text) }
            rows.append(
                MarkdownTableRow(
                    id: UUID(),
                    rangeUTF16: contentRange,
                    fullRangeUTF16: NSRange(
                        location: lineRange.location,
                        length: NSMaxRange(lineRange) - lineRange.location),
                    lineText: lineText,
                    lineEnding: ending,
                    cells: cells,
                    isDelimiter: isDelimiter))
            lineLoc = NSMaxRange(lineRange)
        }
        let alignments =
            rows.first(where: \.isDelimiter).map { row in
                row.cells.map { alignment(of: $0.text) }
            } ?? []
        let columnCount =
            rows.first(where: { !$0.isDelimiter })?.cells.count
            ?? rows.first?.cells.count ?? 0
        return MarkdownTableModel(
            rangeUTF16: blockRange,
            rows: rows,
            alignments: alignments,
            columnIDs: (0..<columnCount).map { _ in UUID() })
    }

    /// 按未转义、code span 外的 `|` 切 cell;首尾边界管道剥除,cell 文本
    /// 两侧单空格裁掉。行首无管道时首个 cell 从行首起。
    ///
    /// code span:backtick run 定长配对(GFM)——长度 N 的 run 只被同长
    /// run 闭合,``a`b`` 内的单个反引号是字面量,不会失步。
    /// 转义:管道前反斜杠 run 奇数 = 转义(含 `\\|` 字面反斜杠 + 未转义
    /// 管道、`\\\|` 字面反斜杠 + 转义管道的奇偶语义)。
    private static func parseCells(ns: NSString, lineRange: NSRange) -> [MarkdownTableCell] {
        var cells: [MarkdownTableCell] = []
        var cellStart = -1
        var openCodeRun = 0  // 打开中的 code span backtick run 长度;0 = 闭合
        let end = NSMaxRange(lineRange)

        func backslashRun(before i: Int) -> Int {
            var count = 0
            var j = i - 1
            while j >= lineRange.location, ns.character(at: j) == 0x5C {
                count += 1
                j -= 1
            }
            return count
        }

        func emit(from start: Int, to pipeAt: Int) {
            var s = start
            var e = pipeAt
            if e > s, ns.character(at: e - 1) == 0x20, e - 1 > s { e -= 1 }
            if s < e, ns.character(at: s) == 0x20, s + 1 < e { s += 1 }
            guard e >= s else { return }
            cells.append(
                MarkdownTableCell(
                    rangeUTF16: NSRange(location: s, length: e - s),
                    text: ns.substring(with: NSRange(location: s, length: e - s))))
        }

        var i = lineRange.location
        while i < end {
            let u = ns.character(at: i)
            if u == 0x60 {  // ` run
                var run = 0
                while i + run < end, ns.character(at: i + run) == 0x60 { run += 1 }
                if openCodeRun == 0 {
                    openCodeRun = run
                } else if run == openCodeRun {
                    openCodeRun = 0  // 同长 run 才闭合
                }
                // 长度不匹配的 run 是 span 内字面量,不改变开闭状态
                i += run
                continue
            }
            if u == 0x7C, openCodeRun == 0, backslashRun(before: i) % 2 == 0 {
                if cellStart >= 0 {
                    emit(from: cellStart, to: i)
                } else if i > lineRange.location {
                    emit(from: lineRange.location, to: i)  // 行首无管道
                }
                cellStart = i + 1  // 行首边界管道:仅移动起点
            }
            i += 1
        }
        // 行尾(无尾管道)收最后一个 cell
        if cellStart < end {
            emit(from: cellStart >= 0 ? cellStart : lineRange.location, to: end)
        }
        return cells
    }

    private static func isDelimiterCell(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
            && trimmed.contains("-")
            && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
    }

    private static func alignment(of text: String) -> MarkdownTableAlignment {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch (t.hasPrefix(":"), t.hasSuffix(":")) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        case (false, false): return .none
        }
    }

    // MARK: - 转义 helper

    /// 只转义「尚未被转义」的管道:反斜杠 run 为偶数(含 0)的 `|` 前补
    /// `\`。cell.text(`x \| y`)经此函数往返不双转义;用户裸输入的
    /// `new|value` 照常转义。
    static func escapePipes(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf16.count)
        var backslashes = 0
        for ch in text {
            if ch == "\\" {
                backslashes += 1
                out.append(ch)
            } else if ch == "|" {
                if backslashes % 2 == 0 {
                    out.append("\\")
                }
                out.append("|")
                backslashes = 0
            } else {
                backslashes = 0
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - 修改计划(pure;不改 source)

    /// 覆盖单元格文本;文本按 source 形态理解,未转义管道写入时转义。
    /// row 必须是非分隔行。
    func setCell(row: Int, column: Int, text: String) -> MarkdownTablePlan? {
        guard rows.indices.contains(row), !rows[row].isDelimiter,
            rows[row].cells.indices.contains(column)
        else { return nil }
        let cell = rows[row].cells[column]
        let replacement = Self.escapePipes(text)
        return MarkdownTablePlan(
            patches: [
                SourcePatch(
                    rangeUTF16: cell.rangeUTF16,
                    expectedText: cell.text,
                    replacement: replacement)
            ],
            caretAfterUTF16: cell.rangeUTF16.location + (replacement as NSString).length)
    }

    /// 在 row 行后插入整行空单元格(单 patch,天然原子)。分隔符紧跟
    /// 头行是 GFM 硬约束:在头行后插行自动落到分隔行之后,避免把数据行
    /// 插进头行与分隔行之间破坏表格。行尾沿用目标行(目标行无行尾时用
    /// 其前一行的行尾,保证新行仍是独立行且无末尾换行形态保真)。
    func insertRow(after row: Int, columnCount columns: Int) -> MarkdownTablePlan? {
        guard rows.indices.contains(row), columns > 0 else { return nil }
        var target = row
        if row == headerIndex, let delimiter = delimiterIndex, delimiter == row + 1 {
            target = delimiter  // 头行后 → 分隔行后
        }
        let line = Self.rebuildLine(cells: Array(repeating: "", count: columns))
        let separator =
            rows[target].lineEnding.isEmpty
            ? (target > 0 ? rows[target - 1].lineEnding : "\n")
            : rows[target].lineEnding
        let ending = separator.isEmpty ? "\n" : separator
        let insertAt = NSMaxRange(rows[target].rangeUTF16)  // 行尾换行前
        let replacement = ending + line
        return MarkdownTablePlan(
            patches: [
                SourcePatch(
                    rangeUTF16: NSRange(location: insertAt, length: 0),
                    expectedText: "",
                    replacement: replacement)
            ],
            caretAfterUTF16: insertAt + 2 + ending.utf16.count)  // 行尾 + "| " 后 = 首格起点
    }

    /// 末行 Enter 追加行。
    func appendRow(columnCount columns: Int) -> MarkdownTablePlan? {
        guard !rows.isEmpty else { return nil }
        return insertRow(after: rows.count - 1, columnCount: columns)
    }

    /// 删除整行(含行尾换行,expectedText 用 parse 缓存的 verbatim 行尾)。
    /// 结构保护:头行与分隔行不可删(删后不再是合法 GFM 表格);退化输入
    /// (首行即分隔行)允许删非分隔行。末行无换行时连同上一行的行尾一并
    /// 消费,保住「无末尾换行」形态。
    func deleteRow(_ row: Int) -> MarkdownTablePlan? {
        guard rows.indices.contains(row) else { return nil }
        guard !rows[row].isDelimiter else { return nil }
        if let header = headerIndex, row == header, rows.count > 1 { return nil }
        let target = rows[row]
        if target.lineEnding.isEmpty, row > 0 {
            let previous = rows[row - 1]
            let replaceRange = NSRange(
                location: previous.fullRangeUTF16.location,
                length: NSMaxRange(target.fullRangeUTF16) - previous.fullRangeUTF16.location)
            return MarkdownTablePlan(
                patches: [
                    SourcePatch(
                        rangeUTF16: replaceRange,
                        expectedText: previous.lineText + previous.lineEnding
                            + target.lineText,
                        replacement: previous.lineText)
                ],
                caretAfterUTF16: previous.rangeUTF16.location)
        }
        let patches = [
            SourcePatch(
                rangeUTF16: target.fullRangeUTF16,
                expectedText: target.lineText + target.lineEnding,
                replacement: "")
        ]
        return MarkdownTablePlan(patches: patches, caretAfterUTF16: target.rangeUTF16.location)
    }

    /// 删除一列:逐行(含分隔行)整行重建,同 base 多 patch。单列表格
    /// 拒绝——删尽唯一列后 `| |` 行不再是表格。
    func deleteColumn(_ column: Int) -> MarkdownTablePlan? {
        guard column >= 0, column < columnCount, columnCount > 1 else { return nil }
        var patches: [SourcePatch] = []
        for row in rows where row.cells.indices.contains(column) {
            var texts = row.cells.map(\.text)
            texts.remove(at: column)
            patches.append(
                SourcePatch(
                    rangeUTF16: row.rangeUTF16,
                    expectedText: row.lineText,
                    replacement: Self.rebuildLine(cells: texts)))
        }
        guard !patches.isEmpty else { return nil }
        return MarkdownTablePlan(
            patches: patches, caretAfterUTF16: rows.first?.rangeUTF16.location)
    }

    /// 在 column 前插入空列:逐行重建(分隔行补 `---`,对齐 .none)。
    func insertColumn(before column: Int) -> MarkdownTablePlan? {
        guard column >= 0, column <= columnCount else { return nil }
        var patches: [SourcePatch] = []
        for row in rows {
            var texts = row.cells.map(\.text)
            let index = min(column, texts.count)
            if row.isDelimiter {
                texts.insert("---", at: index)
            } else {
                texts.insert("", at: index)
            }
            patches.append(
                SourcePatch(
                    rangeUTF16: row.rangeUTF16,
                    expectedText: row.lineText,
                    replacement: Self.rebuildLine(cells: texts)))
        }
        guard !patches.isEmpty else { return nil }
        return MarkdownTablePlan(
            patches: patches, caretAfterUTF16: rows.first?.rangeUTF16.location)
    }

    /// 移动数据行(头行/分隔行不可移动;from == to 返回 nil)。
    /// 整表一次替换(单 patch 原子);每行携带自身行文本,块尾换行形态
    /// (有/无末尾换行)保真——混合行尾表格仍输出合法表格,行内字节不动。
    func moveRow(from: Int, to: Int) -> MarkdownTablePlan? {
        let bodyRange = rows.indices.filter { $0 != headerIndex && $0 != delimiterIndex }
        guard bodyRange.contains(from), bodyRange.contains(to), from != to else { return nil }
        var order = bodyRange
        let moved = order.remove(at: bodyRange.firstIndex(of: from)!)
        order.insert(moved, at: bodyRange.firstIndex(of: to)!)
        let fullOrder = [headerIndex, delimiterIndex].compactMap { $0 } + order

        // 行随自身行文本移动;仅规整块尾:保持原块「有/无末尾换行」形态。
        let hadFinalEnding = !(rows.last?.lineEnding.isEmpty ?? true)
        let fallbackEnding = rows.first { !$0.lineEnding.isEmpty }?.lineEnding ?? "\n"
        var text = ""
        for (position, rowIndex) in fullOrder.enumerated() {
            text += rows[rowIndex].lineText
            let isLast = position == fullOrder.count - 1
            if isLast {
                if hadFinalEnding {
                    text +=
                        rows[rowIndex].lineEnding.isEmpty
                        ? fallbackEnding : rows[rowIndex].lineEnding
                }
                // 原块无末尾换行:末行不补 ending
            } else {
                text +=
                    rows[rowIndex].lineEnding.isEmpty
                    ? fallbackEnding : rows[rowIndex].lineEnding
            }
        }
        guard let block = fullBlockRange() else { return nil }
        let caret =
            block.location
            + fullOrder.prefix(while: { $0 != moved }).reduce(0) { $0 + rows[$1].fullRangeUTF16.length }
        return MarkdownTablePlan(
            patches: [
                SourcePatch(
                    rangeUTF16: block,
                    expectedText: reconstructBlockText(),
                    replacement: text)
            ],
            caretAfterUTF16: caret)
    }

    /// 移动列:逐行(含分隔行)cell 重排重建,对齐 marker 随 cell 移动。
    func moveColumn(from: Int, to: Int) -> MarkdownTablePlan? {
        guard from >= 0, from < columnCount, to >= 0, to < columnCount, from != to else {
            return nil
        }
        var patches: [SourcePatch] = []
        for row in rows where row.cells.count == columnCount {
            var texts = row.cells.map(\.text)
            let moved = texts.remove(at: from)
            texts.insert(moved, at: to)
            patches.append(
                SourcePatch(
                    rangeUTF16: row.rangeUTF16,
                    expectedText: row.lineText,
                    replacement: Self.rebuildLine(cells: texts)))
        }
        guard !patches.isEmpty else { return nil }
        return MarkdownTablePlan(
            patches: patches, caretAfterUTF16: rows.first?.rangeUTF16.location)
    }

    /// 设置列对齐:仅重建分隔行(其余行不动)。
    func setAlignment(_ column: Int, _ alignment: MarkdownTableAlignment) -> MarkdownTablePlan? {
        guard let delimiter = delimiterIndex,
            rows[delimiter].cells.indices.contains(column)
        else { return nil }
        let delimiterRow = rows[delimiter]
        let markers = delimiterRow.cells.enumerated().map { index, cell -> String in
            let t = cell.text.trimmingCharacters(in: .whitespaces)
            let dashes = String(repeating: "-", count: max(3, t.filter { $0 == "-" }.count))
            guard index == column else { return t.isEmpty ? dashes : t }
            switch alignment {
            case .none: return dashes
            case .left: return ":" + dashes
            case .center: return ":" + dashes + ":"
            case .right: return dashes + ":"
            }
        }
        return MarkdownTablePlan(
            patches: [
                SourcePatch(
                    rangeUTF16: delimiterRow.rangeUTF16,
                    expectedText: delimiterRow.lineText,
                    replacement: Self.rebuildLine(cells: markers))
            ],
            caretAfterUTF16: NSMaxRange(delimiterRow.rangeUTF16))
    }

    // MARK: - 序列化 helper

    /// 行集合覆盖的连续区间(首行起点到最后行 fullRange 末)。
    private func fullBlockRange() -> NSRange? {
        guard let first = rows.first, let last = rows.last else { return nil }
        return NSRange(
            location: first.fullRangeUTF16.location,
            length: NSMaxRange(last.fullRangeUTF16) - first.fullRangeUTF16.location)
    }

    /// 由缓存的行原文 + verbatim 行尾重建块文本(expectedText 用,
    /// 逐字节等于 parse 输入的对应切片)。
    private func reconstructBlockText() -> String {
        rows.map { $0.lineText + $0.lineEnding }.joined()
    }

    /// 由 cell 文本重建 `| a | b |` 形态的行(空 cell = 两空格)。
    static func rebuildLine(cells: [String]) -> String {
        "|" + cells.map { $0.isEmpty ? "  " : " \($0) " }.joined(separator: "|") + "|"
    }
}
