import XCTest
@testable import MiaoYan

/// T12 输入规则（SPEC §4.3 空段前缀）：纯函数匹配 + undo 单元重组。
final class MarkdownInputRulesTests: XCTestCase {

    // MARK: matchPrefixInsertion 输入矩阵（AC-03/AC-06 子集）

    func testHeadingPrefixCompletionMatchesAllLevels() {
        for level in 1...6 {
            let source = String(repeating: "#", count: level) + " \n"
            let match = MarkdownInputRules.matchPrefixInsertion(
                source: source, insertedOffset: level, protectedRanges: [])
            XCTAssertEqual(match?.kind, .heading, "H\(level) 前缀完成必须匹配")
            XCTAssertEqual(match?.headingLevel, level)
            XCTAssertEqual(match?.prefixRangeUTF16, NSRange(location: 0, length: level + 1))
        }
    }

    func testBulletPrefixCompletionMatchesAllSymbols() {
        for symbol in ["-", "*", "+"] {
            let source = symbol + " \n"
            let match = MarkdownInputRules.matchPrefixInsertion(
                source: source, insertedOffset: 1, protectedRanges: [])
            XCTAssertEqual(match?.kind, .bulletList, "\(symbol) 前缀完成必须匹配")
        }
    }

    func testOrderedPrefixCompletion() {
        XCTAssertEqual(
            MarkdownInputRules.matchPrefixInsertion(source: "1. \n", insertedOffset: 2, protectedRanges: [])?.kind,
            .orderedList)
        XCTAssertEqual(
            MarkdownInputRules.matchPrefixInsertion(source: "23) \n", insertedOffset: 3, protectedRanges: [])?.kind,
            .orderedList)
    }

    func testQuotePrefixCompletion() {
        XCTAssertEqual(
            MarkdownInputRules.matchPrefixInsertion(source: "> \n", insertedOffset: 1, protectedRanges: [])?.kind,
            .quote)
        // 手输嵌套（≤3 层）也认
        XCTAssertEqual(
            MarkdownInputRules.matchPrefixInsertion(source: ">> \n", insertedOffset: 2, protectedRanges: [])?.kind,
            .quote)
        // 缩进的 quote 前缀与 heading/bullet 同规则（≤3 缩进）
        XCTAssertEqual(
            MarkdownInputRules.matchPrefixInsertion(source: "  > \n", insertedOffset: 3, protectedRanges: [])?.kind,
            .quote)
    }

    /// NE-03：CRLF 文档的输入规则与 LF 行为一致（行尾剥 \r\n 整体）。
    func testCRLFLineEndingStillMatches() {
        XCTAssertEqual(
            MarkdownInputRules.matchPrefixInsertion(source: "- \r\n", insertedOffset: 1, protectedRanges: [])?.kind,
            .bulletList, "CRLF 行尾的 bullet 前缀必须匹配")
        XCTAssertEqual(
            MarkdownInputRules.matchPrefixInsertion(source: "# \r\n", insertedOffset: 1, protectedRanges: [])?.kind,
            .heading, "CRLF 行尾的 heading 前缀必须匹配")
        XCTAssertNil(
            MarkdownInputRules.matchPrefixInsertion(source: "- x\r\n", insertedOffset: 1, protectedRanges: []),
            "CRLF 非空段仍不匹配")
    }

    func testIndentedPrefixStillMatches() {
        // ≤3 缩进的空段前缀（≥4 缩进由 codeIndented 保护块排除，见下）
        let match = MarkdownInputRules.matchPrefixInsertion(
            source: "  - \n", insertedOffset: 3, protectedRanges: [])
        XCTAssertEqual(match?.kind, .bulletList)
        XCTAssertEqual(match?.prefixRangeUTF16, NSRange(location: 0, length: 4))
    }

    // MARK: 不触发矩阵（NE-13 组合输入由 view 层排除；此处为文本形态）

    func testSpaceNotAtLineEndDoesNotMatch() {
        XCTAssertNil(
            MarkdownInputRules.matchPrefixInsertion(
                source: "- x\n", insertedOffset: 1, protectedRanges: []),
            "前缀后有内容：合法前缀未完成，不转换")
        XCTAssertNil(
            MarkdownInputRules.matchPrefixInsertion(
                source: "# 中 间\n", insertedOffset: 4, protectedRanges: []),
            "行中空格不是前缀完成")
    }

    func testInsertedCharacterMustBeSpace() {
        XCTAssertNil(
            MarkdownInputRules.matchPrefixInsertion(
                source: "-\n", insertedOffset: 1, protectedRanges: []),
            "非空格字符不构成前缀完成")
    }

    func testBareSymbolWithoutSpaceDoesNotMatch() {
        XCTAssertNil(
            MarkdownInputRules.matchPrefixInsertion(
                source: "-\n", insertedOffset: 1, protectedRanges: []))
    }

    func testProtectedBlocksDoNotMatch() {
        // fence 内一行 "# "（0`..3`\n 4# 5␠ 6\n）：空格在 5
        let fence = "```\n# \n```\n" as NSString
        let inner = NSRange(location: 4, length: 3)
        XCTAssertNil(
            MarkdownInputRules.matchPrefixInsertion(
                source: fence as String, insertedOffset: 5, protectedRanges: [inner]))
        // 同一位置无保护信息时本应匹配（对照：排除是保护块造成的）
        XCTAssertNotNil(
            MarkdownInputRules.matchPrefixInsertion(
                source: fence as String, insertedOffset: 5, protectedRanges: []))
    }

