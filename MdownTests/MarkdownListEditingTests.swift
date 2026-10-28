import XCTest
@testable import Mdown

/// T12 list/quote/task 结构编辑：Enter 拆分/退级、Tab/Shift+Tab、
/// Backspace/Delete、task toggle、跨块替换、输入规则 view 集成
/// （AC-06；NE-07/NE-08/NE-13/NE-21 的 T12 子集）。
@MainActor
final class MarkdownListEditingTests: XCTestCase {

    private func makeView(_ source: String) -> RichMarkdownTextView {
        let view = RichMarkdownTextView(source: source)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        // 持窗走 addTeardownBlock：tearDown 覆写是 nonisolated，
        // 在其中改 @MainActor 存储在 Swift 6 下编译不过
        // （CI Xcode 16.3；Xcode 27 的 Swift 5 模式放行）。
        addTeardownBlock { [weak window] in window?.close() }
        return view
    }

    private func enter(_ view: RichMarkdownTextView) -> Bool {
        view.text(view, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    private func tab(_ view: RichMarkdownTextView) -> Bool {
        view.text(view, doCommandBy: #selector(NSResponder.insertTab(_:)))
    }

    private func backtab(_ view: RichMarkdownTextView) -> Bool {
        view.text(view, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
    }

    private func backspace(_ view: RichMarkdownTextView) -> Bool {
        view.text(view, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
    }

    private func deleteForward(_ view: RichMarkdownTextView) -> Bool {
        view.text(view, doCommandBy: #selector(NSResponder.deleteForward(_:)))
    }

    // MARK: 行模型纯函数（MarkdownBlockModel）

    func testParseLineMatrix() {
        let ns = "- a\n1. b\n> c\n- [x] d\n  - 缩进项\n普通\n-\n" as NSString
        func line(_ i: Int) -> MarkdownBlockLine {
            MarkdownBlockModel.parseLine(ns, lineRange: ns.lineRange(for: NSRange(location: i, length: 0)))
        }
        XCTAssertEqual(line(0).kind, .bullet(symbol: "-"))
        XCTAssertEqual(line(0).prefixLength, 2)
        XCTAssertEqual(line(4).kind, .ordered(number: 1, closer: "."))
        XCTAssertEqual(line(9).kind, .quote(depth: 1))
        XCTAssertEqual(line(13).kind, .bullet(symbol: "-"))
        XCTAssertEqual(line(13).task?.checked, true, "- [x] 解析为 task 且已勾选")
        XCTAssertEqual(line(13).prefixLength, 6, "task 前缀含 [x] 与尾空格")
        XCTAssertEqual(line(22).kind, .bullet(symbol: "-"))
        XCTAssertEqual(line(22).indentUTF16, 2)
        XCTAssertEqual(line(30).kind, .none, "普通行无结构前缀")
        XCTAssertEqual(line(32).kind, .bullet(symbol: "-"))
        XCTAssertTrue(line(32).contentIsEmpty, "裸 marker 是空项")
    }

    func testParseLineRejectsInvalidMarkers() {
        let ns = "-x\n1.x\n- [x]y\n" as NSString
        XCTAssertEqual(MarkdownBlockModel.parseLine(ns, lineRange: NSRange(location: 0, length: 3)).kind, .none, "紧贴内容不是 marker")
        XCTAssertEqual(MarkdownBlockModel.parseLine(ns, lineRange: NSRange(location: 3, length: 4)).kind, .none)
        let task = MarkdownBlockModel.parseLine(ns, lineRange: NSRange(location: 7, length: 7))
        XCTAssertNil(task.task, "- [x]y 紧贴内容不是 task 项")
        XCTAssertEqual(task.prefixLength, 2, "marker 前缀止于空白")
    }

    // MARK: Enter 拆分（AC-06）

    func testEnterSplitOrderedItemIncrementsNumberOnlyForNewItem() {
        let view = makeView("1. a\n1. b\n1. c\n")
        // display "a\nb\nc\n"：caret display 1 = a 后
        view.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(enter(view))
        XCTAssertEqual(view.source, "1. a\n2. \n1. b\n1. c\n", "新项编号递增，其他项 marker 不重排")
    }

    func testEnterSplitTaskItemResetsCheckState() {
        let view = makeView("- [x] ab\n")
        // display "[x] ab\n"：caret display 5 = a 后
        view.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertTrue(enter(view))
        XCTAssertEqual(view.source, "- [x] a\n- [ ] b\n", "拆分新项 task 复位未勾选，原项勾选状态不动")
    }

    func testEnterSplitOrderedTaskIncrementsNumber() {
        let view = makeView("1. [x] ab\n")
        // display "[x] ab\n"：caret display 5 = ab 中间
        view.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertTrue(enter(view))
        XCTAssertEqual(
            view.source, "1. [x] a\n2. [ ] b\n",
            "有序 task 拆分：编号 +1 且勾选复位（只新项递增）")
    }

    func testEnterSplitQuoteOrderedItemIncrementsNumber() {
        let view = makeView("> 1. ab\n")
        // display "ab\n"：caret display 2 = ab 后
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(enter(view))
        XCTAssertEqual(
            view.source, "> 1. ab\n> 2. \n",
            "quote 内有序项拆分：完整前缀照抄，编号只新项 +1")
    }

    func testIncrementOrderedMarkerKeepsIndentLiteralAndMultiDigit() {
        XCTAssertEqual(
            MarkdownBlockModel.incrementOrderedMarker("\t10. ", closer: "."),
            "\t11. ", "缩进字面保留，多位数编号 +1")
        XCTAssertEqual(
            MarkdownBlockModel.incrementOrderedMarker("2) ", closer: ")"),
            "3) ", ") closer 同规则")
        XCTAssertEqual(
            MarkdownBlockModel.incrementOrderedMarker("> 9. ", closer: "."),
            "> 10. ", "9 → 10 进位")
        XCTAssertEqual(
            MarkdownBlockModel.incrementOrderedMarker("- ", closer: "."),
            "- ", "无编号前缀原样返回")
    }

    func testEnterSplitQuoteInheritsPrefix() {
        let view = makeView("> ab\n")
        // display "ab\n"：caret display 1 = a 后
        view.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(enter(view))
        XCTAssertEqual(view.source, "> a\n> b\n", "quote 拆分继承原前缀")
    }

    // MARK: Enter 空项退级（SPEC §4.3「退一级或退出最外层」）

    func testEnterOnNestedEmptyItemOutdentsOneLevel() {
        let view = makeView("- a\n  -\n")
        // display "a\n\n"：caret display 3 = 空项内容首
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(enter(view))
        XCTAssertEqual(view.source, "- a\n-\n", "空项 Enter 先退一级缩进，不直接退出")
    }

    func testEnterOnOutermostEmptyItemExitsList() {
        let view = makeView("- a\n-\n")
        // display "a\n\n"：caret display 3
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(enter(view))
        XCTAssertEqual(view.source, "- a\n", "最外层空项 Enter 删除该行退出列表")
    }

    func testEnterOnEmptyQuoteLineExits() {
        let view = makeView("> a\n>\n")
        // display "a\n\n"：caret display 3 = 空 quote 行
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(enter(view))
        XCTAssertEqual(view.source, "> a\n", "空 quote 行 Enter 删除该行退出")
    }

    // MARK: Tab / Shift+Tab（三层 mixed 结构）

    func testThreeLevelMixedListStructureMatrix() {
        let view = makeView("- a\n  - b\n    - c\n")
        // display "a\nb\nc\n"
        // 三层搭建后 Enter 拆 c：display "a\nb\nc\n" 中 c 后 = display 5
        view.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertTrue(enter(view))
        XCTAssertEqual(view.source, "- a\n  - b\n    - c\n    - \n", "三层内层项拆分保持四级……同层 marker 精确")

        // Shift+Tab 退到二层
        XCTAssertTrue(backtab(view))
        XCTAssertEqual(view.source, "- a\n  - b\n    - c\n  - \n", "Shift+Tab 退一级")

        // 再退到一层
        XCTAssertTrue(backtab(view))
        XCTAssertEqual(view.source, "- a\n  - b\n    - c\n- \n", "Shift+Tab 再退一级到最外层")

        // 最外层 Shift+Tab：吞掉按键但无操作（不删内容）
        XCTAssertTrue(backtab(view))
        XCTAssertEqual(view.source, "- a\n  - b\n    - c\n- \n", "最外层 Shift+Tab 无操作")

        // undo 逐级回：三次结构命令各一次
        XCTAssertTrue(view.performUndo())
        XCTAssertTrue(view.performUndo())
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "- a\n  - b\n    - c\n", "结构命令 undo 链完整恢复")
    }

    func testQuoteMixedWithListEnter() {
        let view = makeView("> 引\n> - 项\n")
        // display "引\n项\n"（quote 前缀与内层 list marker 都隐藏）
        // caret display 3 = "项" 后
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(enter(view))
        XCTAssertEqual(view.source, "> 引\n> - 项\n> - \n", "quote 内混合 list 行 Enter 继承完整前缀（quote+list）")
    }

    func testQuoteListEmptyItemEnterDowngradesToQuote() {
        let view = makeView("> 引\n> - \n")
        // display "引\n"：caret display 2 = 空项行
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(enter(view))
        XCTAssertEqual(view.source, "> 引\n> \n", "quote 内空 list 项 Enter 先退 list 层（保留 quote）")
    }

    func testQuoteNestedListItemEnterKeepsFullPrefix() {
        let view = makeView("> > - x\n")
        // display "x\n"：caret display 1 = x 后
        view.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(enter(view))
        XCTAssertEqual(view.source, "> > - x\n> > - \n", "两层 quote 内 list 拆分继承完整前缀")
    }

    func testTaskToggleInsideQuoteList() {
        let view = makeView("> - [ ] 买牛奶\n")
        // display "[ ] 买牛奶\n"：caret display 5 = 任务内容内
        view.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertTrue(view.toggleTaskAtSelection(), "quote 混合行的 task 可精确 toggle")
        XCTAssertEqual(view.source, "> - [x] 买牛奶\n")
    }

    func testTabInQuoteListIndentsInnerMarker() {
        let view = makeView("> - a\n")
        // display "a\n"：caret display 1 = a 后
        view.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(tab(view))
        XCTAssertEqual(view.source, ">   - a\n", "quote 内 list Tab 缩进内层 marker")

        XCTAssertTrue(backtab(view))
        XCTAssertEqual(view.source, "> - a\n", "Shift+Tab 退回内层缩进")
    }

    // MARK: Backspace / Delete（块首合并/退级，原子 patch）

    func testBackspaceAtQuoteContentStartRemovesOneLevel() {
        let view = makeView(">> ab\n")
        // display "ab\n"：caret display 0 = 内容首
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(backspace(view))
        XCTAssertEqual(view.source, "> ab\n", "三层引用 Backspace 退一层")

        XCTAssertTrue(backspace(view))
        XCTAssertEqual(view.source, "ab\n", "最外层引用 Backspace 退出")
    }

    func testBackspaceAtNestedItemOutdentsOneLevel() {
        let view = makeView("- a\n  - b\n")
        // display "a\nb\n"：caret display 2 = b 首
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(backspace(view))
        XCTAssertEqual(view.source, "- a\n- b\n", "嵌套项块首 Backspace 先退一级缩进，不吞 marker 变懒延续行")
    }

    func testCaretAtEmptyItemLineStartEnterExits() {
        let view = makeView("- a\n-\n")
        // display "a\n\n"：caret display 2 = 空项行首（块缝 display 坐标）
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(enter(view))
        XCTAssertEqual(view.source, "- a\n", "空项行首（非内容首）Enter 仍删除该行退出，不凭空拆出新项")
    }

    func testBackspaceInsideContentFallsBackToDefault() {
        let view = makeView("- abc\n")
        // display "abc\n"：caret display 2 = b/c 间（非内容首）
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertFalse(backspace(view), "内容中间 Backspace 走默认字符删除")
    }

    func testDeleteForwardOnEmptyItemRemovesLine() {
        let view = makeView("- a\n-\n")
        // display "a\n\n"：caret display 3 = 空项
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(deleteForward(view))
        XCTAssertEqual(view.source, "- a\n", "空项 Delete 前向删除整行")
    }

    func testDeleteForwardOnNonEmptyLineFallsBack() {
        let view = makeView("- abc\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(deleteForward(view), "非空行 Delete 走默认行为")
    }

    // MARK: task 精确 span toggle（NE-07）

    func testTaskToggleFlipsExactlyOneCharacter() {
        let view = makeView("- [ ] 买牛奶\n- [x] 洗碗\n")
        // display "买牛奶\n洗碗\n"：caret display 2 = 任务一内
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(view.toggleTaskAtSelection())
        XCTAssertEqual(view.source, "- [x] 买牛奶\n- [x] 洗碗\n", "勾选只动括号内单字符")

        XCTAssertTrue(view.toggleTaskAtSelection())
        XCTAssertEqual(view.source, "- [ ] 买牛奶\n- [x] 洗碗\n", "再 toggle 复原")

        // undo 一次回原文（单一事务）
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "- [x] 买牛奶\n- [x] 洗碗\n")
    }

    func testTaskToggleOutsideTaskItemFails() {
        let view = makeView("- 普通\n")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertFalse(view.toggleTaskAtSelection(), "非 task 项不响应 toggle")
    }

    // MARK: 跨块替换（SPEC §4.3「验证完整映射后一次事务」）

    func testCrossBlockReplaceIsSingleAtomicPatch() {
        let view = makeView("aaa\n\n- bbb\n")
        // display "aaa\n\nbbb\n"：选 display [2,6) = "a\n\nb"
        view.setSelectedRange(NSRange(location: 2, length: 4))
        view.insertText("X")
        XCTAssertEqual(view.source, "aaXbb\n", "跨块替换经完整映射一次落 source（marker 一并消解）")
        XCTAssertEqual(view.displayText, "aaXbb\n")
        XCTAssertEqual(view.revision, 1, "一次替换 = 一次 revision（单事务）")

        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "aaa\n\n- bbb\n", "跨块替换 undo 一次回原文")
    }

    func testCrossBlockReplaceSpanningThreeBlocks() {
        let view = makeView("# 标\n\n正文。\n")
        // display "标\n\n正文。\n"：选 display [0,7) = "标\n\n正文"
        view.setSelectedRange(NSRange(location: 0, length: 7))
        view.insertText("新")
        XCTAssertEqual(view.source, "新", "heading→段落跨块替换一次事务，结构与尾换行一并消解")
    }

    func testSpanReplaceEndingAtBlockSeamAbsorbsNextMarker() {
        let view = makeView("aaa\n\n- bbb\n")
        // display "aaa\n\nbbb\n"：选 display [2,5) = "a\n\n"，终点恰在 list 块缝
        view.setSelectedRange(NSRange(location: 2, length: 3))
        view.insertText("X")
        XCTAssertEqual(
            view.source, "aaXbbb\n",
            "终点在块缝时下一块的隐藏 marker 一并消解，不得泄漏成可见字面")
    }

    func testSpanInsideSingleBlockWithHiddenMarkerRejected() {
        let view = makeView("a `b` c\n")
        // display "a b c\n"：选 display [1,3) = " b"——终点映到闭 backtick
        // 前，span 会把不可见反引号扫进替换区间；必须安全拒绝而非泄漏。
        view.setSelectedRange(NSRange(location: 1, length: 2))
        view.insertText("X")
        XCTAssertEqual(view.source, "a `b` c\n", "单块含隐藏 marker 的选择不走 span 泄漏路径")
        XCTAssertEqual(view.displayText, "a b c\n", "拒绝后 display 回退为 source 投影")
    }

    // MARK: 输入规则 view 集成（AC-05：typing→分块→undo 至原文）

    func testEmptyParagraphPrefixConvertsWithSingleUndoToLiteral() {
        let view = makeView("\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("#")
        view.insertText(" ")
        XCTAssertEqual(view.source, "# \n")
        XCTAssertEqual(view.lastInputRuleTriggered?.kind, .heading, "空段前缀完成触发输入规则")
        XCTAssertEqual(view.lastInputRuleTriggered?.headingLevel, 1)

        // 一键 undo 回空段（完整字面前缀消失，不吞字）
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "\n", "一键 undo 回字面前缀之前")

        XCTAssertTrue(view.performRedo())
        XCTAssertEqual(view.source, "# \n", "redo 重放前缀")
    }

    func testEmptyParagraphBulletAndQuotePrefixConvert() {
        let view = makeView("\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("-")
        view.insertText(" ")
        XCTAssertEqual(view.source, "- \n")
        XCTAssertEqual(view.lastInputRuleTriggered?.kind, .bulletList)
        XCTAssertEqual(view.displayText, "\n", "空项 marker 隐藏后 display 为空行")

        let quote = makeView("\n")
        quote.setSelectedRange(NSRange(location: 0, length: 0))
        quote.insertText(">")
        quote.insertText(" ")
        XCTAssertEqual(quote.source, "> \n")
        XCTAssertEqual(quote.lastInputRuleTriggered?.kind, .quote)
    }

    func testPrefixWithPriorPauseStillSingleUndo() {
        // 符号与空格分属不同 coalescing 窗口：输入规则显式重组仍一键 undo。
        let view = makeView("\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("1")
        view.insertText(".")
        view.insertText(" ")
        XCTAssertEqual(view.source, "1. \n")
        XCTAssertEqual(view.lastInputRuleTriggered?.kind, .orderedList)
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "\n", "跨合并窗的前缀输入仍一键 undo 回字面")
    }

    func testCompositionCommitDoesNotTriggerInputRule() {
        let view = makeView("\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setMarkedText("#", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        // IME 提交整段 "# "（一次 insertText 多字符，NE-13 组合输入不触发）
        view.insertText("# ")
        view.unmarkText()
        XCTAssertEqual(view.source, "# \n")
        XCTAssertNil(view.lastInputRuleTriggered, "组合输入提交不触发 typing rule")
    }

    func testPasteDoesNotTriggerInputRule() {
        let view = makeView("\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let board = NSPasteboard.general
        board.clearContents()
        board.setString("# ", forType: .string)
        view.paste(nil)
        XCTAssertEqual(view.source, "\\# \n", "普通粘贴转义结构标记")
        XCTAssertEqual(view.displayText, "# \n")
        XCTAssertNil(view.lastInputRuleTriggered, "粘贴不触发 typing rule（NE-21）")
        // 粘贴单条历史：一次 undo 回空
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "\n")
    }

    func testFenceContentDoesNotTriggerInputRule() {
        let view = makeView("```\n\n```\n")
        // display 原样 "```\n\n```\n"：caret display 4 = fence 内空行行首
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.insertText("#")
        view.insertText(" ")
        XCTAssertEqual(view.source, "```\n# \n```\n", "fence 内按字面输入")
        XCTAssertNil(view.lastInputRuleTriggered, "保护块内不触发输入规则（NE-10）")
    }

    func testPlainTypingAfterWordDoesNotTrigger() {
        let view = makeView("ab\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.insertText(" ")
        XCTAssertEqual(view.source, "ab \n")
        XCTAssertNil(view.lastInputRuleTriggered, "行尾空格但行内已有内容：非空段前缀")
    }

    // MARK: undo / redo selection 收敛（marker 隐藏处 source↔display 映射）

    func testUndoRedoSelectionMapsThroughHiddenMarker() {
        let view = makeView("- ab\n")
        // display "ab\n"：caret display 2 = b 后
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(tab(view))
        XCTAssertEqual(view.source, "  - ab\n")
        XCTAssertEqual(view.selectedRange().location, 2, "Tab 后 caret 停在内容同位（marker 隐藏）")

        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "- ab\n")
        XCTAssertEqual(view.selectedRange().location, 2, "undo 后 caret 映射回 display 内容位置")

        XCTAssertTrue(view.performRedo())
        XCTAssertEqual(view.source, "  - ab\n")
        XCTAssertEqual(view.selectedRange().location, 2, "redo 后 caret 经投影映射（不按 source 偏移直用）")
    }

    func testStructureThenTypingThenUndoChain() {
        // AC-05 子集：typing→结构→undo 链逐层恢复。
        let view = makeView("- a\n")
        // display "a\n"：caret 1 = a 后
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertText("b")
        XCTAssertEqual(view.source, "- ab\n")
        XCTAssertTrue(enter(view))
        XCTAssertEqual(view.source, "- ab\n- \n")
        view.insertText("c")
        XCTAssertEqual(view.source, "- ab\n- c\n")

        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "- ab\n- \n", "undo typing")
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "- ab\n", "undo 结构拆分")
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "- a\n", "undo typing")
    }
}
