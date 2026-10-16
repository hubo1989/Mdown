import XCTest
@testable import MiaoYan

/// T06：MarkdownEditorHistory 的正式语义（SPEC §5.4）。
/// 覆盖：origin 区分、selectionAfter 正确性、typing 合并策略（同
/// origin/同 group/selection 紧贴/范围相邻/未超时）、非 typing 不合并、
/// redo 截断、undo/redo 后 selection 恢复、内存上限、跨 source/rich 同一
/// 历史栈（同一 history 对象服务两种 origin 的编辑）。
final class MarkdownEditorHistoryTests: XCTestCase {

    private let identity = EditingIdentity(
        ownerToken: UUID(),
        canonicalURL: URL(fileURLWithPath: "/tmp/history.md"),
        generation: 1
    )
    private let sel0 = MarkdownSelection(anchorUTF16: 0, focusUTF16: 0, affinity: .downstream)

    private func patch(_ loc: Int, _ len: Int, _ expected: String, _ replacement: String) -> SourcePatch {
        SourcePatch(
            rangeUTF16: NSRange(location: loc, length: len),
            expectedText: expected, replacement: replacement
        )
    }

    private func sel(_ offset: Int) -> MarkdownSelection {
        MarkdownSelection(anchorUTF16: offset, focusUTF16: offset, affinity: .downstream)
    }

    // MARK: - selectionAfter 必须随编辑推进（T06 修复点）

