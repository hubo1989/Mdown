import XCTest

@testable import MiaoYan

/// T14 (SPEC NE-23 / NE-24 / NE-28 / AC-14)：命令 adapter 的路由注册表。
///
/// 覆盖四组行为：
/// 1. 路由判定——native rich 活动时内容命令走 rich source patch,绝不触碰
///    隐藏的 source 编辑器;source 布局时走 TextFormatter 同语义;preview /
///    presentation 一律拒绝;身份失配拒绝;Vditor legacy 返回 legacy 回退。
/// 2. rich 面命令原语——underline / link / todo / codeBlock / 快捷模板
///    的 source patch 语义(原子、可撤销、selection 映射)。
/// 3. find/replace——匹配锚在权威 source(含 frontmatter/ref 等不可见范围),
///    replace-all 一次事务一次撤销,大小写不敏感匹配按实际字节 patch。
/// 4. 整篇替换(format 通道)——单步 undo/redo,caret clamp。
final class MarkdownCommandRoutingTests: XCTestCase {

    private var tempDir: URL!
    private var testWindow: NSWindow?

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiaoYanCommandRoutingTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        testWindow = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    @MainActor
    private func makeNote(named: String = "note.md", body: String) -> Note {
        let url = tempDir.appendingPathComponent(named)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        let project = Project(url: tempDir, label: "test", isRoot: true)
        let note = Note(url: url, with: project)
        note.content = NSMutableAttributedString(string: body)
        note.markContentAsLoaded()
        return note
    }

    /// G0 同款:挂 window 保证 firstResponder / 文本协议稳定。
    @MainActor
    private func makeRichHost(body: String, note: Note) -> NativeRichEditorHostView {
        let host = NativeRichEditorHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        testWindow = window
        host.loadNote(note)
        return host
    }

    @MainActor
    private func makeEnvironment(
        surface: MarkdownEditorCommandAdapter.Environment.Surface,
        selectedNote: Note?,
        contentEditingForbidden: Bool = false
    ) -> MarkdownEditorCommandAdapter.Environment {
        MarkdownEditorCommandAdapter.Environment(
            surface: surface,
            selectedNote: selectedNote,
            contentEditingForbidden: contentEditingForbidden
        )
    }

    // MARK: - 路由判定（NE-24：命令只作用活动会话）

    @MainActor
    func testBoldOnNativeRichAppliesStrongPatchAndSkipsHiddenSourceEditor() {
        let note = makeNote(body: "plain word here")
        let host = makeRichHost(body: "plain word here", note: note)
        let hiddenEditor = EditTextView(frame: .zero)
        let hiddenNote = makeNote(named: "other.md", body: "hidden buffer")
        hiddenEditor.publishStorage(NSAttributedString(string: "hidden buffer"), owner: hiddenNote)

        host.textView.setSelectedRange(NSRange(location: 6, length: 4))  // "word"

        let env = makeEnvironment(surface: .nativeRich(host), selectedNote: note)
        let target = MarkdownEditorCommandAdapter.resolve(.bold, in: env)
        guard case .rich(let view) = target else {
            return XCTFail("native rich 活动时 bold 必须路由到 rich 面,实际 \(target)")
        }
        XCTAssertTrue(view === host.textView)
        XCTAssertTrue(MarkdownEditorCommandAdapter.perform(.bold, on: target))
        XCTAssertEqual(view.source, "plain **word** here", "命令必须以 source patch 落到活动会话")
        XCTAssertEqual(
            hiddenEditor.textStorage?.string, "hidden buffer",
            "rich 活动时不得触碰隐藏的 source 编辑器")
    }

    @MainActor
    func testBoldInSourceLayoutGoesThroughTextFormatter() {
        let note = makeNote(body: "plain word here")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSAttributedString(string: "plain word here"), owner: note)
        editor.setSelectedRange(NSRange(location: 6, length: 4))

