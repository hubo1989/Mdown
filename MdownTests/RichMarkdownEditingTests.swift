import XCTest
@testable import Mdown

/// T04 / G0：RichMarkdownTextView 直接编辑（AppKit input protocol 路径）、
/// 结构命令、undo/redo、性能探针。
@MainActor
final class RichMarkdownEditingTests: XCTestCase {

    private func makeView(_ source: String) -> RichMarkdownTextView {
        let view = RichMarkdownTextView(source: source)
        // 挂到 window 确保文本输入协议在全量测试序列中稳定
        // （无 window 时 firstResponder 状态在测试顺序敏感场景下不确定）。
        // 持窗走 addTeardownBlock：tearDown 的覆写是 nonisolated
        // （XCTestCase 合同），在里面改 @MainActor 存储在 Swift 6
        // 下编译不过（CI Xcode 16.3；Xcode 27 的 Swift 5 模式放行）。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        addTeardownBlock { [weak window] in window?.close() }
        return view
    }

    // MARK: Tab Quick Input 菜单 action（WYSIWYG 面 First Responder 契约）

    func testInsertMenuActionsReachRichSurface() {
        let view = makeView("正文\n")
        // First Responder 契约:菜单 action 必须能在富面被命中(⌘ 菜单不会置灰)。
        for selector in [
            #selector(RichMarkdownTextView.insertTimeShortcut(_:)), #selector(RichMarkdownTextView.insertTableShortcut(_:)),
            #selector(RichMarkdownTextView.insertMathShortcut(_:)), #selector(RichMarkdownTextView.insertMathBlockShortcut(_:)),
            #selector(RichMarkdownTextView.insertImgShortcut(_:)), #selector(RichMarkdownTextView.insertVideoShortcut(_:)),
            #selector(RichMarkdownTextView.insertMarkmapShortcut(_:)), #selector(RichMarkdownTextView.insertMermaidShortcut(_:)),
            #selector(RichMarkdownTextView.insertPlantumlShortcut(_:)), #selector(RichMarkdownTextView.insertFoldShortcut(_:)),
            #selector(RichMarkdownTextView.insertTaskShortcut(_:)),
        ] {
            XCTAssertTrue(view.responds(to: selector), "\(selector) 必须实现于富面")
        }
    }

    func testInsertTableAndMermaidMenuActionsLandTemplates() {
        let table = makeView("正文\n")
        table.setSelectedRange(NSRange(location: 2, length: 0))
        table.insertTableShortcut(self)
        XCTAssertTrue(table.source.contains("|-----|"), "表格模板必须插进 source")

        let mermaid = makeView("正文\n")
        mermaid.setSelectedRange(NSRange(location: 2, length: 0))
        mermaid.insertMermaidShortcut(self)
        XCTAssertTrue(mermaid.source.contains("```mermaid"), "mermaid 模板必须插进 source")
    }

    func testInsertMathMenuActionsLandTemplates() {
        let inline = makeView("正文\n")
        inline.setSelectedRange(NSRange(location: 2, length: 0))
        inline.insertMathShortcut(self)
        XCTAssertTrue(inline.source.contains("$E = mc^2$"), "行内公式模板必须插进 source")

        let block = makeView("正文\n")
        block.setSelectedRange(NSRange(location: 2, length: 0))
        block.insertMathBlockShortcut(self)
        XCTAssertTrue(block.source.contains("$$\nE = mc^2\n$$"), "块级公式模板必须插进 source")
    }

