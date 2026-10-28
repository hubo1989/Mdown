import XCTest

@testable import Mdown

/// T16 (SPEC NE-09 / NE-14 / NE-15 / AC-11):MarkdownTableModel 的纯逻辑合同。
///
/// 模型只保存 cell 的 source UTF-16 区间与结构事实;一切修改以
/// SourcePatch 计划表达(应用走 MarkdownPatchApplier,同 base 降序)。
/// 不拆 `code|pipe`(code span 内管道)、不拆 `\|` 转义;行列操作是
/// 原子 patch 组;序列化只发生在 replacement 字符串里。
final class MarkdownTableEditingTests: XCTestCase {

    private let sample = "| a | b |\n| --- | :---: |\n| c | d |\n"

    private func parse(_ source: String) -> MarkdownTableModel {
        let ns = source as NSString
        let range = NSRange(location: 0, length: ns.length)
        return MarkdownTableModel.parse(source: source, blockRange: range)
    }

    // MARK: - 解析

    func testParseTwoColumnTableWithAlignment() {
        let model = parse(sample)
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.alignments, [.none, .center])
        XCTAssertFalse(model.rows[0].isDelimiter)
        XCTAssertTrue(model.rows[1].isDelimiter)
        XCTAssertFalse(model.rows[2].isDelimiter)
        // cell 区间锚在 source 实际字节
        let ns = sample as NSString
        for row in model.rows where !row.isDelimiter {
            for cell in row.cells {
                XCTAssertEqual(ns.substring(with: cell.rangeUTF16), cell.text)
            }
        }
        XCTAssertEqual(model.rows[0].cells.map(\.text), ["a", "b"])
        XCTAssertEqual(model.rows[2].cells.map(\.text), ["c", "d"])
    }

    func testEscapedPipeAndCodeSpanPipeStayInOneCell() {
        let source = "| x \\| y | `a|b` | z |\n| --- | --- | --- |\n"
        let model = parse(source)
        XCTAssertEqual(model.rows[0].cells.count, 3)
        XCTAssertEqual(model.rows[0].cells[0].text, "x \\| y")
        XCTAssertEqual(model.rows[0].cells[1].text, "`a|b`")
        XCTAssertEqual(model.rows[0].cells[2].text, "z")
    }

    func testRowWithoutLeadingOrTrailingPipesParses() {
        let source = "a | b\n--- | ---\nc | d\n"
        let model = parse(source)
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.rows[2].cells.map(\.text), ["c", "d"])
    }

    // MARK: - 单元格编辑

    func testSetCellPlansSinglePatchWithEscaping() throws {
        let model = parse(sample)
        let plan = try XCTUnwrap(model.setCell(row: 2, column: 1, text: "new|value"))
        let ns = sample as NSString
        XCTAssertEqual(plan.patches.count, 1)
        let patch = plan.patches[0]
        XCTAssertEqual(patch.expectedText, "d")
        XCTAssertEqual(ns.substring(with: patch.rangeUTF16), "d")
        XCTAssertEqual(patch.replacement, "new\\|value", "| 必须转义后写入 source")
    }

    func testSetCellOutOfRangeReturnsNil() {
        let model = parse(sample)
        XCTAssertNil(model.setCell(row: 5, column: 0, text: "x"))
        XCTAssertNil(model.setCell(row: 0, column: 9, text: "x"))
    }

    // MARK: - 行操作

    func testInsertRowAfterHeaderLandsAfterDelimiter() throws {
        // GFM 硬约束:分隔行必须紧跟头行——头行后插行自动落到分隔行后。
        // (旧期望把新行插进头行与分隔行之间,破坏表格,已按此修正。)
        let model = parse(sample)
        let plan = try XCTUnwrap(model.insertRow(after: 0, columnCount: 2))
        XCTAssertEqual(plan.patches.count, 1, "整行一次 insert,天然原子")
        let applied = apply(sample, plan.patches)
        let lines = applied.components(separatedBy: "\n")
        XCTAssertEqual(lines[1], "| --- | :---: |", "分隔行仍紧跟头行: \(applied)")
        XCTAssertEqual(lines[2], "|  |  |", "新行落在分隔行后: \(applied)")
    }

    func testInsertRowAfterBodyRowLandsImmediately() throws {
        let model = parse(sample)
        let plan = try XCTUnwrap(model.insertRow(after: 2, columnCount: 2))
        let applied = apply(sample, plan.patches)
        XCTAssertEqual(
            applied.components(separatedBy: "\n")[3], "|  |  |",
            "身体行后插行不动其位置: \(applied)")
    }

    func testAppendRowForEnterInLastCell() throws {
        let model = parse(sample)
        let plan = try XCTUnwrap(model.appendRow(columnCount: 2))
        let applied = apply(sample, plan.patches)
        XCTAssertTrue(applied.hasSuffix("|  |  |\n"), applied)
        XCTAssertNotNil(plan.caretAfterUTF16)
    }

    func testDeleteRowRemovesWholeLine() throws {
        let model = parse(sample)
        let plan = try XCTUnwrap(model.deleteRow(2))  // 删 "| c | d |"
        let applied = apply(sample, plan.patches)
        XCTAssertFalse(applied.contains("| c | d |"), applied)
        XCTAssertTrue(applied.contains("| a | b |"), "头行不受影响")
    }

    // MARK: - 列操作

    func testDeleteColumnTouchesEveryRow() throws {
        let source = "| a | b |\n| --- | --- |\n| c | d |\n"
        let model = parse(source)
        let plan = try XCTUnwrap(model.deleteColumn(1))
        let applied = apply(source, plan.patches)
        XCTAssertEqual(applied, "| a |\n| --- |\n| c |\n")
    }

    func testToggleAlignmentRewritesDelimiterRowOnly() throws {
        let model = parse(sample)
        let plan = try XCTUnwrap(model.setAlignment(1, .right))
        let applied = apply(sample, plan.patches)
        XCTAssertTrue(applied.contains("| --- | ---: |"), applied)
        XCTAssertEqual(applied.components(separatedBy: .newlines).count - 1, 3, "行数不变")
    }

    // MARK: - 往返不变量

    func testNoOpRoundTripKeepsBytesStable() throws {
        // setCell 写回自身文本必须字节稳定(无隐式重排)
        let model = parse(sample)
        let cell = model.rows[2].cells[0]
        let plan = try XCTUnwrap(model.setCell(row: 2, column: 0, text: cell.text))
        let applied = apply(sample, plan.patches)
        XCTAssertEqual(applied, sample)
    }

    // MARK: - helper

    private func apply(_ source: String, _ patches: [SourcePatch]) -> String {
        switch MarkdownPatchApplier.applyPatches(patches, to: source) {
        case .success(let out):
            return out
        case .failure(let reason):
            XCTFail("patch 应用失败: \(reason)")
            return source
        }
    }
}

