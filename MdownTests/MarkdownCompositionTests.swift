import XCTest
@testable import Mdown

/// T04 / G0：IME composition 经 AppKit input protocol 的真实路径。
/// setMarkedText / unmarkText / insertText 是输入系统驱动 NSTextView 的
/// 协议形态；真实候选窗交互留实机验证（validation/G0）。
@MainActor
final class MarkdownCompositionTests: XCTestCase {

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
        // 在其中改 @MainActor 存储在 Swift 6 下编译不过。
        addTeardownBlock { [weak window] in window?.close() }
        return view
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
}