    func testSymbolRunsBeyondLimitsDoNotMatch() {
        XCTAssertNil(
            MarkdownInputRules.matchPrefixInsertion(
                source: "####### \n", insertedOffset: 7, protectedRanges: []),
            "7 个 # 不是合法 heading")
        XCTAssertNil(
            MarkdownInputRules.matchPrefixInsertion(
                source: ">>>> \n", insertedOffset: 4, protectedRanges: []),
            "4 层引用手输超出认定范围")
    }

    // MARK: collapseTypingPrefix（一键 undo 回字面前缀）

    private func insertEntry(_ history: inout MarkdownEditorHistory, _ text: String, at location: Int, base: String) {
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [SourcePatch(rangeUTF16: NSRange(location: location, length: 0), expectedText: "", replacement: text)],
                sourceBefore: base,
                selectionBefore: MarkdownSelection(anchorUTF16: location, focusUTF16: location, affinity: .downstream),
                selectionAfter: MarkdownSelection(
                    anchorUTF16: location + text.utf16.count, focusUTF16: location + text.utf16.count, affinity: .downstream),
                origin: .typing, name: "typing"))
    }

    func testCollapseMergesPrefixTypingIntoSingleUndoEntry() {
        var history = MarkdownEditorHistory()
        insertEntry(&history, "#", at: 0, base: "\n")
        insertEntry(&history, " ", at: 1, base: "#\n")
        XCTAssertEqual(history.undoStack.count, 2)

        XCTAssertTrue(
            history.collapseTypingPrefix(
                prefixRange: NSRange(location: 0, length: 2),
                selectionAfter: MarkdownSelection(anchorUTF16: 2, focusUTF16: 2, affinity: .downstream),
                name: "input-rule-heading"))
        XCTAssertEqual(history.undoStack.count, 1, "前缀输入合并为单条 undo 记录")

        let undo = history.undo(currentSource: "# \n")
        XCTAssertEqual(undo?.source, "\n", "一次 undo 回到字面前缀之前（不吞字）")
        XCTAssertEqual(undo?.name, "input-rule-heading")
    }

    func testCollapseAcrossCoalescingWindow() {
        // 用户在符号与空格间停顿超过合并窗：两条 entry 未被 coalesce
        // （时间窗拒绝合并），输入规则显式重组仍须一键 undo。
        final class Clock { var current = Date(timeIntervalSinceNow: -5) }
        let clock = Clock()
        var history = MarkdownEditorHistory(now: { clock.current })
        insertEntry(&history, "-", at: 0, base: "\n")
        clock.current = Date()  // 5 秒后
        insertEntry(&history, " ", at: 1, base: "-\n")
        XCTAssertEqual(history.undoStack.count, 2, "跨合并窗的 typing 不被自动合并")
        XCTAssertTrue(
            history.collapseTypingPrefix(
                prefixRange: NSRange(location: 0, length: 2),
                selectionAfter: MarkdownSelection(anchorUTF16: 2, focusUTF16: 2, affinity: .downstream),
                name: "input-rule-bulletList"))
        XCTAssertEqual(history.undo(currentSource: "- \n")?.source, "\n")
    }

    func testCollapseSkipsWhenChainBroken() {
        var history = MarkdownEditorHistory()
        insertEntry(&history, "#", at: 0, base: "\n")
        // 中间一次非纯插入（删除）打断链
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [SourcePatch(rangeUTF16: NSRange(location: 1, length: 1), expectedText: "x", replacement: "")],
                sourceBefore: "#x\n",
                selectionBefore: MarkdownSelection(anchorUTF16: 2, focusUTF16: 2, affinity: .downstream),
                selectionAfter: MarkdownSelection(anchorUTF16: 1, focusUTF16: 1, affinity: .downstream),
                origin: .delete, name: "delete"))
        insertEntry(&history, " ", at: 1, base: "#\n")
        // 此时栈顶链只覆盖 [1,2)，与前缀 [0,2) 不匹配：不重组
        XCTAssertFalse(
            history.collapseTypingPrefix(
                prefixRange: NSRange(location: 0, length: 2),
                selectionAfter: MarkdownSelection(anchorUTF16: 2, focusUTF16: 2, affinity: .downstream),
                name: "input-rule-heading"))
        XCTAssertEqual(history.undoStack.count, 3, "链不完整时保持既有粒度（不吞字）")
    }

    func testCollapseIgnoresNonTypingEntries() {
        var history = MarkdownEditorHistory()
        insertEntry(&history, "#", at: 0, base: "\n")
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [SourcePatch(rangeUTF16: NSRange(location: 1, length: 0), expectedText: "", replacement: " ")],
                sourceBefore: "#\n",
                selectionBefore: MarkdownSelection(anchorUTF16: 1, focusUTF16: 1, affinity: .downstream),
                selectionAfter: MarkdownSelection(anchorUTF16: 2, focusUTF16: 2, affinity: .downstream),
                origin: .structure, name: "indent"))
        XCTAssertFalse(
            history.collapseTypingPrefix(
                prefixRange: NSRange(location: 0, length: 2),
                selectionAfter: MarkdownSelection(anchorUTF16: 2, focusUTF16: 2, affinity: .downstream),
                name: "input-rule-heading"),
            "结构命令打断链：空格不属于前缀 typing，不合并")
    }
}