// MARK: - 模型回归(字节保真 / 转义 / 结构约束 / 行列移动)

extension MarkdownTableEditingTests {

    // MARK: CRLF / 混合行尾 / 无末尾换行

    func testCRLFRowsCarryExactLineEndings() throws {
        let source = "| a | b |\r\n| --- | --- |\r\n| c | d |"  // 无末尾换行
        let model = parse(source)
        XCTAssertEqual(model.rows[0].lineEnding, "\r\n")
        XCTAssertEqual(model.rows[1].lineEnding, "\r\n")
        XCTAssertEqual(model.rows[2].lineEnding, "", "末行无换行必须逐字记为 empty")
        XCTAssertEqual(model.rows[0].lineText, "| a | b |", "lineText 不得含 CR")
        XCTAssertEqual(model.rows[2].lineText, "| c | d |")

        let plan = try XCTUnwrap(model.setCell(row: 2, column: 0, text: "X"))
        XCTAssertEqual(apply(source, plan.patches), "| a | b |\r\n| --- | --- |\r\n| X | d |")
    }

    func testDeleteRowUsesCachedVerbatimEnding() throws {
        // 三身体行 CRLF 表,删中间行:expectedText 用缓存 lineText+lineEnding
        let source = "| a |\r\n| --- |\r\n| b |\r\n| c |\r\n| d |"
        let model = parse(source)
        let plan = try XCTUnwrap(model.deleteRow(3))  // "| c |\r\n"
        let applied = apply(source, plan.patches)
        XCTAssertEqual(applied, "| a |\r\n| --- |\r\n| b |\r\n| d |")
    }

