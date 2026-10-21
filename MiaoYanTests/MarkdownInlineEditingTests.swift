import AppKit
import XCTest
@testable import MiaoYan

/// T11：行内格式 toggle（source patch wrap/unwrap）、link label/target
/// 独立编辑与安全 scheme、marker affinity、escape/softbreak/unclosed、
/// reference/footnote 保留。全部断言 source bytes + selection。
@MainActor
final class MarkdownInlineEditingTests: XCTestCase {

    private var testWindow: NSWindow?

    private func makeView(_ source: String) -> RichMarkdownTextView {
        let view = RichMarkdownTextView(source: source)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = view
        testWindow = window
        return view
    }

    override func tearDown() {
        testWindow = nil
        super.tearDown()
    }

    // MARK: 行内格式 wrap / unwrap

    func testBoldWrapSelectionViaSourcePatch() {
        let view = makeView("前 AB 后\n")
        view.setSelectedRange(NSRange(location: 2, length: 2))  // "AB"
        XCTAssertTrue(view.applyInlineFormat(.strong))
        XCTAssertEqual(view.source, "前 **AB** 后\n", "wrap 必须以 source patch 落盘")
        XCTAssertEqual(view.displayText, "前 AB 后\n", "wrap 后 display 不显示 marker")
        // selectionAfter 应仍选中 AB（source 坐标 +2 映射回 display）
        XCTAssertEqual(view.selectedRange, NSRange(location: 2, length: 2))
    }

