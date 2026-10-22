import XCTest

@testable import MiaoYan

/// Regression coverage for #543 "文件内容被错误替换": in preview-family modes
/// `EditTextView.note` follows the list selection while `textStorage` keeps the
/// previously edited note's bytes (fill() returns before the editor branch).
/// Whole-buffer persists that trusted `EditTextView.note` then wrote note X's
/// full text into note Y's file. `saveTextStorageContent` must refuse any save
/// whose target is not the storage owner recorded by `publishStorage`.
final class EditorStorageOwnershipTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiaoYanOwnershipTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    @MainActor
    private func makeNote(_ name: String, body: String) -> Note {
        let url = tempDir.appendingPathComponent(name)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        let project = Project(url: tempDir, label: "test", isRoot: true)
        let note = Note(url: url, with: project)
        note.content = NSMutableAttributedString(string: body)
        return note
    }

    @MainActor
    func testRefusesCrossNoteWholeBufferSave() {
        let noteA = makeNote("a.md", body: "AAA original")
        let noteB = makeNote("b.md", body: "BBB original")
        let editor = EditTextView(frame: .zero)

        // Simulate the preview-mode desync: buffer holds B while a save
        // targets A (Cmd+S / window-close / duplicate after a list switch).
        editor.publishStorage(NSAttributedString(string: "BBB original"), owner: noteB)
        editor.saveTextStorageContent(to: noteA)

        XCTAssertEqual(noteA.content.string, "AAA original", "cross-note save must be refused, not overwrite the target")
        XCTAssertEqual(noteB.content.string, "BBB original", "the buffer owner must stay untouched")
    }

    @MainActor
    func testAllowsSaveWhenOwnerMatches() {
        let noteB = makeNote("b.md", body: "BBB original")
        let editor = EditTextView(frame: .zero)

        editor.publishStorage(NSAttributedString(string: "BBB edited"), owner: noteB)
        editor.saveTextStorageContent(to: noteB)

        XCTAssertEqual(noteB.content.string, "BBB edited")
    }

    @MainActor
    func testAllowsSaveToDifferentInstanceWithSameURL() {
        // Ownership is keyed by file identity, not object identity, so a
        // reloaded Note instance for the same file must still be writable.
        let noteB1 = makeNote("b.md", body: "BBB original")
        let noteB2 = makeNote("b.md", body: "BBB original")
        let editor = EditTextView(frame: .zero)

        editor.publishStorage(NSAttributedString(string: "BBB edited"), owner: noteB1)
        editor.saveTextStorageContent(to: noteB2)

        XCTAssertEqual(noteB2.content.string, "BBB edited")
    }

    @MainActor
    func testRefusesSaveFromClearedBuffer() {
        let noteA = makeNote("a.md", body: "AAA original")
        let editor = EditTextView(frame: .zero)

        editor.publishStorage(NSAttributedString(), owner: nil)
        editor.saveTextStorageContent(to: noteA)

        XCTAssertEqual(noteA.content.string, "AAA original", "an ownerless (cleared) buffer must never be persisted")
    }

    @MainActor
    func testUploadPlaceholdersAreUniquePerUpload() {
        // A shared "![](uploading...)" literal let one upload's completion
        // match a placeholder in a different note's buffer and cross-write
        // full contents between files (#543).
        let first = ClipboardManager.makeUploadPlaceholder()
        let second = ClipboardManager.makeUploadPlaceholder()

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("![](uploading-"))
        XCTAssertTrue(first.hasSuffix("...)"))
    }

    /// T01 风险 #3：wysiwyg 模式下，Cmd+S / close / quit 硬保存点从
    /// source 编辑器 buffer 采集。owner 匹配（同一 note 从 source 切到
    /// wysiwyg 后 textStorage 停留在旧 v1）时，旧 v1 会覆盖 wysiwyg 后端已写进
    /// note.content 的 v2——用户输入丢失。修复前红：
    /// `editor.saveTextStorageContent(to: noteA)` 得到 v1。
    @MainActor
    func testHardSavePointMustNotOverwriteRichContentWithStaleSourceBuffer() {
        let noteA = makeNote("a.md", body: "v1")
        let editor = EditTextView(frame: .zero)
        let richHost = NativeRichEditorHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        // source 模式加载 A：buffer=v1，owner=A；切 wysiwyg 后 buffer 不变
        editor.publishStorage(NSAttributedString(string: "v1"), owner: noteA)
        // wysiwyg：后端加载 A 并收到合法 token 的用户编辑消息
        richHost.loadNote(noteA)
        // 模拟用户编辑:T14 整篇替换事务触发 onSourceCommitted 镜像
        _ = richHost.textView.applyWholeSourceReplacement("v2", name: "test-edit")
        XCTAssertEqual(noteA.content.string, "v2")

        // T08: 硬保存点统一入口（wysiwyg 活动时 rich 后端是权威）。
        let context = BackendCaptureStubContext(
            activeNote: noteA, sourceEditor: editor,
            richHost: richHost, isWysiwygActive: true)
        _ = EditingTransitionCoordinator().finishActiveEditing(
            in: context, forceCompositionFinish: false)

        XCTAssertEqual(
            noteA.content.string, "v2",
            "wysiwyg 活动时硬保存点不得用旧 source buffer 覆盖 rich 内容")
        XCTAssertFalse(richHost.hasUnsavedChanges, "flush 后 rich 后端不再挂起未保存状态")
    }

    /// 反向：非 wysiwyg 时硬保存点仍从 source 编辑器采集（owner guard 不变）。
    @MainActor
    func testCaptureBufferUsesSourceEditorWhenWysiwygInactive() {
        let noteA = makeNote("a.md", body: "v1")
        let editor = EditTextView(frame: .zero)

        editor.publishStorage(NSAttributedString(string: "v1 edited"), owner: noteA)
        // T08: 硬保存点统一入口（source 模式从编辑器采集，owner guard 不变）。
        let context = BackendCaptureStubContext(
            activeNote: noteA, sourceEditor: editor,
            richHost: nil, isWysiwygActive: false)
        _ = EditingTransitionCoordinator().finishActiveEditing(
            in: context, forceCompositionFinish: false)

        XCTAssertEqual(noteA.content.string, "v1 edited")
    }

    /// T05: 会话推进（watcher 重载/显式替换/formatter 等程序化路径）而
    /// buffer 停在旧 revision 时，整篇写回必须被拒——旧 v1 不得覆盖
    /// session/Note 已接受的 v2（PLAN §5 testSameOwnerStaleBufferCannotSave
    /// 的 source 模式形态）。
    @MainActor
    func testStaleBufferRevisionCannotWholeSave() {
        let noteA = makeNote("t05-stale.md", body: "v1")
        let editor = EditTextView(frame: .zero)

        // source 模式装载：buffer=v1，会话基线 rev0
        editor.publishStorage(NSAttributedString(string: "v1"), owner: noteA)
        XCTAssertEqual(editor.storageRevision, 0)
        let session = editor.editingSession
        XCTAssertNotNil(session, "publishStorage 必须建立源码会话")

        // 会话侧前进到 v2（commit 镜像同步进 Note；buffer 未重新 publish）
        noteA.content = NSMutableAttributedString(string: "v2")
        _ = session?.replaceAll(markdown: "v2")

        editor.saveTextStorageContent(to: noteA)

        XCTAssertEqual(noteA.content.string, "v2", "旧 buffer（rev0）不得整篇写回覆盖 rev1 内容")
    }

    /// 反向：正常输入路径不受防护误伤——buffer 与会话同处基线 revision
    /// 时（T05 输入不逐键 apply，双方都在 rev0），保存照常成功。
    @MainActor
    func testTypingThenSaveStillWorksUnderSessionGuard() {
        let noteA = makeNote("t05-typing.md", body: "v1")
        let editor = EditTextView(frame: .zero)

        editor.publishStorage(NSAttributedString(string: "v1"), owner: noteA)
        // 用户输入（textStorage 直接演进；会话 revision 不动）
        editor.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        editor.saveTextStorageContent(to: noteA)

        XCTAssertEqual(noteA.content.string, "xv1", "同 revision 的正常输入必须能保存")
    }

    /// publishStorage 对外发布内容时同步登记会话基线：模板/版本恢复等
    /// 整篇替换调用点无需各自维护 revision 元数据。
    @MainActor
    func testPublishStorageRebasesSessionAndKeepsGuardAligned() {
        let noteA = makeNote("t05-rebase.md", body: "v1")
        let editor = EditTextView(frame: .zero)

        editor.publishStorage(NSAttributedString(string: "v1"), owner: noteA)
        let firstSession = editor.editingSession

        // 整篇替换（模板路径形态）
        editor.publishStorage(NSAttributedString(string: "v2 template"), owner: noteA)

        XCTAssertIdentical(editor.editingSession, firstSession, "同 URL 复用会话")
        XCTAssertEqual(firstSession?.snapshot.markdown, "v2 template", "会话基线跟随发布内容")
        XCTAssertEqual(editor.storageRevision, firstSession?.revision, "buffer revision 与会话对齐")

        editor.saveTextStorageContent(to: noteA)
        XCTAssertEqual(noteA.content.string, "v2 template", "发布后的 buffer 保存不受防护拦截")
    }
}
