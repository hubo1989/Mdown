import XCTest
@testable import MiaoYan

/// T01: Vditor 桥契约测试。驱动真实 WKWebView + editor.html 循环。
final class VditorBridgeContractTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VditorBridge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory = tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    @MainActor
    private func makeTestNote(name: String, content: String) -> Note {
        let fileURL = tempDirectory.appendingPathComponent(name)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        let project = Project(url: tempDirectory, label: "TestProject", isTrash: false, isRoot: true)
        let note = Note(url: fileURL, with: project)
        note.content = NSMutableAttributedString(string: content)
        return note
    }

    /// 轮询 JS 谓词直到为真或超时。返回是否就绪。
    @MainActor
    private func waitForJS(_ view: VditorEditView, predicate: String, timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = try? await view.evaluateJavaScript(predicate)
            if let ready = result as? Bool, ready { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    @MainActor
    private func makeReadyEditor() async throws -> (VditorEditView, Note) {
        let view = VditorEditView()
        let note = makeTestNote(name: "bridge.md", content: "# Bridge\n\ninitial content")
        view.loadNote(note)

        // editorInstance 存在（didFinish → initEditor 已跑）
        let instanceReady = await waitForJS(view, predicate: "typeof editorInstance !== 'undefined'")
        XCTAssertTrue(instanceReady, "Vditor editorInstance 未在超时内创建（WKWebView 环境受阻时记录为环境阻塞）")
        // wysiwyg contenteditable 就绪；失败时 dump DOM 结构辅助定位
        let editableReady = await waitForJS(
            view,
            predicate: "!!document.querySelector('.vditor-wysiwyg [contenteditable=\"true\"]')"
        )
        if !editableReady {
            let dump = (try? await view.evaluateJavaScript(
                "document.querySelector('.vditor') ? document.querySelector('.vditor').innerHTML.slice(0, 400) : 'NO_VDITOR_ROOT'"
            ) as? String) ?? "dump-failed"
            XCTFail("wysiwyg contenteditable 未就绪；DOM dump: \(dump)")
        }
        return (view, note)
    }

    /// 契约：setMarkdown 程序化加载后，JS 侧读回一致（bridge 基本回路）。
    /// Vditor 序列化会为无末尾换行的文档追加单个 `\n`——该规范化行为在此固定。
    @MainActor
    func testSetMarkdownRoundTripsThroughEditor() async throws {
        let (view, note) = try await makeReadyEditor()
        let readBack = try await view.evaluateJavaScript("getMarkdown()") as? String
        let expected = note.content.string
        let normalized = readBack.map { $0.hasSuffix("\n") && !expected.hasSuffix("\n") ? String($0.dropLast()) : $0 }
        XCTAssertEqual(normalized, expected, "setMarkdown 后 JS getValue 应与 Note 内容一致（允许 Vditor 追加的末尾换行）")
    }

    /// T01 红：setMarkdown 的 100ms isUpdatingFromSwift 窗口内，真实用户输入
    /// 不得被当作程序化回声丢弃（vditorChange 必须到达 Swift 并更新 Note.content）。
    @MainActor
    func testUserInputDuringSetMarkdownWindowIsNotLost() async throws {
        let (view, note) = try await makeReadyEditor()

        // 触发 setMarkdown（等价 loadNote 重载同 note），紧接窗口内模拟真实用户输入。
        view.loadNote(note)

        let typedResult = try await view.evaluateJavaScript("""
        (function() {
            var editable = document.querySelector('.vditor-wysiwyg [contenteditable="true"]');
            editable.focus();
            var sel = window.getSelection();
            var range = document.createRange();
            range.selectNodeContents(editable);
            range.collapse(false);
            sel.removeAllRanges();
            sel.addRange(range);
            document.execCommand('insertText', false, 'X');
            return 'sent';
        })()
        """)
        let typed = try XCTUnwrap(typedResult as? String)
        XCTAssertEqual(typed, "sent")

        // 等 vditorChange 到达 Swift（最多 2s；正常应立即）。
        var noteContent = note.content.string
        let deadline = Date().addingTimeInterval(2)
        while !noteContent.contains("X") && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            noteContent = note.content.string
        }
        XCTAssertTrue(note.content.string.contains("X"),
                      "setMarkdown 窗口内的真实输入被 loading flag 丢弃，用户输入丢失（T01 风险 #1）")
    }

    /// 反向回归门：程序化 setMarkdown 不得产生假 vditorChange——
    /// Note.content、hasUnsavedChanges、磁盘文件三者在等待期后都必须不变
    /// （Vditor 序列化的末尾换行规范化不得写回）。
    @MainActor
    func testSetMarkdownDoesNotProduceSpuriousChangeOrDirty() async throws {
        let (view, note) = try await makeReadyEditor()
        let diskBefore = try String(contentsOf: note.url, encoding: .utf8)
        let contentBefore = note.content.string

        view.loadNote(note) // 同 note 重载 → applyNoteToEditor → setMarkdown

        try await Task.sleep(nanoseconds: 1_500_000_000) // 覆盖旧 0.5s debounce 窗口
        XCTAssertEqual(note.content.string, contentBefore, "程序化加载不得把回声/末尾换行写进 Note.content")
        XCTAssertFalse(view.hasUnsavedChanges, "程序化加载不得置 hasUnsavedChanges")
        let diskAfter = try String(contentsOf: note.url, encoding: .utf8)
        XCTAssertEqual(diskAfter, diskBefore, "程序化加载不得触发磁盘写")
    }

    /// T01 风险 #2：A 的 vditorChange 晚于 loadNote(B) 到达时，
    /// 消息不得套用 currentNote=B 写坏 B 的内容。stale token 与
    /// 无身份消息都必须拒绝。
    @MainActor
    func testLateChangeMessageDoesNotOverwriteSwitchedNote() throws {
        let view = VditorEditView()
        let noteA = makeTestNote(name: "late-a.md", content: "A 原始内容")
        let noteB = makeTestNote(name: "late-b.md", content: "B 原始内容")

        view.loadNote(noteA)
        view.loadNote(noteB) // postMessage 在途时切换
        XCTAssertEqual(view.currentNote?.url, noteB.url)

        // 模拟 A 的晚到消息（真实竞态中 JS postMessage 与 Swift 切换交错）
        view.handleContentChanged("A 的迟到编辑", token: view.currentLoadTokenValue - 1)
        view.handleContentChanged("无身份消息")

        XCTAssertEqual(noteB.content.string, "B 原始内容",
                       "晚到/无身份消息不得写进 B（消息缺少匹配身份即拒绝）")
    }
}