    func testTypewriterAndFocusTogglesOnlyChangeViewState() {
        let view = makeView("第一行\n第二行\n")
        let revision = view.revision
        view.isTypewriterMode = true
        view.isFocusDimmingEnabled = true
        view.updateFocusDimming()
        XCTAssertEqual(view.revision, revision, "开关不得推进 revision(NE-37)")
        XCTAssertEqual(view.source, "第一行\n第二行\n", "开关不得改正文")
        view.isFocusDimmingEnabled = false
        view.updateFocusDimming()
        XCTAssertEqual(view.revision, revision, "关闭降噪同样只动 view state")
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

    // MARK: Quick Input 模板展开（PR #10 review F2：rich 面无 Tab 展开路径，
    // 字面 `/name` 会让 Quick Input 停在字面命令）

    /// 插入命令必须直接展开模板内容，与 source 模式 Tab 展开同语义；
    /// `{{select}}` 区间按模板语义选中（表头 plain 1:1 映射）。
    func testShortcutTemplateInsertsExpandedTableTemplate() {
        let view = makeView("正文\n\n段落\n")
        view.setSelectedRange(NSRange(location: 3, length: 0))  // "段落" 行首
        XCTAssertTrue(view.insertShortcutTemplate("table"))
        XCTAssertFalse(view.source.contains("/table"), "Quick Input 不得停在字面命令")
        XCTAssertTrue(view.source.contains("| 列1 | 列2 | 列3 |"), "表头必须展开")
        XCTAssertTrue(view.source.contains("|-----|-----|-----|"), "分隔行必须展开")
        let selection = view.selectedRange()
        XCTAssertEqual(selection.length, 2, "{{select}} 区间选中（source 模式展开语义）")
        XCTAssertEqual(
            (view.string as NSString).substring(with: selection), "列1",
            "选中内容必须是模板的 select span 而非附件占位")
    }

    /// `/time` 展开为时间文本（ShortcutTemplateManager 同一格式），
    /// caret 落模板末尾。
    func testShortcutTemplateInsertsExpandedTimeTemplate() {
        let view = makeView("记于\n")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(view.insertShortcutTemplate("time"))
        XCTAssertFalse(view.source.contains("/time"), "不得停留字面 `/time`")
        XCTAssertNotNil(
            view.source.range(
                of: #"^记于\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\n$"#,
                options: .regularExpression),
            "必须展开为 yyyy-MM-dd HH:mm:ss 时间文本")
    }

    /// Tab 展开斜杠命令(PR #10 follow-up:与源码面 Tab 行为对齐)。
    /// 走真实 delegate 路径(text(_:doCommandBy:)),旧代码在 rich 面
    /// 只会插入字面 Tab(`/time` 不展开)。
    func testTabKeyExpandsSlashShortcutOnRichSurface() throws {
        let source = "记于\n/time\n"
        let view = makeView(source)
        // "/time" 占 source[3,8):行尾(闭围栏 \n 前)是 8
        let caret = try XCTUnwrap(view.displayOffset(forSourceOffset: 8))
        view.setSelectedRange(NSRange(location: caret, length: 0))
        XCTAssertTrue(
            view.text(view, doCommandBy: NSSelectorFromString("insertTab:")),
            "Tab 应被展开消费")
        XCTAssertFalse(view.source.contains("/time"), "不得停留字面 `/time`")
        XCTAssertNotNil(
            view.source.range(
                of: #"^记于\n\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\n$"#,
                options: .regularExpression),
            "Tab 必须展开为时间模板")

        // 无斜杠命令时 Tab 不被吞,回落默认行为(返回 false)。
        let plain = makeView("普通段落\n")
        let plainCaret = try XCTUnwrap(plain.displayOffset(forSourceOffset: 4))  // 行尾
        plain.setSelectedRange(NSRange(location: plainCaret, length: 0))
        XCTAssertFalse(
            plain.text(plain, doCommandBy: NSSelectorFromString("insertTab:")),
            "无命令时 Tab 不得被吞")
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

// MARK: - T19 视觉排版(标题分级/行内样式/链接色/代码底色)

extension RichMarkdownEditingTests {

    @MainActor
    func testHeadingRendersLargerFont() {
        let view = RichMarkdownTextView(source: "# Title\n\nplain\n")
        let ns = view.string as NSString
        let title = ns.range(of: "Title")
        let font =
            view.textStorage?.attribute(
                .font, at: title.location, effectiveRange: nil) as? NSFont
        let bodyFont =
            view.textStorage?.attribute(
                .font, at: ns.range(of: "plain").location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(
            font?.pointSize ?? 0, (bodyFont?.pointSize ?? 0) * 1.3,
            "H1 字号应明显大于正文")
    }

    @MainActor
    func testStrongAndEmphasisRenderTraits() {
        let view = RichMarkdownTextView(source: "a **bold** b *ital* c ~~del~~ d\n")
        let ns = view.string as NSString
        let boldFont =
            view.textStorage?.attribute(
                .font, at: ns.range(of: "bold").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(
            boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true, "粗体内容应有 bold trait")
        let italFont =
            view.textStorage?.attribute(
                .font, at: ns.range(of: "ital").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(
            italFont?.fontDescriptor.symbolicTraits.contains(.italic) == true, "斜体内容应有 italic trait")
        let delStyle =
            view.textStorage?.attribute(
                .strikethroughStyle, at: ns.range(of: "del").location, effectiveRange: nil) as? Int
        XCTAssertEqual(delStyle, NSUnderlineStyle.single.rawValue, "删除线内容应有划线")
    }

    @MainActor
    func testLinkLabelRendersAccentColor() {
        let view = RichMarkdownTextView(source: "see [docs](https://example.com) here\n")
        let ns = view.string as NSString
        let label =
            view.textStorage?.attribute(
                .foregroundColor, at: ns.range(of: "docs").location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(label, view.previewLinkColour, "链接 label 应用预览链接色")
        let here =
            view.textStorage?.attribute(
                .foregroundColor, at: ns.range(of: "here").location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(here, view.contentTextColor, "普通文字不受影响")
    }

    @MainActor
    func testCodeFenceAndSpanGetBackground() {
        let view = RichMarkdownTextView(source: "x `c` y\n\n```\ncode\n```\n")
        let ns = view.string as NSString
        let spanBg = view.textStorage?.attribute(
            .backgroundColor, at: ns.range(of: "c").location, effectiveRange: nil)
        XCTAssertNotNil(spanBg, "code span 应有底色")
        let fenceBg = view.textStorage?.attribute(
            .backgroundColor, at: ns.range(of: "code").location, effectiveRange: nil)
        XCTAssertNotNil(fenceBg, "fence 内容应有底色")
    }

    @MainActor
    func testFocusDimmingKeepsInlineStylesFlat() {
        let view = RichMarkdownTextView(source: "a **bold** b\n\nc2\n")
        view.contentTextColor = NSColor.black
        view.isFocusDimmingEnabled = true
        view.setSelectedRange(NSRange(location: 11, length: 0))  // c2 块内
        view.updateFocusDimming()
        let ns = view.string as NSString
        let boldFont =
            view.textStorage?.attribute(
                .font, at: ns.range(of: "bold").location, effectiveRange: nil) as? NSFont
        // 非活跃块:字号 trait 可以在,但前景必须平色(不残留强调色/装饰)
        let color =
            view.textStorage?.attribute(
                .foregroundColor, at: ns.range(of: "bold").location, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(color, .black, "非活跃块降噪")
        XCTAssertEqual(color?.alphaComponent ?? 1, 0.4, accuracy: 0.01)
        _ = boldFont
    }
}

// MARK: - T19 预览对齐(字号/行高/颜色/列表缩进/属性残留)

extension RichMarkdownEditingTests {

    @MainActor
    func testHeadingScaleMatchesPreviewCSS() {
        let view = RichMarkdownTextView(source: "# a\n## b\n### c\n#### d\n")
        let ns = view.string as NSString
        let body = view.bodyFont.pointSize
        let scales: [(String, CGFloat)] = [("a", 2.0), ("b", 1.5), ("c", 1.25), ("d", 1.0)]
        for (word, scale) in scales {
            let font =
                view.textStorage?.attribute(
                    .font, at: ns.range(of: word).location, effectiveRange: nil) as? NSFont
            XCTAssertEqual(
                font?.pointSize ?? 0, body * scale, accuracy: 0.6,
                "H\(word) 字号应为正文 ×\(scale)(typography.css)")
        }
    }

    @MainActor
    func testUnwrapBoldRestoresBodyFont() {
        // 属性残留回归:wrap/unwrap 两次 display 不变(skip 分支),
        // 旧实现粗体 trait 留在同字节文本上。
        let view = RichMarkdownTextView(source: "word tail\n")
        view.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertTrue(view.applyInlineFormat(.strong))
        let ns = view.string as NSString
        let bold =
            view.textStorage?.attribute(
                .font, at: ns.range(of: "word").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true)

        view.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertTrue(view.applyInlineFormat(.strong))
        XCTAssertEqual(view.source, "word tail\n")
        let restored =
            view.textStorage?.attribute(
                .font, at: ns.range(of: "word").location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(restored, view.bodyFont, "unwrap 后同字节必须回正文字体")
    }

    @MainActor
    func testCodeBackgroundMatchesPreviewHex() {
        let view = RichMarkdownTextView(source: "`c`\n")
        let ns = view.string as NSString
        let bg =
            view.textStorage?.attribute(
                .backgroundColor, at: ns.range(of: "c").location, effectiveRange: nil) as? NSColor
        let expected = view.previewCodeBackground
        XCTAssertNotNil(bg)
        XCTAssertEqual(bg?.redComponent ?? -1, expected.redComponent, accuracy: 0.005)
        XCTAssertEqual(bg?.greenComponent ?? -1, expected.greenComponent, accuracy: 0.005)
        XCTAssertEqual(bg?.blueComponent ?? -1, expected.blueComponent, accuracy: 0.005)
    }

    @MainActor
    func testBaseLineHeightMatchesPreview() {
        let view = RichMarkdownTextView(source: "body\n")
        let ns = view.string as NSString
        let style =
            view.textStorage?.attribute(
                .paragraphStyle, at: ns.range(of: "body").location, effectiveRange: nil)
            as? NSParagraphStyle
        XCTAssertEqual(
            style?.lineHeightMultiple ?? 0, 1.74, accuracy: 0.01,
            "正文行高应为 1.74(typography.css)")
    }

    @MainActor
    func testListMarkerIndentsAndOrdinals() {
        let view = RichMarkdownTextView(source: "- a\n- b\n1. one\n2. two\n   - nested\n")
        let markers = view.computeListMarkers()
        XCTAssertEqual(markers.count, 5)
        XCTAssertEqual(markers[0].text, "•")
        XCTAssertEqual(markers[2].ordered, true)
        XCTAssertEqual(markers[2].ordinal, 1)
        XCTAssertEqual(markers[3].ordinal, 2)
        // 深度跟随 parser indentDepth 的整除规则(每 2 空格一级):
        // 3 空格缩进 = 深度 1(块模型同值;GFM 列对齐语义不另立标准)。
        XCTAssertEqual(markers[4].depth, 1, "嵌套项深度 = 缩进空格数/2(整除)")
        // headIndent 写进段落属性
        let ns = view.string as NSString
        let style =
            view.textStorage?.attribute(
                .paragraphStyle, at: ns.range(of: "a").location, effectiveRange: nil)
            as? NSParagraphStyle
        XCTAssertGreaterThan(style?.headIndent ?? 0, 0, "列表项应有 marker 缩进")
    }
}
