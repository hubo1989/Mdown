import XCTest

@testable import MiaoYan

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

    func testInsertRowAddsEmptyRowAfterTarget() throws {
        let model = parse(sample)
        let plan = try XCTUnwrap(model.insertRow(after: 0, columnCount: 2))
        XCTAssertEqual(plan.patches.count, 1, "整行一次 insert,天然原子")
        let applied = apply(sample, plan.patches)
        let lines = applied.components(separatedBy: "\n")
        XCTAssertEqual(lines[1], "|  |  |", "头行后插入空行: \(applied)")
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