    func testDeleteRowWithoutFinalNewlineRemovesExactSlice() throws {
        let source = "| a | b |\n| --- | --- |\n| c | d |"
        let model = parse(source)
        let plan = try XCTUnwrap(model.deleteRow(2))
        XCTAssertEqual(apply(source, plan.patches), "| a | b |\n| --- | --- |")
    }

    func testInsertRowFollowsTargetLineEnding() throws {
        let source = "| a |\r\n| --- |\r\n| c |\r\n"
        let model = parse(source)
        let plan = try XCTUnwrap(model.insertRow(after: 2, columnCount: 1))
        XCTAssertEqual(
            apply(source, plan.patches), "| a |\r\n| --- |\r\n| c |\r\n|  |\r\n",
            "新行分隔与终止沿用 CRLF 行尾,原行字节不动")
    }

    func testInsertRowAfterNonFinalLineWithoutEndingAddsSeparator() throws {
        // 末行无换行:新行仍须独立成行,且块尾无换行形态保真
        let source = "| a |\n| --- |\n| c |"
        let model = parse(source)
        let plan = try XCTUnwrap(model.insertRow(after: 2, columnCount: 1))
        XCTAssertEqual(apply(source, plan.patches), "| a |\n| --- |\n| c |\n|  |")
    }

    func testMixedLineEndingsKeepUnchangedRowsVerbatim() throws {
        let source = "| a |\r\n| --- |\n| c |"
        let model = parse(source)
        let plan = try XCTUnwrap(model.setCell(row: 2, column: 0, text: "X"))
        let applied = apply(source, plan.patches)
        // 只动目标 cell;两个未改行连同各自行尾逐字节保留
        XCTAssertEqual(applied, "| a |\r\n| --- |\n| X |")
    }

    // MARK: 转义不双转义 / code span / 管道奇偶

