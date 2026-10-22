import XCTest

@testable import MiaoYan

/// T14 (SPEC NE-28 / AC-14)：preview checkbox intent 的原生校验与转换。
///
/// preview 的 task 勾选不得再按全局 Note + DOM 序号直写(旧 HandlerCheckbox
/// 路径)。本套件固定：
/// 1. payload 解析——只接受有限 JSON(index/checked/generation),拒绝任意
///    Markdown / range 类消息;
/// 2. 纯 resolver——在权威 source 上定位第 n 个 task span(跳过代码块),
///    期望 state 失配 = stale 拒绝;
/// 3. 应用——经活动会话面(rich / source 编辑器)以 source patch 翻转,
///    caret/附件锚不扰动,一次撤销;
/// 4. 防线——非 main frame、presentation/PPT、generation 过期、笔记失配、
///    无活动面、Trash 只读全部拒绝且零写入。
final class PreviewEditIntentTests: XCTestCase {

    private var tempDir: URL!
    private var testWindow: NSWindow?

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiaoYanPreviewIntentTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        testWindow = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    @MainActor
    private func makeNote(
        named: String = "note.md", body: String, isTrash: Bool = false
    ) -> Note {
        let dir: URL = isTrash ? tempDir.appendingPathComponent("Trash") : tempDir
        if isTrash {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir.appendingPathComponent(named)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        let project = Project(url: dir, label: "test", isTrash: isTrash, isRoot: true)
        let note = Note(url: url, with: project)
        note.content = NSMutableAttributedString(string: body)
        note.markContentAsLoaded()
        return note
    }

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

    // MARK: - payload 解析（不接受任意消息）

    func testParsePayloadAcceptsFiniteJSONShape() {
        let payload = PreviewTaskIntent.parsePayload([
            "index": 2, "checked": true, "generation": 7,
        ])
        XCTAssertEqual(
            payload,
            PreviewTaskIntentPayload(index: 2, expectedChecked: true, renderGeneration: 7))
    }

    func testParsePayloadRejectsMarkdownAndRangeMessages() {
        XCTAssertNil(PreviewTaskIntent.parsePayload("# heading\n\n- [ ] injected"))
        XCTAssertNil(PreviewTaskIntent.parsePayload(["location": 3, "length": 5]))
        XCTAssertNil(PreviewTaskIntent.parsePayload("2"))
        XCTAssertNil(PreviewTaskIntent.parsePayload(["index": "not-a-number", "checked": true]))
        XCTAssertNil(PreviewTaskIntent.parsePayload(["index": -1, "checked": true]))
    }

    // MARK: - 纯 resolver：权威 source 上的第 n 个 task

    @MainActor
    func testResolverLocatesNthTaskSpanAcrossBlocks() {
        let source = "intro\n\n- [ ] one\n- [x] two\n- [ ] three\n"
        let plan = PreviewTaskIntent.planToggle(
            in: source, index: 1, expectedChecked: true)
        guard case .success(let toggle) = plan else {
            return XCTFail("index 1 应命中第二个 task,实际 \(plan)")
        }
        let ns = source as NSString
        XCTAssertEqual(ns.substring(with: toggle.sourceRange), "- [x]")
        XCTAssertEqual(toggle.expectedOld, "- [x]")
        XCTAssertEqual(toggle.replacement, "- [ ]")
    }

    @MainActor
    func testResolverSkipsTaskLookalikesInsideFencedCode() {
        let source = "```\n- [x] not a task\n```\n\n- [ ] real task\n"
        let plan = PreviewTaskIntent.planToggle(
            in: source, index: 0, expectedChecked: false)
        guard case .success(let toggle) = plan else {
            return XCTFail("fence 内的 - [x] 不得计数,实际 \(plan)")
        }
        let ns = source as NSString
        XCTAssertEqual(
            ns.substring(with: toggle.sourceRange).hasPrefix("- [ ]"), true,
            "必须命中 fence 外的真实 task")
    }

    @MainActor
    func testResolverRejectsIndexOutOfRange() {
        let result = PreviewTaskIntent.planToggle(in: "- [ ] one\n", index: 1, expectedChecked: false)
        guard case .failure(.indexOutOfRange) = result else {
            return XCTFail("越界 index 必须拒绝,实际 \(result)")
        }
    }

    @MainActor
    func testResolverRejectsStaleRenderedState() {
        // render 时是未勾选,source 已是勾选 → render 落后,拒绝
        let result = PreviewTaskIntent.planToggle(in: "- [x] one\n", index: 0, expectedChecked: false)
        guard case .failure(.staleContent) = result else {
            return XCTFail("期望 state 与 source 失配必须拒绝,实际 \(result)")
        }
    }

    // MARK: - 应用：经活动会话面翻转

    @MainActor
    func testAppliedIntentFlipsThroughRichSurfaceAndUpdatesMirror() {
        let source = "- [ ] alpha\n- [x] beta\n"
        let note = makeNote(body: source)
        let host = makeRichHost(body: source, note: note)
        host.textView.setSelectedRange(NSRange(location: 5, length: 0))

        let context = PreviewTaskIntentApplier.Context(
            surface: .rich(host),
            displayedNote: note,
            currentRenderGeneration: 3,
            interactivePreviewAllowed: true,
            isMainFrame: true
        )
        let payload = PreviewTaskIntentPayload(index: 1, expectedChecked: true, renderGeneration: 3)
        let rejection = PreviewTaskIntentApplier.apply(payload, in: context)
        XCTAssertNil(rejection, "合法 intent 必须应用,实际 \(String(describing: rejection))")

        XCTAssertEqual(host.textView.source, "- [ ] alpha\n- [ ] beta\n")
        XCTAssertEqual(
            note.content.string, "- [ ] alpha\n- [ ] beta\n",
            "翻转必须镜像进 note.content（preview 刷新源）")
        XCTAssertEqual(host.textView.selectedRange().location, 5, "不得移动编辑器 caret")
        XCTAssertTrue(host.textView.performUndo(), "preview 翻转必须可撤销")
        XCTAssertEqual(host.textView.source, source)
    }

    @MainActor
    func testAppliedIntentFlipsThroughSourceEditorBuffer() {
        let source = "- [ ] alpha\n"
        let note = makeNote(body: source)
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSAttributedString(string: source), owner: note)
        editor.setSelectedRange(NSRange(location: 8, length: 0))

        let context = PreviewTaskIntentApplier.Context(
            surface: .sourceEditor(editor, note),
            displayedNote: note,
            currentRenderGeneration: 1,
            interactivePreviewAllowed: true,
            isMainFrame: true
        )
        let payload = PreviewTaskIntentPayload(index: 0, expectedChecked: false, renderGeneration: 1)
        let rejection = PreviewTaskIntentApplier.apply(payload, in: context)
        XCTAssertNil(rejection)

        XCTAssertEqual(
            editor.textStorage?.string, "- [x] alpha\n",
            "翻转必须进活动编辑器 buffer（不得绕过 buffer 直写 Note）")
        // note.content 镜像由生产路径的 textDidChange delegate 完成，
        // 单测环境不接 delegate，此处只验证 buffer 语义。
    }