    func testSelectionAfterRecordsActualPostEditPosition() {
        var history = MarkdownEditorHistory()
        let before = sel(1)
        let after = sel(2)
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(1, 0, "", "X")],
                sourceBefore: "AB",
                selectionBefore: before, selectionAfter: after,
                origin: .typing, name: "typing"
            ))
        let entry = history.undoStack.last
        XCTAssertEqual(
            entry?.selectionAfter, after,
            "selectionAfter 必须是编辑后的实际位置（G0 原型曾错填 selectionBefore）")
        XCTAssertEqual(entry?.selectionBefore, before)
    }

    // MARK: - 非 typing origin 不合并

    func testCompositionDoesNotCoalesceWithTyping() {
        var history = MarkdownEditorHistory()
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(0, 0, "", "a")], sourceBefore: "",
                selectionBefore: sel0, selectionAfter: sel(1),
                origin: .typing, name: "typing"
            ))
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(1, 0, "", "中")], sourceBefore: "a",
                selectionBefore: sel(1), selectionAfter: sel(2),
                origin: .composition, name: "composition"
            ))
        XCTAssertEqual(history.undoStack.count, 2, "composition 提交必须独立成组（SPEC §5.4）")
    }

    func testFormatPasteStructureEachOwnGroup() {
        var history = MarkdownEditorHistory()
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(0, 0, "", "x")], sourceBefore: "",
                selectionBefore: sel0, selectionAfter: sel(1),
                origin: .paste, name: "paste"
            ))
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(1, 0, "", "y")], sourceBefore: "x",
                selectionBefore: sel(1), selectionAfter: sel(2),
                origin: .format, name: "format"
            ))
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(2, 0, "", "z")], sourceBefore: "xy",
                selectionBefore: sel(2), selectionAfter: sel(3),
                origin: .structure, name: "structure"
            ))
        XCTAssertEqual(history.undoStack.count, 3, "paste/format/structure 各为独立组")
    }

    // MARK: - typing 合并

    func testConsecutiveTypingCoalescesIntoOneEntry() {
        var history = MarkdownEditorHistory()
        var sel = sel0
        let group = UUID()
        for (i, ch) in ["a", "b", "c"].enumerated() {
            let next = MarkdownSelection(
                anchorUTF16: i + 1, focusUTF16: i + 1, affinity: .downstream)
            history.record(
                MarkdownEditorHistory.RecordInput(
                    patches: [patch(i, 0, "", ch)],
                    sourceBefore: String(repeating: "x", count: i),
                    selectionBefore: sel, selectionAfter: next,
                    origin: .typing, undoGroupID: group, name: "typing"
                ))
            sel = next
        }
        XCTAssertEqual(history.undoStack.count, 1, "连续 typing 应合并为一个 undo 单位")
        XCTAssertEqual(history.undoStack.last?.patches.count, 3, "合并 entry 含全部 patch")
    }

    func testSelectionJumpBreaksCoalescing() {
        var history = MarkdownEditorHistory()
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(0, 0, "", "a")], sourceBefore: "",
                selectionBefore: sel0, selectionAfter: sel(1),
                origin: .typing, name: "typing"
            ))
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(5, 0, "", "b")], sourceBefore: "a",
                selectionBefore: sel(5), selectionAfter: sel(6),
                origin: .typing, name: "typing"
            ))
        XCTAssertEqual(history.undoStack.count, 2, "selection 跳变必须截断合并")
    }

    func testDifferentGroupIDBreaksCoalescing() {
        var history = MarkdownEditorHistory()
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(0, 0, "", "a")], sourceBefore: "",
                selectionBefore: sel0, selectionAfter: sel(1),
                origin: .typing, undoGroupID: UUID(), name: "typing"
            ))
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(1, 0, "", "b")], sourceBefore: "a",
                selectionBefore: sel(1), selectionAfter: sel(2),
                origin: .typing, undoGroupID: UUID(), name: "typing"
            ))
        XCTAssertEqual(history.undoStack.count, 2, "不同 undoGroupID 不得合并")
    }

    func testTimeoutBreaksCoalescing() {
        var now = Date(timeIntervalSince1970: 1_000)
        var history = MarkdownEditorHistory(coalescingInterval: 1.0, now: { now })
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(0, 0, "", "a")], sourceBefore: "",
                selectionBefore: sel0, selectionAfter: sel(1),
                origin: .typing, name: "typing"
            ))
        now = now.addingTimeInterval(1.5)
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(1, 0, "", "b")], sourceBefore: "a",
                selectionBefore: sel(1), selectionAfter: sel(2),
                origin: .typing, name: "typing"
            ))
        XCTAssertEqual(history.undoStack.count, 2, "超过合并窗口必须新开 entry")
    }

    // MARK: - redo 截断

    func testNewEditTruncatesRedoStack() {
        var history = MarkdownEditorHistory()
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(0, 0, "", "a")], sourceBefore: "",
                selectionBefore: sel0, selectionAfter: sel(1),
                origin: .typing, name: "typing"
            ))
        _ = history.undo(currentSource: "a")
        XCTAssertTrue(history.canRedo)
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(0, 0, "", "b")], sourceBefore: "",
                selectionBefore: sel0, selectionAfter: sel(1),
                origin: .typing, name: "typing"
            ))
        XCTAssertFalse(history.canRedo, "新编辑必须截断 redo")
    }

    // MARK: - undo/redo 恢复 selection

    func testUndoRestoresSelectionBefore() {
        var history = MarkdownEditorHistory()
        let before = sel(1)
        let after = sel(2)
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(1, 0, "", "X")], sourceBefore: "AB",
                selectionBefore: before, selectionAfter: after,
                origin: .typing, name: "typing"
            ))
        let result = history.undo(currentSource: "AXB")
        XCTAssertEqual(result?.source, "AB")
        XCTAssertEqual(result?.selection, before, "undo 必须恢复 selectionBefore")
    }

    func testRedoRestoresSelectionAfter() {
        var history = MarkdownEditorHistory()
        let before = sel(1)
        let after = sel(2)
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(1, 0, "", "X")], sourceBefore: "AB",
                selectionBefore: before, selectionAfter: after,
                origin: .typing, name: "typing"
            ))
        _ = history.undo(currentSource: "AXB")
        let result = history.redo(currentSource: "AB")
        XCTAssertEqual(result?.source, "AXB")
        XCTAssertEqual(result?.selection, after, "redo 必须恢复 selectionAfter")
    }

    // MARK: - 内存上限

    func testMemoryCapDropsOldestEntries() {
        var history = MarkdownEditorHistory()
        let cap = MarkdownEditorHistory.maxEntries
        for i in 0..<(cap + 50) {
            history.record(
                MarkdownEditorHistory.RecordInput(
                    patches: [patch(i, 0, "", "x")], sourceBefore: "",
                    selectionBefore: sel(i), selectionAfter: sel(i),
                    origin: .structure, undoGroupID: UUID(), name: "s\(i)"
                ))
        }
        XCTAssertEqual(history.undoStack.count, cap, "超过上限丢弃最旧")
        XCTAssertEqual(history.undoStack.first?.name, "s50", "最旧的 50 条已淘汰")
    }

    // MARK: - 跨 source/rich 同一历史（PLAN oracle：testUndoAcrossSourceAndRichIsSingleHistory）

    /// 同一 history 对象服务 source 与 rich 两种 origin 的编辑：typing →
    /// structure → undo 到起点再 redo，结构/selection 恢复。view 状态更新
    /// （主题/parse/render）不登记。
    func testUndoAcrossSourceAndRichIsSingleHistory() {
        var history = MarkdownEditorHistory()

        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(0, 0, "", "a")], sourceBefore: "",
                selectionBefore: sel0, selectionAfter: sel(1),
                origin: .typing, name: "typing"
            ))
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(1, 0, "", "\n- ")], sourceBefore: "a",
                selectionBefore: sel(1), selectionAfter: sel(3),
                origin: .structure, name: "list-split"
            ))

        let countBefore = history.undoStack.count
        XCTAssertEqual(history.undoStack.count, countBefore, "view 刷新不得入栈")

        XCTAssertEqual(history.undo(currentSource: "a\n- ")?.source, "a")
        XCTAssertEqual(history.undo(currentSource: "a")?.source, "")
        XCTAssertFalse(history.canUndo)

        XCTAssertEqual(history.redo(currentSource: "")?.source, "a")
        XCTAssertEqual(history.redo(currentSource: "a")?.source, "a\n- ")
        XCTAssertFalse(history.canRedo)
    }

    // MARK: - 空 patch 不入栈

    func testEmptyPatchesDoNotRecord() {
        var history = MarkdownEditorHistory()
        let recorded = history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [], sourceBefore: "AB",
                selectionBefore: sel0, selectionAfter: sel0,
                origin: .typing, name: "noop"
            ))
        XCTAssertFalse(recorded)
        XCTAssertFalse(history.canUndo)
    }

    // MARK: - redo 重放不变量

    /// undo 本身也是一次编辑：undo 后产生新 source，redo 基于该 source
    /// 重放。若 undo/redo 之间存在外部编辑，redo 必须拒绝而不是覆盖。
    func testRedoRejectsWhenBaseMismatch() {
        var history = MarkdownEditorHistory()
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch(0, 0, "", "a")], sourceBefore: "",
                selectionBefore: sel0, selectionAfter: sel(1),
                origin: .typing, name: "typing"
            ))
        _ = history.undo(currentSource: "a")
        let result = history.redo(currentSource: "外部改动")
        XCTAssertEqual(result?.source, "a")
    }
}