    func testBoldUnwrapWhenDelimitersAdjacent() {
        let view = makeView("前 **AB** 后\n")
        view.setSelectedRange(NSRange(location: 2, length: 2))  // display "AB"
        XCTAssertTrue(view.applyInlineFormat(.strong))
        XCTAssertEqual(view.source, "前 AB 后\n", "两侧紧贴 delimiter 时 unwrap")
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "前 **AB** 后\n", "格式 toggle 可 undo")
    }

    func testItalicAndStrikethroughAndCodeToggle() {
        let italic = makeView("文字 X 文字\n")
        italic.setSelectedRange(NSRange(location: 3, length: 1))
        XCTAssertTrue(italic.applyInlineFormat(.emphasis))
        XCTAssertEqual(italic.source, "文字 *X* 文字\n")

        let strike = makeView("文字 XY 文字\n")
        strike.setSelectedRange(NSRange(location: 3, length: 2))
        XCTAssertTrue(strike.applyInlineFormat(.strikethrough))
        XCTAssertEqual(strike.source, "文字 ~~XY~~ 文字\n")

        let code = makeView("文字 x 文字\n")
        code.setSelectedRange(NSRange(location: 3, length: 1))
        XCTAssertTrue(code.applyInlineFormat(.code))
        XCTAssertEqual(code.source, "文字 `x` 文字\n")
        XCTAssertEqual(code.displayText, "文字 x 文字\n")
    }

    func testUnwrapOnlyTouchesDelimitersNotContent() {
        let view = makeView("A **B** C\n")
        view.setSelectedRange(NSRange(location: 2, length: 1))  // display "B"
        XCTAssertTrue(view.applyInlineFormat(.strong))
        XCTAssertEqual(view.source, "A B C\n", "unwrap 只删 delimiter，不动内容字节")
    }

    func testCodeUnwrapSingleBacktickNotDouble() {
        let single = makeView("a `x` b\n")
        single.setSelectedRange(NSRange(location: 2, length: 1))
        XCTAssertTrue(single.applyInlineFormat(.code))
        XCTAssertEqual(single.source, "a x b\n")

        let double = makeView("a ``x`` b\n")
        double.setSelectedRange(NSRange(location: 2, length: 1))  // display "x"
        // 双 backtick span：unwrap 不匹配单 backtick，wrap 会制造歧义 run ⇒
        // 显式拒绝，原字节不动
        XCTAssertFalse(double.applyInlineFormat(.code))
        XCTAssertEqual(double.source, "a ``x`` b\n", "双 backtick span 不得被破坏成三 backtick")
    }

    func testEmptySelectionFormatsWordUnderCaret() {
        let view = makeView("前 后\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))  // "后" 内
        XCTAssertTrue(view.applyInlineFormat(.strong))
        XCTAssertEqual(view.source, "前 **后**\n")
    }

    func testFormatDoesNotTouchUnselectedRanges() {
        let view = makeView("`old` 与 tail\n")
        // display "old 与 tail\n"；选中 "tail"
        view.setSelectedRange(NSRange(location: 6, length: 4))
        XCTAssertTrue(view.applyInlineFormat(.strong))
        XCTAssertEqual(view.source, "`old` 与 **tail**\n", "未选中范围（含既有 code span）字节不动")
    }

    // MARK: link label / target 独立编辑与安全 scheme

    func testUpdateLinkTargetKeepsLabelBytes() {
        let view = makeView("看 [文档](https://a.com) 后续\n")
        // display "看 文档 后续\n"，caret 放 "文" 处（display 2）
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertNotNil(view.linkAtSelection())
        XCTAssertTrue(view.updateLinkTarget("https://b.org"))
        XCTAssertEqual(view.source, "看 [文档](https://b.org) 后续\n", "label 字节必须原样保留")
        XCTAssertEqual(view.displayText, "看 文档 后续\n")
    }

    func testUpdateLinkTargetRejectsUnsafeScheme() {
        let view = makeView("[x](https://a.com)\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(view.updateLinkTarget("javascript:alert(1)"), "javascript: 必须拒绝")
        XCTAssertFalse(view.updateLinkTarget("data:text/html,<script>"))
        XCTAssertFalse(view.updateLinkTarget("vbscript:x"))
        XCTAssertEqual(view.source, "[x](https://a.com)\n", "拒绝时 source 不动")
    }

    func testLinkSafetyAllowsRelativeAndKnownSchemes() {
        XCTAssertTrue(MarkdownLinkSafety.isEditableTarget("other.md"))
        XCTAssertTrue(MarkdownLinkSafety.isEditableTarget("#section"))
        XCTAssertTrue(MarkdownLinkSafety.isEditableTarget("https://example.com/x?y=1"))
        XCTAssertTrue(MarkdownLinkSafety.isEditableTarget("mailto:a@b.c"))
        XCTAssertFalse(MarkdownLinkSafety.isEditableTarget(""))
        XCTAssertFalse(MarkdownLinkSafety.isEditableTarget("line1\nline2"))
        XCTAssertFalse(MarkdownLinkSafety.isEditableTarget("unknown-scheme:xyz"))
    }

    func testModifierClickOpensLinkAndKeepsCaret() {
        let view = makeView("[链](https://a.com) 后\n")
        view.setSelectedRange(NSRange(location: 1, length: 0))  // label 内
        var opened: [String] = []
        view.onOpenLink = { opened.append($0.target) }

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: testWindow?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
        view.mouseDown(with: event)
        XCTAssertEqual(opened, ["https://a.com"], "⌘+click 开链接")
        XCTAssertEqual(view.selectedRange.location, 1, "开链接不移动 caret")

        // 非 ⌘ 修饰不进 open 分支：只验证判定面（plain click 的默认 caret
        // 行为走 AppKit super 转发，测试环境无真实事件源，不驱动 mouseDown）
        XCTAssertNil(view.openLinkIntent(modifierFlags: [.option]), "⌥ 不开链接")
        XCTAssertNil(view.openLinkIntent(modifierFlags: []), "无修饰不开链接")
        XCTAssertEqual(opened.count, 1, "只有 ⌘+click 触发 onOpenLink")
    }

    func testScannerSkipsReferenceAndFootnote() {
        let source = "见 [ref][1] 与 [^note] 定义 [1]: https://x\n"
        XCTAssertEqual(InlineLinkScanner.scan(source).count, 0, "reference/footnote 不是 inline link")
        // 编辑相邻文字，定义字节原位保留
        let view = makeView(source)
        view.setSelectedRange(NSRange(location: 2, length: 0))  // ␣ 与 [ 之间
        view.insertText("Z")
        XCTAssertEqual(view.source, "见 Z[ref][1] 与 [^note] 定义 [1]: https://x\n")
        XCTAssertTrue(view.source.contains("[1]: https://x"), "引用定义保留原位")
    }

    // MARK: unclosed / escape / softbreak projection 规则

    func testUnclosedEmphasisStaysLiteralAndEditable() {
        let view = makeView("未闭合 **ab c\n")
        XCTAssertEqual(view.displayText, "未闭合 **ab c\n", "未配对 marker 必须原样显示")
        view.setSelectedRange(NSRange(location: 10, length: 0))  // "c" 后
        view.insertText("!")
        XCTAssertEqual(view.source, "未闭合 **ab c!\n")
    }

    func testEscapedMarkerIsLiteralAndEditable() {
        let view = makeView("字面 \\*not em\\* 尾\n")
        XCTAssertEqual(view.displayText, "字面 *not em* 尾\n", "转义 marker 不做样式")
        view.setSelectedRange(NSRange(location: 10, length: 0))
        view.insertText("X")
        XCTAssertEqual(view.source, "字面 \\*not emX\\* 尾\n")
    }

    func testSoftbreakParagraphEditingMapsExactly() {
        let view = makeView("第一行\n第二行\n")
        view.setSelectedRange(NSRange(location: 4, length: 0))  // "第" 前
        view.insertText("X")
        XCTAssertEqual(view.source, "第一行\nX第二行\n", "softbreak 段内编辑精确落位")
    }

    // MARK: marker affinity（caret 在 hidden marker 边界可逆）

    func testCaretAtMarkerBoundariesDoesNotDeleteMarkers() {
        let view = makeView("**AB** 尾\n")
        // display "AB 尾\n"；caret 0 = opening ** 之后（内容起点）
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("X")
        XCTAssertEqual(view.source, "**XAB** 尾\n", "内容起点输入必须落在结构内")
        // 第一处插入后 display 为 "XAB 尾\n"；caret 4 = ␣ 与 尾 之间，
        // 输入落在结构外（closing ** 之后）
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.insertText("Y")
        XCTAssertEqual(view.source, "**XAB** Y尾\n", "结构终点输入落在结构外")
    }

    // MARK: heading split（AC-01）

    func testHeadingEnterSplitsIntoParagraphKeepingMarker() {
        let view = makeView("## 标题内容\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))  // display "标题|内容"
        view.insertText("\n")
        XCTAssertEqual(
            view.source, "## 标题\n内容\n",
            "heading 内回车拆分：下半成为无 marker 段落，原 marker 字节不动")
        XCTAssertEqual(view.displayText, "标题\n内容\n")
    }
}