    // MARK: - 防线：全部拒绝且零写入

    @MainActor
    func testSubframeIntentIsRejected() {
        let source = "- [ ] alpha\n"
        let note = makeNote(body: source)
        let host = makeRichHost(body: source, note: note)

        let context = PreviewTaskIntentApplier.Context(
            surface: .rich(host),
            displayedNote: note,
            currentRenderGeneration: 1,
            interactivePreviewAllowed: true,
            isMainFrame: false
        )
        let payload = PreviewTaskIntentPayload(index: 0, expectedChecked: false, renderGeneration: 1)
        guard case .notMainFrame? = PreviewTaskIntentApplier.apply(payload, in: context) else {
            return XCTFail("子 frame intent 必须拒绝")
        }
        XCTAssertEqual(host.textView.source, source)
    }

    @MainActor
    func testPresentationModeIntentIsRejected() {
        let source = "- [ ] alpha\n"
        let note = makeNote(body: source)
        let host = makeRichHost(body: source, note: note)

        let context = PreviewTaskIntentApplier.Context(
            surface: .rich(host),
            displayedNote: note,
            currentRenderGeneration: 1,
            interactivePreviewAllowed: false,
            isMainFrame: true
        )
        let payload = PreviewTaskIntentPayload(index: 0, expectedChecked: false, renderGeneration: 1)
        guard case .modeForbidden? = PreviewTaskIntentApplier.apply(payload, in: context) else {
            return XCTFail("presentation/PPT 下 checkbox intent 必须拒绝")
        }
        XCTAssertEqual(host.textView.source, source)
    }

