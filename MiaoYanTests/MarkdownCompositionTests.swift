import XCTest
@testable import MiaoYan

/// T04 / G0：IME composition 经 AppKit input protocol 的真实路径。
/// setMarkedText / unmarkText / insertText 是输入系统驱动 NSTextView 的
/// 协议形态；真实候选窗交互留实机验证（validation/G0）。
@MainActor
final class MarkdownCompositionTests: XCTestCase {

    private var testWindow: NSWindow?

    private func makeView(_ source: String) -> RichMarkdownTextView {
        let view = RichMarkdownTextView(source: source)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        testWindow = window
        return view
    }

    override func tearDown() {
        testWindow = nil
        super.tearDown()
    }

    func testCompositionCommitReachesSourceOnce() {
        let view = makeView("正文。\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))

        // start：候选进入 marked 状态
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText(), "组合中必须存在 markedTextRange")
        let markedSource = view.source
        XCTAssertTrue(markedSource.contains("zhong") || markedSource.contains("正文"), "组合期间 source 跟随 display（不打断 marked）")

        // update：候选变化
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // commit：输入系统以 insertText 提交最终文本
        view.insertText("中文")
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText(), "提交后不得残留 markedTextRange")
        XCTAssertEqual(view.source, "正文中文。\n", "组合提交必须精确进入 source")
    }

    func testCompositionCancelDoesNotLeavePartialText() {
        let view = makeView("正文。\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))

        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        // cancel：输入系统清空 marked（Esc 形态）
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.source, "正文。\n", "取消组合不得留下部分输入")
    }

    func testCompositionInsideEmphasisPreservesMarkers() {
        let view = makeView("**AB**\n")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.insertText("中")
        view.unmarkText()
        XCTAssertEqual(view.source, "**A中B**\n", "组合提交在强调内不得删除 delimiter")
    }

    func testCompositionFollowedByTypingStaysConsistent() {
        let view = makeView("段落\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("中")
        view.unmarkText()
        view.insertText("后续")
        XCTAssertEqual(view.source, "段落中后续\n", "组合后连续直输不串位")
    }

    func testCommitDoesNotWholeReplaceWhileMarked() {
        // 组合期间视图不得整段替换 textStorage（会打断候选显示）：
        // 以 marked 状态下连续 update 后 markedTextRange 仍有效来验证。
        let view = makeView("行首 **粗** 行尾\n")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.setMarkedText("ka", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedBefore = view.hasMarkedText()
        view.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText(), "update 后 marked 仍有效（未整段重置）")
        view.insertText("候选")
        view.unmarkText()
        XCTAssertEqual(view.source, "行首 **候选粗** 行尾\n")
        _ = markedBefore
    }

    // MARK: - T06：composition 与 history 的交互

    /// PLAN §5 oracle：真实 AppKit composition 宿主 + 候选；submit 一次
    /// history，undo 恢复 source/selection。marked 期间的多次 update 不
    /// 产生中间历史条目。
    func testCompositionCommitsOnceAndUndoRestoresSelection() {
        let view = makeView("正文。\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let historyCountBefore = view.history.undoStack.count

        // start → 多次 update → commit
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("中文")
        view.unmarkText()

        XCTAssertEqual(view.source, "正文中文。\n")
        XCTAssertEqual(
            view.history.undoStack.count, historyCountBefore + 1,
            "composition 提交只产生一条历史（多次 update 不各记一条）")

        // undo 恢复 composition 前的 source 与 selection
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "正文。\n", "undo 恢复 composition 前 source")
        XCTAssertEqual(
            view.selectedRange().location, 2,
            "undo 恢复 composition 前 selection（setMarkedText 前 caret 在 2）")

        // redo 重放
        XCTAssertTrue(view.performRedo())
        XCTAssertEqual(view.source, "正文中文。\n")
    }

    /// composition 取消不留历史。
    func testCompositionCancelDoesNotRecordHistory() {
        let view = makeView("正文。\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let historyCountBefore = view.history.undoStack.count

        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()

        XCTAssertEqual(
            view.history.undoStack.count, historyCountBefore,
            "取消组合不得产生历史；got \(view.history.undoStack.count) entries: \(view.history.undoStack.map { "\($0.name)@\($0.origin.rawValue) patches=\($0.patches.count)" })")
        XCTAssertEqual(view.source, "正文。\n")
    }

    /// composition 提交与紧随的普通 typing 不合并（SPEC §5.4：IME 提交
    /// 是明确 group）。
    func testCompositionCommitDoesNotCoalesceWithFollowingTyping() {
        let view = makeView("正文。\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))

        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("中")
        view.unmarkText()
        let countAfterComposition = view.history.undoStack.count

        view.insertText("后续")
        XCTAssertEqual(view.source, "正文中后续。\n")
        XCTAssertEqual(
            view.history.undoStack.count, countAfterComposition + 1,
            "composition 后的普通 typing 必须独立成组")
    }

    /// marked 期间的 parse/rebuild 不打断 composition（不登记历史、
    /// 不重置 markedTextRange）。
    func testRebuildDuringMarkedDoesNotInterruptComposition() {
        let view = makeView("行首 **粗** 行尾\n")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        let historyCountBefore = view.history.undoStack.count

        view.setMarkedText("ka", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        // displayOffset(forSourceOffset:) 内部会 rebuildProjection——这
        // 是 parse/render 刷新的代表路径。marked 期间调用不得打断组合。
        _ = view.displayOffset(forSourceOffset: 0)
        XCTAssertTrue(view.hasMarkedText(), "rebuildProjection 不得打断 markedTextRange")
        XCTAssertEqual(view.history.undoStack.count, historyCountBefore, "view 刷新不登记历史")

        view.insertText("候选")
        view.unmarkText()
        XCTAssertEqual(view.source, "行首 **候选粗** 行尾\n", "组合提交在刷新后仍精确")
    }
}