    func testSetCellDoesNotDoubleEscape() throws {
        let source = #"| x \| y | b |"# + "\n| --- | --- |\n| c | d |\n"
        let model = parse(source)
        // cell.text 已是 source 形态,原样写回不双转义
        let plan = try XCTUnwrap(model.setCell(row: 2, column: 0, text: #"x \| y"#))
        XCTAssertEqual(
            apply(source, plan.patches),
            "| x \\| y | b |\n| --- | --- |\n| x \\| y | d |\n")

        // 裸管道照常转义
        let plan2 = try XCTUnwrap(model.setCell(row: 2, column: 0, text: "a|b"))
        XCTAssertEqual(
            apply(source, plan2.patches),
            "| x \\| y | b |\n| --- | --- |\n| a\\|b | d |\n")
    }

    func testBackslashRunParityDecidesEscapedPipe() {
        // 偶数反斜杠 + 管道 = 未转义管道,拆格;奇数 = 转义,不拆。
        let even = #"| a \\| b |"# + "\n| --- | --- |\n"  // 字面反斜杠 + 未转义 |
        let modelEven = parse(even)
        XCTAssertEqual(modelEven.rows[0].cells.map(\.text), [#"a \\"#, "b"])

        let odd = #"| a \\\| b |"# + "\n| --- | --- |\n"  // 字面反斜杠 + 转义 |
        let modelOdd = parse(odd)
        XCTAssertEqual(modelOdd.rows[0].cells.count, 1)
        XCTAssertEqual(modelOdd.rows[0].cells[0].text, #"a \\\| b"#)
    }

    func testMultiBacktickSpanKeepsPipesAndInnerBackticks() {
        let source = #"| ``a`b`` | `c|d` |"# + "\n| --- | --- |\n"
        let model = parse(source)
        XCTAssertEqual(model.rows[0].cells.map(\.text), ["``a`b``", "`c|d`"])

        // 管道落在双反引号 span 内不拆
        let spanPipe = #"| ``a|b`` | x |"# + "\n| --- | --- |\n"
        XCTAssertEqual(parse(spanPipe).rows[0].cells.map(\.text), ["``a|b``", "x"])
    }

    // MARK: 无效输入 / 结构约束

    func testInvalidBlockRangeReturnsEmptyModel() {
        let source = "| a |\n| --- |\n"
        let ns = source as NSString
        XCTAssertTrue(parseNs(source, NSRange(location: 0, length: ns.length + 10)).rows.isEmpty)
        XCTAssertTrue(parseNs(source, NSRange(location: ns.length + 1, length: 2)).rows.isEmpty)
        XCTAssertTrue(parseNs(source, NSRange(location: 0, length: -1)).rows.isEmpty)
        // 有效范围照常解析(对照)
        XCTAssertEqual(parseNs(source, NSRange(location: 0, length: ns.length)).rows.count, 2)
    }

    func testDeleteColumnRefusesSingleColumnTable() throws {
        let source = "| a |\n| --- |\n| c |\n"
        let model = parse(source)
        XCTAssertNil(model.deleteColumn(0), "单列表格删尽唯一列即破坏结构")
        let plan = try XCTUnwrap(model.insertColumn(before: 1))
        XCTAssertEqual(apply(source, plan.patches), "| a |  |\n| --- | --- |\n| c |  |\n")
    }

    func testHeaderAndDelimiterRowsAreProtectedFromDelete() {
        let model = parse(sample)
        XCTAssertNil(model.deleteRow(0), "头行不可删")
        XCTAssertNil(model.deleteRow(1), "分隔行不可删")
        XCTAssertNotNil(model.deleteRow(2), "身体行可删")
        // 退化输入(首行即分隔行):无头行,身体行仍可删
        let degenerate = parse("| --- |\n| c |")
        XCTAssertNotNil(degenerate.deleteRow(1))
    }

    // MARK: 行列移动

    func testMoveRowReordersBodyKeepingHeaderAndDelimiter() throws {
        let source = "| a |\n| --- |\n| b |\n| c |\n| d |\n"
        let model = parse(source)
        // from/to 为行下标;from 行落到 to 行原先的身体槽位,to 与其余
        // 身体行相对次序不变(被挤开)。
        let plan = try XCTUnwrap(model.moveRow(from: 2, to: 3))
        XCTAssertEqual(apply(source, plan.patches), "| a |\n| --- |\n| c |\n| b |\n| d |\n")

        XCTAssertNil(model.moveRow(from: 2, to: 2), "同位置 no-op")
        XCTAssertNil(model.moveRow(from: 0, to: 3), "头行不可移动")
        XCTAssertNil(model.moveRow(from: 1, to: 3), "分隔行不可移动")
        XCTAssertNotNil(model.moveRow(from: 3, to: 2), "反向移动")
    }

    func testMoveRowPreservesNoFinalNewlineShape() throws {
        let source = "| a |\n| --- |\n| b |\n| c |"  // 无末尾换行
        let model = parse(source)
        let plan = try XCTUnwrap(model.moveRow(from: 2, to: 3))
        XCTAssertEqual(apply(source, plan.patches), "| a |\n| --- |\n| c |\n| b |")
    }

    func testMoveRowOnCRLFTablePreservesCRLF() throws {
        let source = "| a |\r\n| --- |\r\n| b |\r\n| c |\r\n"
        let model = parse(source)
        let plan = try XCTUnwrap(model.moveRow(from: 2, to: 3))
        XCTAssertEqual(apply(source, plan.patches), "| a |\r\n| --- |\r\n| c |\r\n| b |\r\n")
    }

    func testMoveColumnMovesCellsAndAlignmentMarkers() throws {
        let source = "| a | b |\n| --- | :---: |\n| c | d |\n"
        let model = parse(source)
        let plan = try XCTUnwrap(model.moveColumn(from: 0, to: 1))
        XCTAssertEqual(
            apply(source, plan.patches),
            "| b | a |\n| :---: | --- |\n| d | c |\n",
            "cell 与分隔行 marker 随列移动,对齐语义保留")

        XCTAssertNil(model.moveColumn(from: 0, to: 0))
        XCTAssertNil(model.moveColumn(from: 0, to: 9))
    }

    // MARK: stable IDs(快照内)

    func testRowAndColumnIDsStableWithinSnapshot() {
        let model = parse(sample)
        XCTAssertEqual(Set(model.rows.map(\.id)).count, model.rows.count, "行 ID 唯一")
        XCTAssertEqual(model.columnIDs.count, model.columnCount)
        XCTAssertEqual(Set(model.columnIDs).count, model.columnIDs.count, "列 ID 唯一")
        for (index, row) in model.rows.enumerated() {
            XCTAssertEqual(model.rowIndex(of: row.id), index, "ID → 下标可逆")
        }
    }

    // MARK: helper

    private func parseNs(_ source: String, _ range: NSRange) -> MarkdownTableModel {
        MarkdownTableModel.parse(source: source, blockRange: range)
    }
}

// MARK: - rich 面表格交互(T16 part 2;G0 定单 TextKit 投影)

extension MarkdownTableEditingTests {

    private var tableSource: String { "| a | bb |\n| --- | --- |\n| c | d |\n" }

    @MainActor
    private func makeTable() -> RichMarkdownTextView {
        RichMarkdownTextView(source: tableSource)
    }

    /// source 偏移 → display caret 位(ND-04 网格投影下表格 display≠source;
    /// 行为语义按 source 意图断言,坐标一律换算)。
    @MainActor
    private func caretDisplay(_ view: RichMarkdownTextView, sourceAt offset: Int) -> Int {
        view.displayRange(forSourceRange: NSRange(location: offset, length: 0))?.location
            ?? offset
    }

    /// 表格块内字面 → display caret 位。
    @MainActor
    private func caretDisplay(afterLiteral literal: String, in view: RichMarkdownTextView) -> Int {
        let ns = view.source as NSString
        let r = ns.range(of: literal)
        return caretDisplay(view, sourceAt: r.location + r.length)
    }

    @MainActor
    func testTabMovesCaretBetweenCells() {
        let view = makeTable()
        // caret 在 "a" 后(经投影换算 display 位)
        let aStart = caretDisplay(
            view, sourceAt: (view.source as NSString).range(of: "a").location)
        view.setSelectedRange(NSRange(location: aStart, length: 0))
        XCTAssertTrue(view.text(NSTextView(), doCommandBy: #selector(NSText.insertTab(_:))))
        XCTAssertEqual(
            view.selectedRange().location,
            caretDisplay(view, sourceAt: (view.source as NSString).range(of: "bb").location),
            "Tab 应跳到第二格 \"bb\" 起点")

        XCTAssertTrue(view.text(NSTextView(), doCommandBy: #selector(NSText.insertBacktab(_:))))
        XCTAssertEqual(view.selectedRange().location, aStart, "Shift+Tab 应回到 \"a\" 格起点")
    }

    @MainActor
    func testEnterInLastCellAppendsRowAsUndoableTransaction() {
        let view = makeTable()
        view.setSelectedRange(
            NSRange(location: caretDisplay(afterLiteral: "d", in: view), length: 0))  // "d" 后
        let revisionBefore = view.revision
        XCTAssertTrue(view.text(NSTextView(), doCommandBy: #selector(NSText.insertNewline(_:))))
        XCTAssertEqual(view.revision, revisionBefore + 1, "加行是一次结构事务")
        XCTAssertTrue(view.source.hasSuffix("|  |  |\n"), view.source)
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, tableSource, "单步 undo 回到原表")
    }

    @MainActor
    func testEnterInNonLastRowJumpsToCellBelow() {
        let view = makeTable()
        view.setSelectedRange(
            NSRange(location: caretDisplay(afterLiteral: "a", in: view), length: 0))  // "a" 后
        XCTAssertTrue(view.text(NSTextView(), doCommandBy: #selector(NSText.insertNewline(_:))))
        XCTAssertEqual(
            view.selectedRange().location,
            caretDisplay(view, sourceAt: (view.source as NSString).range(of: "c").location),
            "Enter 应跳到正下方 \"c\" 起点")
        XCTAssertEqual(view.source, tableSource, "非末行 Enter 不改正文")
    }

    @MainActor
    func testBacktabFromThirdDataRowFirstCellLandsOnAdjacentRow() {
        // editableRows = [0, 2, 3, 4](头行 + 3 数据行):第 3 数据行首格
        // Shift+Tab 必须落紧邻上一行(row 3)末格 "f";旧行为取
        // first(< r) 会直接跳到头行末格 "b",跳过 row 2/row 3。
        let view = RichMarkdownTextView(
            source: "| a | b |\n| --- | --- |\n| c | d |\n| e | f |\n| g | h |\n")
        let ns = view.source as NSString
        view.setSelectedRange(
            NSRange(location: caretDisplay(view, sourceAt: ns.range(of: "g").location), length: 0))
        XCTAssertTrue(
            view.text(NSTextView(), doCommandBy: #selector(NSText.insertBacktab(_:))))
        XCTAssertEqual(
            view.selectedRange().location,
            caretDisplay(view, sourceAt: ns.range(of: "f").location),
            "Shift+Tab 自第 3 数据行首格应落第 2 数据行末格 \"f\",不得跳回头行")
        // 正向不变:行末格 Tab 跨行落下一行首格
        XCTAssertTrue(view.text(NSTextView(), doCommandBy: #selector(NSText.insertTab(_:))))
        XCTAssertEqual(
            view.selectedRange().location,
            caretDisplay(view, sourceAt: ns.range(of: "g").location),
            "Tab 正向跨行仍落下一行首格")
    }

    @MainActor
    func testTabOutsideTableFallsBackToStructuralHandling() {
        let view = RichMarkdownTextView(source: "- item\n")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        // list 内 Tab 走既有缩进路径;返回值真假不重要,关键是 source 变为缩进
        _ = view.text(NSTextView(), doCommandBy: #selector(NSText.insertTab(_:)))
        XCTAssertTrue(view.source.hasPrefix("  - item"), "list 缩进不受表格分支影响")
    }
}

// MARK: - T16 行列命令(view 层;caret 驱动,右键菜单入口)

extension MarkdownTableEditingTests {

    @MainActor
    private func makeTableView() -> RichMarkdownTextView {
        RichMarkdownTextView(source: "| a | b |\n| --- | --- |\n| c | d |\n| e | f |\n")
    }

    @MainActor
    func testInsertAndDeleteRowCommandsAtCaret() {
        let view = makeTableView()
        // caret 在 body 首行 "c" 内(经投影换算)
        let ns = view.source as NSString
        view.setSelectedRange(
            NSRange(
                location: caretDisplay(view, sourceAt: ns.range(of: "c").location + 1), length: 0))
        XCTAssertTrue(view.insertTableRowBelowAtCaret())
        XCTAssertEqual(
            view.source, "| a | b |\n| --- | --- |\n| c | d |\n|  |  |\n| e | f |\n")
        XCTAssertTrue(view.performUndo(), "插入行单步撤销")

        XCTAssertTrue(view.deleteTableRowAtCaret())
        XCTAssertEqual(view.source, "| a | b |\n| --- | --- |\n| e | f |\n")
        XCTAssertTrue(view.performUndo(), "删行单步撤销")
    }

    @MainActor
    func testInsertRowBelowMovesCaretToNewRowFirstCell() {
        let view = makeTableView()
        let ns = view.source as NSString
        let cEnd = caretDisplay(view, sourceAt: ns.range(of: "c").location + 1)
        view.setSelectedRange(NSRange(location: cEnd, length: 0))
        XCTAssertTrue(view.insertTableRowBelowAtCaret())
        // caret 必须落新行首格内容起点(经投影换算);旧行为恢复 pre-edit 偏移留在旧行。
        let newStart = (view.source as NSString).range(of: "|  |  |").location + 2
        XCTAssertEqual(
            view.selectedRange().location,
            caretDisplay(view, sourceAt: newStart),
            "Add Row Below 后 caret 必须落新行首格,而非停留旧行")
    }

    @MainActor
    func testDeleteRowRestoresCaretAtPlanSurvivingPosition() {
        // 长 body 行删除构造偏移位移:pre-edit caret(37)在新文本中越过
        // 表格末尾;plan 的存活位 = 被删行原起点(24,现 "| e | f |" 行首)。
        let view = RichMarkdownTextView(
            source: "| a | b |\n| --- | --- |\n| ccccccc | d |\n| e | f |\n")
        let ns = view.source as NSString
        view.setSelectedRange(
            NSRange(
                location: caretDisplay(view, sourceAt: ns.range(of: "d").location + 1), length: 0))
        XCTAssertTrue(view.deleteTableRowAtCaret())
        XCTAssertEqual(view.source, "| a | b |\n| --- | --- |\n| e | f |\n")
        // plan 存活位 = 被删行原起点(现 "| e | f |" 行首),经新投影换算。
        let survivor = (view.source as NSString).range(of: "| e | f |").location
        XCTAssertEqual(
            view.selectedRange().location,
            caretDisplay(view, sourceAt: survivor),
            "删行后 caret 落 plan 的安全存活位(被删行原起点),不得沿用位移后错位的旧偏移")
    }

    @MainActor
    func testTypingPipeInsideCellEscapesAndKeepsColumns() {
        let view = makeTableView()
        let ns = view.source as NSString
        // caret 在 body 首格 "c" 内(经投影换算)
        view.setSelectedRange(
            NSRange(
                location: caretDisplay(view, sourceAt: ns.range(of: "c").location + 1), length: 0))
        view.insertText("x|y")
        XCTAssertTrue(view.source.contains("| cx\\|y |"), "管道转义写入: \(view.source)")
        // 列数不塌:表仍为两列结构
        XCTAssertTrue(view.source.contains("| a | b |"))
        XCTAssertTrue(view.source.hasSuffix("| e | f |\n"))
    }

    @MainActor
    func testCrossCellSelectionReplacementIsRejected() {
        let view = makeTableView()
        let ns = view.source as NSString
        // 选中 "c | d"(跨 cell 边界)后键入 X:必须拒绝,source 不动
        let start = ns.range(of: "c").location
        let end = ns.range(of: "d").location + 1
        view.setSelectedRange(NSRange(location: start, length: end - start))
        view.insertText("X")
        XCTAssertEqual(
            view.source,
            "| a | b |\n| --- | --- |\n| c | d |\n| e | f |\n",
            "跨 cell 替换不得吞管道拆表")
        XCTAssertNotNil(view.lastSyncRejection, "拒绝应留下观察口记录")
    }

    @MainActor
    func testPipeEscapeParity() {
        XCTAssertEqual(RichMarkdownTextView.escapingUnescapedPipes("a|b"), "a\\|b")
        XCTAssertEqual(RichMarkdownTextView.escapingUnescapedPipes("a\\|b"), "a\\|b", "已转义不双转义")
        XCTAssertEqual(RichMarkdownTextView.escapingUnescapedPipes("a\\\\|b"), "a\\\\\\|b", "\\\\ 后管道仍需转义")
    }

    @MainActor
    func testInsertAndDeleteColumnCommandsAtCaret() {
        let view = makeTableView()
        let ns = view.source as NSString
        view.setSelectedRange(
            NSRange(
                location: caretDisplay(view, sourceAt: ns.range(of: "d").location + 1), length: 0))
        XCTAssertTrue(view.insertTableColumnAtCaret())
        XCTAssertEqual(
            view.source, "| a |  | b |\n| --- | --- | --- |\n| c |  | d |\n| e |  | f |\n",
            "新空列插在 caret 列前(原列右移)")
        XCTAssertTrue(view.performUndo())

        view.setSelectedRange(
            NSRange(
                location: caretDisplay(view, sourceAt: ns.range(of: "f").location + 1), length: 0))
        XCTAssertTrue(view.deleteTableColumnAtCaret())
        XCTAssertEqual(view.source, "| a |\n| --- |\n| c |\n| e |\n")
        XCTAssertTrue(view.performUndo())
    }

    @MainActor
    func testMoveRowCommandsMoveBodyRowsOnly() {
        let view = makeTableView()
        let ns = view.source as NSString
        // caret 在末行 "e" 内:上移一行
        view.setSelectedRange(
            NSRange(
                location: caretDisplay(view, sourceAt: ns.range(of: "e").location + 1), length: 0))
        XCTAssertTrue(view.moveTableRowUpAtCaret())
        XCTAssertEqual(
            view.source, "| a | b |\n| --- | --- |\n| e | f |\n| c | d |\n")
        XCTAssertTrue(view.performUndo())

        // 头行上移必须拒绝(护头/分隔行)
        view.setSelectedRange(
            NSRange(
                location: caretDisplay(view, sourceAt: ns.range(of: "a").location + 1), length: 0))
        XCTAssertFalse(view.moveTableRowUpAtCaret())
        XCTAssertEqual(view.source, "| a | b |\n| --- | --- |\n| c | d |\n| e | f |\n")
    }

    @MainActor
    func testMoveColumnCommandSwapsDataAndAlignment() {
        let view = RichMarkdownTextView(source: "| a | b |\n| :- | -: |\n| c | d |\n")
        let ns = view.source as NSString
        view.setSelectedRange(
            NSRange(
                location: caretDisplay(view, sourceAt: ns.range(of: "a").location + 1), length: 0))
        XCTAssertTrue(view.moveTableColumnRightAtCaret())
        XCTAssertEqual(view.source, "| b | a |\n| -: | :- |\n| d | c |\n", "数据与对齐随列移动")
        XCTAssertTrue(view.performUndo())
    }

    @MainActor
    func testSetAlignmentCommandRewritesDelimiter() {
        let view = makeTableView()
        let ns = view.source as NSString
        view.setSelectedRange(
            NSRange(
                location: caretDisplay(view, sourceAt: ns.range(of: "b").location + 1), length: 0))
        XCTAssertTrue(view.setTableAlignmentAtCaret(.center))
        XCTAssertEqual(
            view.source,
            "| a | b |\n| --- | :---: |\n| c | d |\n| e | f |\n",
            "仅分隔行对齐变化")
        XCTAssertTrue(view.performUndo())
    }

    @MainActor
    func testTableCommandsFailOutsideTable() {
        let view = RichMarkdownTextView(source: "plain text\n")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertFalse(view.insertTableRowBelowAtCaret())
        XCTAssertFalse(view.deleteTableRowAtCaret())
        XCTAssertFalse(view.insertTableColumnAtCaret())
        XCTAssertFalse(view.deleteTableColumnAtCaret())
        XCTAssertFalse(view.moveTableRowUpAtCaret())
        XCTAssertFalse(view.moveTableColumnLeftAtCaret())
        XCTAssertFalse(view.setTableAlignmentAtCaret(.left))
        XCTAssertEqual(view.source, "plain text\n")
    }
}
