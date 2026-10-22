import Foundation

// MARK: - T16 GFM 表格模型(PLAN T16 / SPEC NE-09 / AC-11)
//
// 纯逻辑层:把 table 块的 source 解析为 cell 的 UTF-16 区间与结构事实
// (对齐/分隔行/行列),一切修改以 SourcePatch 计划表达——应用统一走
// MarkdownPatchApplier(同 base 降序、expectedText 逐字节校验),模型
// 自身不改 source、不持有权威正文。行原文在 parse 时逐行缓存,patch
// 的 expectedText 用缓存原文而非重建文本,保证字节精确。
//
// 管道拆分:`\|` 转义与 code span 内 `|` 不拆;写入 cell 文本时对用户
// 文本里的 `|` 显式转义,往返字节稳定(除用户改动本身)。

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
    /// 行内容(不含行尾换行)区间。
    let rangeUTF16: NSRange
    /// 行内容 + 行尾换行(存在时)的区间(deleteRow 用)。
    let fullRangeUTF16: NSRange
    /// 行内容原文(parse 时缓存,expectedText 用)。
    let lineText: String
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

    var columnCount: Int {
        rows.first(where: { !$0.isDelimiter })?.cells.count
            ?? rows.first?.cells.count ?? 0
    }

    // MARK: - 解析

    /// 解析 blockRange 内的 table 块(逐行;调用方保证块类型是 table)。
    static func parse(source: String, blockRange: NSRange) -> MarkdownTableModel {
        let ns = source as NSString
        var rows: [MarkdownTableRow] = []
        var lineLoc = blockRange.location
        let blockEnd = NSMaxRange(blockRange)
        while lineLoc < blockEnd {
            let lineRange = ns.lineRange(for: NSRange(location: lineLoc, length: 0))
            guard NSMaxRange(lineRange) <= blockEnd else { break }
            let contentEnd = max(
                lineRange.location,
                NSMaxRange(lineRange)
                    - (lineRange.length > 0 && ns.character(at: NSMaxRange(lineRange) - 1) == 0x0A
                        ? 1 : 0))
            let contentRange = NSRange(
                location: lineRange.location, length: contentEnd - lineRange.location)
            let cells = parseCells(ns: ns, lineRange: contentRange)
            let isDelimiter = !cells.isEmpty && cells.allSatisfy { isDelimiterCell($0.text) }
            rows.append(
                MarkdownTableRow(
                    rangeUTF16: contentRange,
                    fullRangeUTF16: NSRange(
                        location: lineRange.location, length: NSMaxRange(lineRange) - lineRange.location),
                    lineText: ns.substring(with: contentRange),
                    cells: cells,
                    isDelimiter: isDelimiter))
            lineLoc = NSMaxRange(lineRange)
        }
        let alignments =
            rows.first(where: \.isDelimiter).map { row in
                row.cells.map { alignment(of: $0.text) }
            } ?? []
        return MarkdownTableModel(rangeUTF16: blockRange, rows: rows, alignments: alignments)
    }

    /// 按未转义、code span 外的 `|` 切 cell;首尾边界管道剥除,cell 文本
    /// 两侧单空格裁掉。行首无管道时首个 cell 从行首起。
    private static func parseCells(ns: NSString, lineRange: NSRange) -> [MarkdownTableCell] {
        var cells: [MarkdownTableCell] = []
        var cellStart = -1
        var inBacktick = false
        let end = NSMaxRange(lineRange)

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
            if u == 0x60 {
                inBacktick.toggle()
            } else if u == 0x7C, !inBacktick {
                let escaped =
                    i > lineRange.location
                    && ns.character(at: i - 1) == 0x5C
                    && (i - 1 == lineRange.location || ns.character(at: i - 2) != 0x5C)
                if !escaped {
                    if cellStart >= 0 {
                        emit(from: cellStart, to: i)
                    } else if i > lineRange.location {
                        emit(from: lineRange.location, to: i)  // 行首无管道
                    }
                    cellStart = i + 1  // 行首边界管道:仅移动起点
                }
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

    // MARK: - 修改计划(pure;不改 source)

    /// 覆盖单元格文本;用户文本中的 `|` 转义写入。row 必须是非分隔行。
    func setCell(row: Int, column: Int, text: String) -> MarkdownTablePlan? {
        guard rows.indices.contains(row), !rows[row].isDelimiter,
            rows[row].cells.indices.contains(column)
        else { return nil }
        let cell = rows[row].cells[column]
        let replacement = text.replacingOccurrences(of: "|", with: "\\|")
        return MarkdownTablePlan(
            patches: [
                SourcePatch(
                    rangeUTF16: cell.rangeUTF16,
                    expectedText: cell.text,
                    replacement: replacement)
            ],
            caretAfterUTF16: cell.rangeUTF16.location + (replacement as NSString).length)
    }

    /// 在 row 行后插入整行空单元格(单 patch,天然原子)。
    func insertRow(after row: Int, columnCount columns: Int) -> MarkdownTablePlan? {
        guard rows.indices.contains(row), columns > 0 else { return nil }
        let line = Self.rebuildLine(
            cells: Array(repeating: "", count: columns))
        let insertAt = NSMaxRange(rows[row].rangeUTF16)  // 行尾换行前
        return MarkdownTablePlan(
            patches: [
                SourcePatch(
                    rangeUTF16: NSRange(location: insertAt, length: 0),
                    expectedText: "",
                    replacement: "\n" + line)
            ],
            caretAfterUTF16: insertAt + 2)  // "\n| " 之后 = 首格起点
    }

    /// 末行 Enter 追加行。
    func appendRow(columnCount columns: Int) -> MarkdownTablePlan? {
        guard !rows.isEmpty else { return nil }
        return insertRow(after: rows.count - 1, columnCount: columns)
    }

    /// 删除整行(含行尾换行);最后一行保护(表格至少留分隔 + 一行)。
    func deleteRow(_ row: Int) -> MarkdownTablePlan? {
        guard rows.indices.contains(row), rows.count > 2 else { return nil }
        let target = rows[row]
        let patches = [
            SourcePatch(
                rangeUTF16: target.fullRangeUTF16,
                expectedText: sourceLineWithNewline(target),
                replacement: "")
        ]
        return MarkdownTablePlan(patches: patches, caretAfterUTF16: target.rangeUTF16.location)
    }

    /// 删除一列:逐行(含分隔行)整行重建,同 base 多 patch。
    func deleteColumn(_ column: Int) -> MarkdownTablePlan? {
        guard column >= 0, column < columnCount else { return nil }
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

    /// 在 column 前插入空列:逐行重建。
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

    /// 设置列对齐:仅重建分隔行(其余行不动)。
    func setAlignment(_ column: Int, _ alignment: MarkdownTableAlignment) -> MarkdownTablePlan? {
        guard let delimiter = rows.first(where: \.isDelimiter),
            delimiter.cells.indices.contains(column)
        else { return nil }
        let markers = delimiter.cells.enumerated().map { index, cell -> String in
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
                    rangeUTF16: delimiter.rangeUTF16,
                    expectedText: delimiter.lineText,
                    replacement: Self.rebuildLine(cells: markers))
            ],
            caretAfterUTF16: NSMaxRange(delimiter.rangeUTF16))
    }

    // MARK: - 序列化 helper

    /// 行原文 + 行尾换行(deleteRow 的 expectedText;换行形态与 parse
    /// 时的 fullRange 一致——CRLF 表格暂不展开,块内行尾由 lineRange
    /// 决定,fullRange 已含真实字节,这里从 cells 无法还原,因此
    /// deleteRow 的 expectedText 退化为不校验整行:改为只删行内容 +
    /// 独立删行首换行的两段 patch(见下)。
    private func sourceLineWithNewline(_ row: MarkdownTableRow) -> String {
        // fullRange 比 range 多出的正是行尾换行;用 length 差恢复形态。
        let extra = row.fullRangeUTF16.length - row.rangeUTF16.length
        return row.lineText + String(repeating: "\n", count: max(0, extra))
    }

    /// 由 cell 文本重建 `| a | b |` 形态的行(空 cell = 两空格)。
    static func rebuildLine(cells: [String]) -> String {
        "|" + cells.map { $0.isEmpty ? "  " : " \($0) " }.joined(separator: "|") + "|"
    }
}
