import XCTest
@testable import MiaoYan

/// T04 / G0：RichMarkdownTextView 直接编辑（AppKit input protocol 路径）、
/// 结构命令、undo/redo、性能探针。
@MainActor
final class RichMarkdownEditingTests: XCTestCase {

    private var testWindow: NSWindow?

    private func makeView(_ source: String) -> RichMarkdownTextView {
        let view = RichMarkdownTextView(source: source)
        // 挂到 window 确保文本输入协议在全量测试序列中稳定
        // （无 window 时 firstResponder 状态在测试顺序敏感场景下不确定）。
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

    // MARK: 正文与行内格式直接编辑（source bytes 断言）

    func testTypingPlainParagraphReachesSource() {
        let view = makeView("# 标\n\n正文段落。\n")
        // display: "标\n\n正文段落。\n"（heading marker 隐藏 + blank 行保留）
        // 标(0)\n(1)\n(2)正(3)文(4)段(5)落(6)。(7)\n(8)
        // caret 放 display 7 = "落" 与 "。" 之间
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.insertText("新")
        XCTAssertEqual(view.source, "# 标\n\n正文段落新。\n", "普通输入必须精确落到 source")
        XCTAssertEqual(view.revision, 1, "init 0 + 每次编辑 +1")
    }

    func testTypingInsideEmphasisDoesNotDeleteMarkers() {
        let view = makeView("**AB** 后文\n")
        // display: "AB 后文\n"
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertText("X")  // display 1 = A 与 B 之间
        XCTAssertEqual(view.source, "**AXB** 后文\n", "编辑强调内容不得删除 delimiter")
        XCTAssertEqual(view.displayText, "AXB 后文\n")
    }

    func testTypingInsideCodeSpanKeepsBackticks() {
        let view = makeView("前 `码` 后\n")
        view.setSelectedRange(NSRange(location: 3, length: 0))  // display 3 = "码" 后
        view.insertText("x")
        XCTAssertEqual(view.source, "前 `码x` 后\n", "code span 编辑保留 backtick")
    }

    func testHeadingEditKeepsMarkerInSource() {
        let view = makeView("## 二级\n")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertText("X")  // display 1 = "二" 后
        XCTAssertEqual(view.source, "## 二X级\n", "heading 编辑后 marker 原样")
    }

    func testCaretMoveDoesNotResourceifyOrChangeBytes() {
        let view = makeView("**AB**\n")
        let sourceBefore = view.source
        let displayBefore = view.displayText
        for offset in 0...3 {
            view.setSelectedRange(NSRange(location: offset, length: 0))
        }
        XCTAssertEqual(view.source, sourceBefore, "点击/移动不得改 source")
        XCTAssertEqual(view.displayText, displayBefore, "点击不得触发显示回退")
        XCTAssertEqual(view.displayText, "AB\n", "hidden marker 不因点击重新显示")
    }

    /// 懒延续行（"- 一\n二"）在视图 display 中不得丢首字符（G0 修复回归）。
    func testLazyContinuationLineDisplaysFully() {
        let view = makeView("- 一\n二\n")
        XCTAssertEqual(view.displayText, "一\n二\n", "懒延续行首字符不得被 marker 段吞掉")
        // 懒延续行内编辑也必须落到 source 的正确位置（"二" 之后插入不串位）
        view.setSelectedRange(NSRange(location: 3, length: 0))  // display 3 = "二" 后（"一\n二\n"）
        view.insertText("X")
        XCTAssertEqual(view.source, "- 一\n二X\n")
    }

    // MARK: 三层 list 结构命令（AC-06 原型）

    func testEnterSplitsListItemAtSameLevel() {
        let view = makeView("- 一级甲\n  - 二级\n    - 三级\n")
        // display（三层 marker 隐藏）: "一级甲\n二级\n三级\n"
        // 一(0)级(1)甲(2)\n(3) 二(4)级(5)\n(6) 三(7)级(8)\n(9)
        // caret 放行 2 "三级" 内容起点（display 7 = '三' 前）
        view.setSelectedRange(NSRange(location: 7, length: 0))
        let handled = view.text(view, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(handled)
        // caret 在内容起点：前项为空项，"三级" 起始新项（可再 Enter 退出）
        XCTAssertTrue(view.source.contains("    - \n    - 三级\n"), "Enter 必须按同级 marker 在 caret 处拆分")
    }

    /// Enter 拆分发生在 caret 位置而非行尾："- abc" 光标在 b 后
    /// 得 "- ab\n- c"，不把整行挤到新项。
    func testEnterSplitsItemAtCaret() {
        let view = makeView("- abc\n")
        // display "abc\n"：caret display 2 = b 后
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(view.text(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(view.source, "- ab\n- c\n", "Enter 在项内容中间按 caret 拆分，光标后内容归新项")
    }

    /// 有序列表（`1.`/`2.`）的结构命令与无序一致：Tab 缩进、Shift+Tab
    /// 退回、空项 Enter 退出。
    func testOrderedListItemStructureCommands() {
        let view = makeView("1. 甲\n2. 乙\n")
        // display "甲\n乙\n"：caret display 3 = 乙 后
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(view.text(view, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(view.source, "1. 甲\n  2. 乙\n", "有序列表 Tab 缩进二级")
        XCTAssertTrue(view.text(view, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        XCTAssertEqual(view.source, "1. 甲\n2. 乙\n", "有序列表 Shift+Tab 退回一级")

        let empty = makeView("1. 甲\n2.\n")
        // display "甲\n\n"：caret display 3 = 空项行
        empty.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(empty.text(empty, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(empty.source, "1. 甲\n", "有序空项 Enter 退出列表")
    }

    /// 快速路径后的连续输入必须持续落进 source：块尾连打三个字符，
    /// 第三个字符的定位不得因 rendered 坐标过期而失败（textDidChange
    /// 开头收敛投影）。
    func testConsecutiveTypingAtBlockEndKeepsLandingInSource() {
        let view = makeView("- 一\n\n段落。\n")
        // display "一\n\n段落。\n"：caret display 6 = "。" 后
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertText("a")
        view.insertText("b")
        view.insertText("c")
        XCTAssertEqual(view.source, "- 一\n\n段落。abc\n", "连续输入不得因 stale 投影坐标丢字")
        XCTAssertEqual(view.displayText, "一\n\n段落。abc\n")
    }

    /// 非首块的 displayOffset(forSourceOffset:) 不得把 source 偏移先减块
    /// 起点（段的 source 坐标本就是文档绝对），否则全部折叠回块首。
    func testDisplayOffsetInsideNonFirstBlock() {
        let view = makeView("前段\n\n- 项\n")
        // source "前段\n\n- 项\n"：块起点 4，"项"=6。display "前段\n\n项\n"
        // 中 "项" 位于 display 4。
        XCTAssertEqual(view.displayOffset(forSourceOffset: 6), 4, "块内 source 偏移必须映射到块内 display 位置")
    }

    func testTabIndentsAndOutdentsThreeLevelList() {
        let view = makeView("- 一\n- 二\n- 三\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))  // "一" 后（display）
        XCTAssertTrue(view.text(view, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(view.source, "- 一\n  - 二\n- 三\n", "Tab 缩进二级")

        XCTAssertTrue(view.text(view, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        XCTAssertEqual(view.source, "- 一\n- 二\n- 三\n", "Shift+Tab 退回一级")
    }

    func testEnterOnEmptyItemExitsList() {
        let view = makeView("- 内容\n-\n")
        // display: "内容\n\n"（空项 marker 隐藏后为空行）
        view.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertTrue(view.text(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(view.source, "- 内容\n", "空项 Enter 退出列表并移除该行")
    }

    func testBackspaceAtItemStartRemovesMarkerOnly() {
        let view = makeView("- 项目\n")
        // display: "项目\n"，内容起点 display 0
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(view.text(view, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(view.source, "项目\n", "Backspace 在项首只删 marker")
    }

    /// T11：heading 内容内行内格式命令，marker 字节不动（AC-01）。
    func testInlineFormatInsideHeadingKeepsMarker() {
        let view = makeView("## 标题\n")
        // display "标题\n"，选中 "题"
        view.setSelectedRange(NSRange(location: 0, length: 2))  // 选中 "标题"
        XCTAssertTrue(view.applyInlineFormat(.strong))
        XCTAssertEqual(view.source, "## **标题**\n", "heading marker 与内容字节精确")
        XCTAssertEqual(view.displayText, "标题\n")
    }

    /// T11：format 命令登记单一历史，undo 回 wrap 前字节。
    func testInlineFormatUndoRestoresBytes() {
        let view = makeView("词 其他\n")
        view.setSelectedRange(NSRange(location: 0, length: 1))
        XCTAssertTrue(view.applyInlineFormat(.emphasis))
        XCTAssertEqual(view.source, "*词* 其他\n")
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "词 其他\n")
    }

    // MARK: undo / redo（单一历史）

    func testUndoRedoTypingAndStructure() {
        let view = makeView("**AB**\n")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertText("X")
        XCTAssertEqual(view.source, "**AXB**\n")

        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "**AB**\n", "undo 恢复 typing 前 source")

        XCTAssertTrue(view.performRedo())
        XCTAssertEqual(view.source, "**AXB**\n", "redo 重放")
    }

    func testUndoRestoresAfterStructureCommand() {
        let view = makeView("- 一\n- 二\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(view.text(view, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(view.source, "- 一\n  - 二\n")

        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "- 一\n- 二\n", "结构命令 undo 恢复")
    }

    // MARK: 性能探针（AC-19 子集：200KiB/2k 行）

    func testLargeDocumentProbe() {
        // 确定性生成器（manifest stress_specs 的 200KiB/2k 行规格）
        var lines: [String] = []
        while lines.count < 2_100 || lines.joined().utf8.count < 210_000 {
            lines.append("行 \(lines.count) 压力样本 **加粗** 与 `code\(lines.count % 97)`。")
        }
        let large = lines.joined(separator: "\n") + "\n"

        let t0 = Date()
        let view = makeView(large)
        let build = Date().timeIntervalSince(t0)

        view.setSelectedRange(NSRange(location: 10, length: 0))
        let t1 = Date()
        view.insertText("字")
        let edit = Date().timeIntervalSince(t1)
        print("G0-PERF large=\(large.utf8.count)B lines=\(lines.count) build=\(build)s editSync=\(edit)s")

        XCTAssertGreaterThanOrEqual(large.utf8.count, 200 * 1024, "压力样本须 ≥200KiB")
        XCTAssertGreaterThanOrEqual(lines.count, 2_000, "压力样本须 ≥2k 行")
        // G0 预算：构建 < 2.0s、单次输入同步 < 2.5s（本机实测记录进 validation/G0）
        // 如果 build 超预算但 editSync 达标，记录 parse/storage 分解供 T05 lazy 渲染决策
        if build >= 2.0 {
            print("G0-PERF-WARN build over budget; T05 needs lazy/viewport rendering")
        }
        XCTAssertLessThan(edit, 2.5, "200KiB 单次输入同步预算")
    }
}

extension RichMarkdownEditingTests {
    /// G0 诊断：list 命令的 caret→item 定位链路。
    func testDebugListItemLocalization() {
        let view = makeView("- 一\n- 二\n- 三\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        print("G0DBG display=\(view.displayText.debugDescription) caret=2")
        // 直接检查 sourceCaret 与 currentListItem 的中间结果
        let mirror = Mirror(reflecting: view)
        _ = mirror
        let (caret, found) = view.debugListItemLocalization()
        print("G0DBG sourceCaret=\(caret) listItemFound=\(found) source=\(view.source.debugDescription)")
    }
}

// MARK: - T15 rich 面 fence token 上色(SPEC §8.1)

@MainActor
func testCodeFenceTokensAreColoredInRichProjection() {
    let view = RichMarkdownTextView(source: "```swift\nlet x = \"s\"\n```\n")
    view.contentTextColor = NSColor.black
    let ns = view.string as NSString
    let letRange = ns.range(of: "let")
    XCTAssertGreaterThan(letRange.location, 0, "'let' 应在 fence 块内")
    let color =
        view.textStorage?.attribute(
            .foregroundColor, at: letRange.location, effectiveRange: nil) as? NSColor
    XCTAssertNotNil(color)
    XCTAssertNotEqual(color, .black, "keyword 需有 token 色,不是正文基色")
    let strRange = ns.range(of: "\"s\"")
    let strColor =
        view.textStorage?.attribute(
            .foregroundColor, at: strRange.location, effectiveRange: nil) as? NSColor
    XCTAssertNotNil(strColor)
    XCTAssertNotEqual(strColor, .black, "string 需有 token 色")
}

@MainActor
func testLargeOrUnknownFenceStaysBaseStyle() {
    let big = String(repeating: "a", count: 3001)
    let view = RichMarkdownTextView(source: "```swift\n\(big)\n```\n")
    view.contentTextColor = NSColor.black
    let ns = view.string as NSString
    // 超限块:无 token 色,前景保持基色
    let color =
        view.textStorage?.attribute(
            .foregroundColor, at: ns.range(of: big).location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(color, .black, "超限 fence 应回基础样式")

    let unknown = RichMarkdownTextView(source: "```cobol\nMOVE 1 TO X\n```\n")
    unknown.contentTextColor = NSColor.black
    let n2 = unknown.string as NSString
    let c2 =
        unknown.textStorage?.attribute(
            .foregroundColor, at: n2.range(of: "MOVE").location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(c2, .black, "未知语言保持 plain code 样式")
}

// MARK: - T15 块级命令(语言更换/⌘Enter 退出块)

extension RichMarkdownEditingTests {

    @MainActor
    func testSetCodeFenceLanguageReplacesInfoStringAsSourceTransaction() {
        let view = RichMarkdownTextView(source: "```swift\nlet x = 1\n```\n")
        view.setSelectedRange(NSRange(location: 6, length: 0))  // fence 内容
        let revisionBefore = view.revision
        XCTAssertTrue(view.setCodeFenceLanguage("js"))
        XCTAssertEqual(view.source, "```js\nlet x = 1\n```\n", "info 串更换,内容与围栏不动")
        XCTAssertEqual(view.revision, revisionBefore + 1, "语言更换是一次 source 事务")
        XCTAssertTrue(view.performUndo(), "可单步撤销")
        XCTAssertEqual(view.source, "```swift\nlet x = 1\n```\n")
    }

    @MainActor
    func testSetCodeFenceLanguageFailsOutsideFence() {
        let view = RichMarkdownTextView(source: "plain text\n")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertFalse(view.setCodeFenceLanguage("js"), "fence 外不得改语言")
        XCTAssertEqual(view.source, "plain text\n")
    }

    @MainActor
    func testSetCodeFenceLanguageOnBareFenceInsertsInfo() {
        let view = RichMarkdownTextView(source: "```\ncode\n```\n")
        view.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertTrue(view.setCodeFenceLanguage("python"))
        XCTAssertEqual(view.source, "```python\ncode\n```\n")
    }

    @MainActor
    func testExitCodeBlockInsertsParagraphAfterFence() {
        let view = RichMarkdownTextView(source: "```swift\nlet x = 1\n```\ntail\n")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        let revisionBefore = view.revision
        XCTAssertTrue(view.exitCodeBlockAtCaret())
        XCTAssertEqual(
            view.source, "```swift\nlet x = 1\n```\n\ntail\n",
            "退出块 = 围栏后插空段落")
        XCTAssertEqual(view.revision, revisionBefore + 1)
        // caret 落在新段落:open fence + 内容 + close fence + 换行 + 1
        let expected = ("```swift\nlet x = 1\n```\n" as NSString).length + 1
        XCTAssertEqual(view.selectedRange().location, expected, "caret 应落在新空行")
        XCTAssertTrue(view.performUndo(), "单步撤销")
        XCTAssertEqual(view.source, "```swift\nlet x = 1\n```\ntail\n")
    }

    @MainActor
    func testExitCodeBlockFailsOutsideFence() {
        let view = RichMarkdownTextView(source: "plain\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertFalse(view.exitCodeBlockAtCaret())
        XCTAssertEqual(view.source, "plain\n")
    }
}