    @MainActor
    func testStaleGenerationIntentIsRejected() {
        let source = "- [ ] alpha\n"
        let note = makeNote(body: source)
        let host = makeRichHost(body: source, note: note)

        let context = PreviewTaskIntentApplier.Context(
            surface: .rich(host),
            displayedNote: note,
            currentRenderGeneration: 5,
            interactivePreviewAllowed: true,
            isMainFrame: true
        )
        // 页面还在报 generation 2 → 过期渲染
        let payload = PreviewTaskIntentPayload(index: 0, expectedChecked: false, renderGeneration: 2)
        guard case .staleRender? = PreviewTaskIntentApplier.apply(payload, in: context) else {
            return XCTFail("过期 generation 必须拒绝")
        }
        XCTAssertEqual(host.textView.source, source)
    }

    @MainActor
    func testMissingGenerationIsRejected() {
        let source = "- [ ] alpha\n"
        let note = makeNote(body: source)
        let host = makeRichHost(body: source, note: note)

        let context = PreviewTaskIntentApplier.Context(
            surface: .rich(host),
            displayedNote: note,
            currentRenderGeneration: 5,
            interactivePreviewAllowed: true,
            isMainFrame: true
        )
        let payload = PreviewTaskIntentPayload(index: 0, expectedChecked: false, renderGeneration: nil)
        guard case .staleRender? = PreviewTaskIntentApplier.apply(payload, in: context) else {
            return XCTFail("缺 generation（无法证明新鲜）必须拒绝")
        }
        XCTAssertEqual(host.textView.source, source)
    }

    @MainActor
    func testNoteMismatchIntentIsRejected() {
        let displayed = makeNote(body: "- [ ] alpha\n")
        let editing = makeNote(named: "editing.md", body: "- [ ] other\n")

        // 编辑面当前持有 displayed 之外的笔记时不得写入：用 sourceEditor 表达
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSAttributedString(string: "- [ ] other\n"), owner: editing)
        let mismatched = PreviewTaskIntentApplier.Context(
            surface: .sourceEditor(editor, editing),
            displayedNote: displayed,
            currentRenderGeneration: 1,
            interactivePreviewAllowed: true,
            isMainFrame: true
        )

        let payload = PreviewTaskIntentPayload(index: 0, expectedChecked: false, renderGeneration: 1)
        guard case .noteMismatch? = PreviewTaskIntentApplier.apply(payload, in: mismatched) else {
            return XCTFail("编辑面笔记与 preview 笔记失配必须拒绝")
        }
        XCTAssertEqual(editor.textStorage?.string, "- [ ] other\n")
    }

    @MainActor
    func testMissingSurfaceIntentIsRejected() {
        let note = makeNote(body: "- [ ] alpha\n")
        let context = PreviewTaskIntentApplier.Context(
            surface: nil,
            displayedNote: note,
            currentRenderGeneration: 1,
            interactivePreviewAllowed: true,
            isMainFrame: true
        )
        let payload = PreviewTaskIntentPayload(index: 0, expectedChecked: false, renderGeneration: 1)
        guard case .noEditableSurface? = PreviewTaskIntentApplier.apply(payload, in: context) else {
            return XCTFail("无可定位活动面必须拒绝（readonly 引导）")
        }
    }

    @MainActor
    func testTrashNoteIntentIsRejected() {
        let source = "- [ ] alpha\n"
        let note = makeNote(body: source, isTrash: true)
        let host = makeRichHost(body: source, note: note)

        let context = PreviewTaskIntentApplier.Context(
            surface: .rich(host),
            displayedNote: note,
            currentRenderGeneration: 1,
            interactivePreviewAllowed: true,
            isMainFrame: true
        )
        let payload = PreviewTaskIntentPayload(index: 0, expectedChecked: false, renderGeneration: 1)
        guard case .readOnly? = PreviewTaskIntentApplier.apply(payload, in: context) else {
            return XCTFail("Trash 笔记必须只读拒绝")
        }
        XCTAssertEqual(host.textView.source, source)
    }
}