        let env = makeEnvironment(surface: .sourceEditor(editor, note: note), selectedNote: note)
        let target = MarkdownEditorCommandAdapter.resolve(.bold, in: env)
        guard case .sourceEditor = target else {
            return XCTFail("source 布局时 bold 必须路由到 source 编辑器,实际 \(target)")
        }
        XCTAssertTrue(MarkdownEditorCommandAdapter.perform(.bold, on: target))
        XCTAssertEqual(editor.textStorage?.string, "plain **word** here")
    }

    @MainActor
    func testCommandRefusedInPreviewModeLeavesNoTrace() {
        let note = makeNote(body: "plain word here")
        let host = makeRichHost(body: "plain word here", note: note)

        let env = makeEnvironment(
            surface: .nativeRich(host), selectedNote: note, contentEditingForbidden: true)
        let target = MarkdownEditorCommandAdapter.resolve(.bold, in: env)
        guard case .refused = target else {
            return XCTFail("preview 模式下内容命令必须拒绝,实际 \(target)")
        }
        XCTAssertFalse(MarkdownEditorCommandAdapter.perform(.bold, on: target))
        XCTAssertEqual(host.textView.source, "plain word here", "拒绝后 source 不得变化")
        XCTAssertEqual(
            host.textView.revision, 1,
            "拒绝不得推进 revision(1 = 装载 setSource 的基线)")
    }

    @MainActor
    func testCommandRefusedWhenRichHostNoteMismatchesSelection() {
        let displayedNote = makeNote(body: "displayed")
        let selectedNote = makeNote(named: "selected.md", body: "selected")
        let host = makeRichHost(body: "displayed", note: displayedNote)

        let env = makeEnvironment(surface: .nativeRich(host), selectedNote: selectedNote)
        let target = MarkdownEditorCommandAdapter.resolve(.bold, in: env)
        guard case .refused = target else {
            return XCTFail("host 笔记与选中笔记失配必须拒绝,实际 \(target)")
        }
        XCTAssertEqual(host.textView.source, "displayed")
    }

    @MainActor
    func testLegacyVditorRoutingFallsBackToLegacyBehavior() {
        let note = makeNote(body: "plain")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSAttributedString(string: "plain"), owner: note)
        editor.setSelectedRange(NSRange(location: 0, length: 5))

        let env = makeEnvironment(
            surface: .legacyVditor(sourceEditor: editor, note: note), selectedNote: note)
        let target = MarkdownEditorCommandAdapter.resolve(.bold, in: env)
        guard case .legacyVditor = target else {
            return XCTFail("legacy Vditor 必须返回 legacy 回退路由,实际 \(target)")
        }
        // legacy 回退 = 既有 force-source 行为,由调用方执行;adapter 不写。
        XCTAssertEqual(editor.textStorage?.string, "plain")
    }

    // MARK: - rich 面命令原语（NE-24：与 TextFormatter 同语义）

    @MainActor
    func testUnderlineCommandWrapsThenUnwrapsSelection() {
        let note = makeNote(body: "plain word here")
        let host = makeRichHost(body: "plain word here", note: note)
        host.textView.setSelectedRange(NSRange(location: 6, length: 4))

        let env = makeEnvironment(surface: .nativeRich(host), selectedNote: note)
        XCTAssertTrue(MarkdownEditorCommandAdapter.perform(.underline, on: MarkdownEditorCommandAdapter.resolve(.underline, in: env)))
        XCTAssertEqual(host.textView.source, "plain <u>word</u> here")

        // 同区间再次执行 = unwrap（raw HTML 投影 1:1,选中完整标签对）
        host.textView.setSelectedRange(NSRange(location: 6, length: 11))
        XCTAssertTrue(MarkdownEditorCommandAdapter.perform(.underline, on: MarkdownEditorCommandAdapter.resolve(.underline, in: env)))
        XCTAssertEqual(host.textView.source, "plain word here")
    }

    @MainActor
    func testLinkCommandCreatesLabelAndTargetAnchor() {
        let note = makeNote(body: "plain word here")
        let host = makeRichHost(body: "plain word here", note: note)
        host.textView.setSelectedRange(NSRange(location: 6, length: 4))

        let env = makeEnvironment(surface: .nativeRich(host), selectedNote: note)
        XCTAssertTrue(MarkdownEditorCommandAdapter.perform(.link, on: MarkdownEditorCommandAdapter.resolve(.link, in: env)))
        XCTAssertEqual(host.textView.source, "plain [word]() here")
        // caret 落在 () 内等待输入 target（"plain [word]()" → ( 在 12、) 在 13）
        let selected = host.textView.selectedRange()
        XCTAssertEqual(
            (host.textView.source as NSString).substring(with: NSRange(location: 11, length: 2)),
            "](")
        XCTAssertEqual(
            selected.location, 10,
            "caret 映射到 label 末端(target 区间在 display 隐藏,输入落点正确)")
    }

    @MainActor
    func testTodoCommandInsertsThenFlipsTaskPrefix() {
        let note = makeNote(body: "plain item")
        let host = makeRichHost(body: "plain item", note: note)
        host.textView.setSelectedRange(NSRange(location: 3, length: 0))

        let env = makeEnvironment(surface: .nativeRich(host), selectedNote: note)
        XCTAssertTrue(MarkdownEditorCommandAdapter.perform(.todo, on: MarkdownEditorCommandAdapter.resolve(.todo, in: env)))
        XCTAssertEqual(host.textView.source, "- [ ] plain item")

        host.textView.setSelectedRange(NSRange(location: 10, length: 0))
        XCTAssertTrue(MarkdownEditorCommandAdapter.perform(.todo, on: MarkdownEditorCommandAdapter.resolve(.todo, in: env)))
        XCTAssertEqual(host.textView.source, "- [x] plain item")

        host.textView.setSelectedRange(NSRange(location: 10, length: 0))
        XCTAssertTrue(MarkdownEditorCommandAdapter.perform(.todo, on: MarkdownEditorCommandAdapter.resolve(.todo, in: env)))
        XCTAssertEqual(host.textView.source, "- [ ] plain item")
    }

    @MainActor
    func testCodeBlockCommandWrapsSelectionInFence() {
        let note = makeNote(body: "selected body text")
        let host = makeRichHost(body: "selected body text", note: note)
        host.textView.setSelectedRange(NSRange(location: 0, length: 13))

        let env = makeEnvironment(surface: .nativeRich(host), selectedNote: note)
        XCTAssertTrue(MarkdownEditorCommandAdapter.perform(.codeBlock, on: MarkdownEditorCommandAdapter.resolve(.codeBlock, in: env)))
        XCTAssertEqual(
            host.textView.source, "```\nselected body\n```\n text",
            "选区外的剩余文本（含空格）原样保留")
        // caret 在开 fence 之后（与 source 模式 insertCodeBlock 落点一致）
        XCTAssertEqual(host.textView.selectedRange().location, 4)
    }

    @MainActor
    func testInsertCodeSpanCommandWrapsSelection() {
        let note = makeNote(body: "plain word here")
        let host = makeRichHost(body: "plain word here", note: note)
        host.textView.setSelectedRange(NSRange(location: 6, length: 4))

        let env = makeEnvironment(surface: .nativeRich(host), selectedNote: note)
        XCTAssertTrue(MarkdownEditorCommandAdapter.perform(.inlineCode, on: MarkdownEditorCommandAdapter.resolve(.inlineCode, in: env)))
        XCTAssertEqual(host.textView.source, "plain `word` here")
    }

    @MainActor
    func testShortcutTemplateInsertsLiteralAtCaret() {
        let note = makeNote(body: "plain text")
        let host = makeRichHost(body: "plain text", note: note)
        host.textView.setSelectedRange(NSRange(location: 5, length: 0))

        let env = makeEnvironment(surface: .nativeRich(host), selectedNote: note)
        XCTAssertTrue(
            MarkdownEditorCommandAdapter.perform(
                .insertShortcutTemplate("time"),
                on: MarkdownEditorCommandAdapter.resolve(.insertShortcutTemplate("time"), in: env)))
        XCTAssertEqual(host.textView.source, "plain/time text")
    }

    @MainActor
    func testEveryCommandInRegistryResolvesWithoutCrashOnRichSurface() {
        let note = makeNote(body: "word")
        let host = makeRichHost(body: "word", note: note)
        let env = makeEnvironment(surface: .nativeRich(host), selectedNote: note)
        for command in MarkdownEditorCommandAdapter.Command.allCases {
            _ = MarkdownEditorCommandAdapter.resolve(command, in: env)
        }
    }

    // MARK: - find/replace（NE-23：匹配锚在 source,一次可撤销事务）

    @MainActor
    func testFindMatchesAreSourceAnchoredIncludingInvisibleRanges() {
        // frontmatter 与正文均含 query：匹配必须覆盖不可见的 frontmatter
        let source = "---\ntitle: FindMe note\n---\n\nbody FindMe tail\n"
        let note = makeNote(body: source)
        let host = makeRichHost(body: source, note: note)

        let matches = host.textView.sourceMatches(for: "FindMe")
        XCTAssertEqual(matches.count, 2, "frontmatter 与正文都应命中")
        let ns = source as NSString
        for range in matches {
            XCTAssertEqual(
                ns.substring(with: range).compare("FindMe", options: .caseInsensitive),
                .orderedSame, "匹配区间必须锚在 source 实际字节")
        }
    }

    @MainActor
    func testReplaceAllIsSingleUndoableTransaction() {
        let source = "a hit b hit c"
        let note = makeNote(body: source)
        let host = makeRichHost(body: source, note: note)
        let revisionBefore = host.textView.revision

        let replaced = host.textView.replaceAllMatches(query: "hit", replacement: "miss")
        XCTAssertEqual(replaced, 2)
        XCTAssertEqual(host.textView.source, "a miss b miss c")
        XCTAssertEqual(host.textView.revision, revisionBefore + 1, "replace-all 只推进一次 revision")

        XCTAssertTrue(host.textView.performUndo(), "replace-all 必须单步撤销")
        XCTAssertEqual(host.textView.source, source, "单次 undo 回到原文")
        XCTAssertTrue(host.textView.performRedo(), "redo 重放整次替换")
        XCTAssertEqual(host.textView.source, "a miss b miss c")
    }

    @MainActor
    func testReplaceAllCaseInsensitiveUsesActualMatchedBytes() {
        let source = "X marks x marks X"
        let note = makeNote(body: source)
        let host = makeRichHost(body: source, note: note)

        let replaced = host.textView.replaceAllMatches(query: "x", replacement: "y")
        XCTAssertEqual(replaced, 3)
        XCTAssertEqual(host.textView.source, "y marks y marks y")
    }

    @MainActor
    func testReplaceNextReplacesSingleMatchAndKeepsSecond() {
        let source = "one two one"
        let note = makeNote(body: source)
        let host = makeRichHost(body: source, note: note)

        let replaced = host.textView.replaceNextMatch(query: "one", replacement: "1")
        XCTAssertEqual(replaced, 1)
        XCTAssertEqual(host.textView.source, "1 two one")
    }

    @MainActor
    func testDisplayRangeMapsSourceRangeWithinBlock() {
        let source = "plain **bold** tail"
        let note = makeNote(body: source)
        let host = makeRichHost(body: source, note: note)

        XCTAssertEqual(host.textView.string, "plain bold tail")
        let display = host.textView.displayRange(forSourceRange: NSRange(location: 8, length: 4))
        XCTAssertNotNil(display, "块内 source 区间必须可映射到 display")
        // display 中 "**bold**" 的 marker 隐藏,但 bold 一词仍在
        let selected = display.map { (host.textView.string as NSString).substring(with: $0) }
        XCTAssertEqual(selected, "bold")
    }

    // MARK: - 整篇替换（format 通道）

    @MainActor
    func testWholeSourceReplacementIsOneUndoStepWithCaretClamp() {
        let source = "line1\nline2"
        let note = makeNote(body: source)
        let host = makeRichHost(body: source, note: note)
        host.textView.setSelectedRange(NSRange(location: 3, length: 0))

        let revisionBefore = host.textView.revision
        let applied = host.textView.applyWholeSourceReplacement("line1 formatted\nline2", name: "format")
        XCTAssertTrue(applied)
        XCTAssertEqual(host.textView.source, "line1 formatted\nline2")
        XCTAssertEqual(host.textView.revision, revisionBefore + 1, "整篇替换只推进一次 revision")

        XCTAssertTrue(host.textView.performUndo())
        XCTAssertEqual(host.textView.source, source, "format 必须单步可撤销")
        XCTAssertTrue(host.textView.performRedo())

        // caret 越界时 clamp 到 display 末尾,不崩溃
        host.textView.setSelectedRange(NSRange(location: (host.textView.string as NSString).length, length: 0))
        _ = host.textView.applyWholeSourceReplacement("x", name: "format")
        XCTAssertLessThanOrEqual(
            host.textView.selectedRange().location, (host.textView.string as NSString).length)
    }

    // MARK: - preview intent 的 span 级 toggle（NE-28 原生校验后的命令）

    @MainActor
    func testTaskToggleByExactSpanFlipsAndIsUndoable() {
        let source = "- [ ] alpha\n- [x] beta\n"
        let note = makeNote(body: source)
        let host = makeRichHost(body: source, note: note)
        host.textView.setSelectedRange(NSRange(location: 2, length: 0))  // 用户 caret 在首行

        let ns = source as NSString
        let betaRange = ns.range(of: "- [x]")
        let applied = host.textView.applyTaskTogglePatch(
            sourceRange: betaRange, expectedOld: "- [x]", replacement: "- [ ]")
        XCTAssertTrue(applied)
        XCTAssertEqual(host.textView.source, "- [ ] alpha\n- [ ] beta\n")
        XCTAssertEqual(
            host.textView.selectedRange().location, 2, "preview 翻转不得移动编辑器 caret")

        XCTAssertTrue(host.textView.performUndo(), "preview intent 必须可撤销")
        XCTAssertEqual(host.textView.source, source)
    }

    @MainActor
    func testTaskToggleBySpanRejectsWrongExpectedBytes() {
        let source = "- [ ] alpha\n"
        let note = makeNote(body: source)
        let host = makeRichHost(body: source, note: note)

        let ns = source as NSString
        let range = ns.range(of: "- [ ]")
        let applied = host.textView.applyTaskTogglePatch(
            sourceRange: range, expectedOld: "- [x]", replacement: "- [ ]")
        XCTAssertFalse(applied, "期望字节失配必须拒绝（stale render 防护）")
        XCTAssertEqual(host.textView.source, source)
    }
}
