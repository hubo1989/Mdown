import XCTest

@testable import MiaoYan

/// T09 (SPEC §7.3 / NE-16 / NE-19 / NE-20 / AC-08 / AC-09)：watcher、rename、
/// Trash、版本恢复与异步附件的 generation 接线。
///
/// 覆盖四组行为：
/// 1. watcher 外部 reload 的 dirty 判定——无本地改动走全量替换；有本地
///    dirty 时保留双方、不清 history/不覆盖 buffer；
/// 2. rename/move/同 URL 新实例的 rebind——generation 提升后旧捕获失效；
/// 3. Trash/退役后一切写路径拒绝，不复活删除文件；
/// 4. 版本恢复与异步附件结果绑定捕获身份，迟到/锚点删除不污染正文。
final class EditorFileSyncTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiaoYanEditorFileSyncTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // 失败注入可能把目录留在只读态；恢复后清理。
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    @MainActor
    private func makeNote(named: String = "note.md", body: String = "orig") -> Note {
        let url = tempDir.appendingPathComponent(named)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        let project = Project(url: tempDir, label: "test", isRoot: true)
        let note = Note(url: url, with: project)
        note.content = NSMutableAttributedString(string: body)
        return note
    }

    // MARK: - watcher reload：无 dirty 走全量替换

    /// watcher 无本地改动的重载必须把 session 代际推进（旧 buffer / 旧任务
    /// 身份失效），否则旧 buffer 的整篇写回会把已接受的磁盘版本覆盖回旧值。
    @MainActor
    func testWatcherReloadWithoutDirtyRebasesSessionGeneration() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSAttributedString(string: "v1"), owner: note)

        // 外部把磁盘改成 v2（模拟另一台设备 / 外部编辑器的写入）。
        try "v2 external".write(to: note.url, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(editor.editingSession)
        let before = session.snapshot.identity.generation
        XCTAssertTrue(
            editor.applyExternalFileChange("v2 external", owner: note),
            "无 dirty 时 watcher 变化必须重载")

        XCTAssertEqual(session.snapshot.identity.generation, before + 1, "无 dirty 重载必须提升代际")
        XCTAssertEqual(session.snapshot.markdown, "v2 external", "会话基线必须是磁盘真值")
        XCTAssertEqual(editor.storageRevision, session.revision, "buffer 重新发布后 revision 对齐")
        XCTAssertFalse(session.storageIsStale, "重新发布的 buffer 不得被防护拦截")
    }

    /// 无 dirty 重载不得登记 undo——程序化装载不是用户编辑（SPEC §5.4）。
    @MainActor
    func testWatcherReloadDoesNotRegisterUndo() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSAttributedString(string: "v1"), owner: note)
        try "v2 external".write(to: note.url, atomically: true, encoding: .utf8)

        // 经 editor 的 T09 入口（buffer 重新发布路径）。
        _ = editor.applyExternalFileChange("v2 external", owner: note)

        XCTAssertFalse(note.undoManager.canUndo, "程序化重载不得进入 undo 栈")
    }

    // MARK: - watcher reload：有 dirty 保留双方

    /// 有本地 dirty 时 watcher 不得覆盖 session/Note 正文：磁盘外部版本与
    /// 本地草稿两份都保留，不清 history、不把旧草稿写死到会话里（NE-19）。
    @MainActor
    func testWatcherReloadWithDirtyKeepsBothVersions() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSAttributedString(string: "v1"), owner: note)

        // 本地草稿（已 commit，等待 debounce / 立即 flush）。
        note.commit(content: NSMutableAttributedString(string: "local draft"))
        let session = try XCTUnwrap(editor.editingSession)
        let before = session.snapshot.identity.generation

        try "v2 external".write(to: note.url, atomically: true, encoding: .utf8)
        XCTAssertFalse(session.reloadFromDisk(externalContent: "v2 external", hasLocalChanges: true), "dirty 时不得自动重载覆盖本地草稿")

        XCTAssertEqual(
            session.snapshot.identity.generation, before,
            "保留双方时不得推进代际——用户草稿仍是会话权威")
        XCTAssertEqual(session.snapshot.markdown, "v1", "会话基线保持原样")
        XCTAssertEqual(note.content.string, "local draft", "本地草稿必须保留")
    }

    /// dirty 时保留双方的同时，外部版本必须被记录下来供用户选择（不静默
    /// 丢弃，也不自动三方合并）。
    @MainActor
    func testWatcherReloadWithDirtyRecordsExternalSnapshot() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSAttributedString(string: "v1"), owner: note)
        note.commit(content: NSMutableAttributedString(string: "local draft"))
        let session = try XCTUnwrap(editor.editingSession)

        try "v2 external".write(to: note.url, atomically: true, encoding: .utf8)
        XCTAssertFalse(
            editor.applyExternalFileChange("v2 external", owner: note),
            "dirty 时不得自动覆盖本地草稿")

        XCTAssertEqual(
            session.pendingExternalContent, "v2 external",
            "外部版本必须被记录，不得静默丢弃")
        XCTAssertEqual(
            session.snapshot.markdown, "v1",
            "会话基线仍是本地草稿对应的版本（保留双方）")
    }

    /// 显式接受外部版本（local recovery trigger，不是保存成功）后：代际
    /// 推进、基线换成磁盘真值、buffer 重新发布，旧草稿不再可写回。
    @MainActor
    func testAdoptExternalVersionRebasesAndDropsStaleBuffer() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSAttributedString(string: "v1"), owner: note)
        note.commit(content: NSMutableAttributedString(string: "local draft"))
        let session = try XCTUnwrap(editor.editingSession)
        try "v2 external".write(to: note.url, atomically: true, encoding: .utf8)
        _ = editor.applyExternalFileChange("v2 external", owner: note)
        XCTAssertEqual(session.pendingExternalContent, "v2 external", "前置：外部版本已保留")

        XCTAssertTrue(editor.adoptPendingExternalVersion(owner: note), "显式接受外部版本必须成功")

        XCTAssertEqual(session.snapshot.markdown, "v2 external")
        XCTAssertNil(session.pendingExternalContent, "接受后待处理外部版本必须清空")
        XCTAssertFalse(session.storageIsStale, "重新发布后 buffer 不得被拦截")
    }

    // MARK: - rename / move / 同 URL 新实例 rebind

    /// rename/move 必须更新 canonical URL 并提升代际：旧身份捕获的编辑与
    /// 写结果全部失效，不按 URL 相等继续写（NE-20）。
    @MainActor
    func testRenameAdvancesGenerationAndInvalidatesOldIdentity() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSMutableAttributedString(string: "v1"), owner: note)
        let session = try XCTUnwrap(editor.editingSession)

        let stale = session.currentJobContext
        let newURL = tempDir.appendingPathComponent("renamed.md")
        session.rename(to: newURL)

        XCTAssertEqual(session.snapshot.identity.canonicalURL, newURL)
        XCTAssertEqual(session.snapshot.identity.generation, stale.generation + 1)
        XCTAssertFalse(session.accepts(resultFor: stale), "改名后旧任务身份必须失效")
        XCTAssertFalse(session.owns(url: note.url), "旧 URL 不再被会话拥有")
    }

    /// 同 URL 的新 Note 实例回流（legacy 允许行为）：保留 ownerToken、
    /// 提升代际、正文重置为传入基线，旧 buffer 不得覆盖新实例内容。
    @MainActor
    func testSameURLNewInstanceRebindKeepsOwnerToken() throws {
        let note1 = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSMutableAttributedString(string: "v1"), owner: note1)
        let session = try XCTUnwrap(editor.editingSession)

        // 文件系统变化后 storage 为同一 URL 建了新实例（磁盘已是 v2）。
        try "v2 disk".write(to: note1.url, atomically: true, encoding: .utf8)
        let note2 = makeNote(body: "v2 disk")

        let ownerBefore = session.snapshot.identity.ownerToken
        let generationBefore = session.snapshot.identity.generation
        XCTAssertTrue(session.rebind(url: note2.url, markdown: "v2 disk"))

        XCTAssertEqual(session.snapshot.identity.ownerToken, ownerBefore, "ownerToken 复用")
        XCTAssertEqual(session.snapshot.identity.generation, generationBefore + 1, "代际必须提升")
        XCTAssertEqual(session.snapshot.markdown, "v2 disk")
        XCTAssertTrue(session.storageIsStale, "rebind 后旧 buffer 不得通过保存防护")
    }

    /// rename/move 后 editor 侧同步：代际提升、buffer 身份重新对齐，使改名后
    /// 的第一次正常保存不被 revision guard 误伤（NE-20 的 buffer 侧对端）。
    @MainActor
    func testSyncSessionAfterRenameAdvancesGenerationAndKeepsSaveWorking() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSMutableAttributedString(string: "v1"), owner: note)
        let session = try XCTUnwrap(editor.editingSession)
        let stale = session.currentJobContext

        // 磁盘改名成功（Note.overwrite/move 已把 note.url 指向新位置）。
        let newURL = tempDir.appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: note.url, to: newURL)
        note.overwrite(url: newURL)

        XCTAssertTrue(editor.syncSessionAfterRename(of: note), "改名后必须同步会话 URL")

        XCTAssertEqual(session.canonicalURL, newURL)
        XCTAssertFalse(session.accepts(resultFor: stale), "改名后旧身份捕获必须失效")
        XCTAssertFalse(session.storageIsStale, "同步后 buffer 不得被误判为陈旧")

        // 改名后继续输入并保存：正常路径不能被防护挡住。
        editor.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "after-rename ")
        editor.saveTextStorageContent(to: note)
        XCTAssertEqual(note.content.string, "after-rename v1")
    }

    /// URL 未变时（重复调用 / 大小写改名已被 Note 处理）不得无谓推进代际：
    /// 否则每次调用都会让在途任务白死。
    @MainActor
    func testSyncSessionAfterRenameIsNoOpWhenURLUnchanged() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSMutableAttributedString(string: "v1"), owner: note)
        let session = try XCTUnwrap(editor.editingSession)
        let before = session.snapshot.identity.generation

        XCTAssertTrue(editor.syncSessionAfterRename(of: note))
        XCTAssertEqual(
            session.snapshot.identity.generation, before,
            "URL 未变不得推进代际")
    }

    // MARK: - Trash / 退役

    /// 退役后 session 拒绝一切编辑与写回，Note 侧写路径同样拒绝：不复活
    /// 已删除文件（AC-08）。
    @MainActor
    func testRetiredNoteRejectsEveryWritePath() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSMutableAttributedString(string: "v1"), owner: note)
        let session = try XCTUnwrap(editor.editingSession)

        note.retireAfterRemoval()
        // 保存防护在 Note 退役时把源码会话一并退役（EditTextView+EditingSession）。
        editor.saveTextStorageContent(to: note)

        XCTAssertEqual(note.saveReturningOutcome(globalStorage: false), .retired)
        XCTAssertEqual(note.flushPendingSaveOutcome(globalStorage: false), .retired)
        XCTAssertFalse(session.owns(url: note.url), "绑定 note 退役后会话不得再声称拥有该 URL")

        // 再经 buffer 路径尝试整篇写回：已退役会话必须拒绝。
        editor.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: editor.textStorage!.length), with: "post-retire")
        editor.saveTextStorageContent(to: note)
        XCTAssertEqual(note.content.string, "v1", "退役 note 不得被 buffer 写回污染")

        let selection = MarkdownSelection(anchorUTF16: 0, focusUTF16: 0, affinity: .downstream)
        let transaction = EditTransaction(
            identity: session.currentJobContext.identity,
            expectedRevision: session.revision,
            patches: [],
            selectionBefore: selection, selectionAfter: selection,
            origin: .typing, undoGroupID: UUID()
        )
        guard case .rejected(.retired) = session.apply(transaction) else {
            return XCTFail("退役会话不得再接受编辑事务")
        }
    }

    /// 退役后已删除文件的路径不得被保存重建（Note.removeFile 语义的写侧
    /// 对端：saveReturningOutcome 在 missing file 且非初始创建时失败）。
    @MainActor
    func testRetiredNoteDoesNotRecreateRemovedFile() throws {
        let note = makeNote(body: "v1")
        note.commit(content: NSMutableAttributedString(string: "draft"))
        try FileManager.default.removeItem(at: note.url)

        note.retireAfterRemoval()
        _ = note.flushPendingSave(globalStorage: false)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: note.url.path),
            "退役笔记的 flush 不得重建已删除文件")
    }

    // MARK: - 版本恢复

    /// 版本恢复是显式 source replacement：代际提升、正文换成恢复版本、
    /// buffer 重新发布，旧 buffer 不得把恢复前内容写回（SPEC §7.3）。
    @MainActor
    func testVersionRestoreIsExplicitReplacementTransaction() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSMutableAttributedString(string: "v1"), owner: note)
        let session = try XCTUnwrap(editor.editingSession)
        let before = session.snapshot.identity.generation

        XCTAssertTrue(
            editor.applyRestoredVersion("old version body", owner: note),
            "版本恢复必须经 editor 的显式替换入口")

        XCTAssertEqual(session.snapshot.markdown, "old version body")
        XCTAssertEqual(session.snapshot.identity.generation, before + 1)
        XCTAssertEqual(editor.storageRevision, session.revision, "恢复后 buffer 重新发布")
        XCTAssertFalse(session.storageIsStale)
    }

    /// 恢复前登记在 note.undoManager 上的动作必须被清空：Cmd-Z 不得把恢复
    /// 前的正文带回编辑器（reloadNote 的同类防护，见 FileSystemEventManager）。
    @MainActor
    func testVersionRestoreWipesStaleUndoHistory() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSMutableAttributedString(string: "v1"), owner: note)

        // 恢复前用户有过编辑。EditTextView 的 view 自动 undo 经
        // windowWillReturnUndoManager 路由到 note.undoManager（生产路径），
        // 脱离 window 的测试直接在 note 的 manager 上登记等价状态。
        note.undoManager.registerUndo(withTarget: note) { _ in }
        XCTAssertTrue(note.undoManager.canUndo, "前置：恢复前必须有可撤销动作")

        XCTAssertTrue(editor.applyRestoredVersion("restored body", owner: note))

        XCTAssertFalse(note.undoManager.canUndo, "恢复后旧 undo 动作不得再作用到新基线")
    }

    /// 恢复后的 buffer 保存必须写入恢复版本，不是恢复前内容。
    @MainActor
    func testSaveAfterRestorePersistsRestoredVersion() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSMutableAttributedString(string: "v1"), owner: note)
        let session = try XCTUnwrap(editor.editingSession)

        XCTAssertTrue(editor.applyRestoredVersion("restored body", owner: note))
        // buffer 已是恢复版本；saveTextStorageContent 走 owner + revision 防护。
        editor.saveTextStorageContent(to: note)

        XCTAssertEqual(note.content.string, "restored body")
    }

    // MARK: - 异步附件 / 上传结果绑定

    /// 上传结果携带捕获的身份快照；会话代际已推进（切笔记 / 重载）时
    /// 结果必须被拒，不得插进当前 buffer（NE-22）。
    @MainActor
    func testLateUploadResultRejectedAfterGenerationAdvance() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSMutableAttributedString(string: "v1"), owner: note)
        let session = try XCTUnwrap(editor.editingSession)

        let captured = session.currentJobContext
        // 上传在途时 watcher 重载推进了代际。
        try "v2 external".write(to: note.url, atomically: true, encoding: .utf8)
        _ = editor.applyExternalFileChange("v2 external", owner: note)

        XCTAssertFalse(session.accepts(resultFor: captured), "迟到的上传结果必须被拒绝")
    }

    /// 同代际同 revision 的结果必须被接受——正常路径不能误伤。
    @MainActor
    func testFreshUploadResultAcceptedAtSameIdentity() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSMutableAttributedString(string: "v1"), owner: note)
        let session = try XCTUnwrap(editor.editingSession)

        XCTAssertTrue(session.accepts(resultFor: session.currentJobContext))
    }

    /// 上传在途时笔记被改名：上传结果绑定的是旧 URL，必须被拒（NE-22）。
    @MainActor
    func testUploadResultRejectedAfterRename() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSMutableAttributedString(string: "v1"), owner: note)
        let session = try XCTUnwrap(editor.editingSession)
        let captured = session.currentJobContext

        let newURL = tempDir.appendingPathComponent("renamed-upload.md")
        try FileManager.default.moveItem(at: note.url, to: newURL)
        note.overwrite(url: newURL)
        editor.syncSessionAfterRename(of: note)

        XCTAssertFalse(
            editor.editingSessionAccepts(resultFor: captured),
            "改名后按旧 URL 捕获的上传结果必须被拒")
        XCTAssertFalse(session.accepts(resultFor: captured))
    }

    /// 上传结果绑定启动时捕获的身份（NE-22 的 editor 侧入口）。同代际接受、
    /// 代际推进后拒绝——这是 ClipboardManager 两个上传回调实际调用的入口。
    @MainActor
    func testUploadResultBoundToCapturedJobContext() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSMutableAttributedString(string: "v1"), owner: note)

        let captured = editor.captureEditingJobContext()
        XCTAssertNotNil(captured, "有会话时必须能捕获任务身份")
        XCTAssertTrue(
            editor.editingSessionAccepts(resultFor: captured!),
            "同代际的上传结果必须被接受")

        // 上传在途时 watcher 重载推进了代际。
        try "v2 external".write(to: note.url, atomically: true, encoding: .utf8)
        XCTAssertTrue(editor.applyExternalFileChange("v2 external", owner: note))

        XCTAssertFalse(
            editor.editingSessionAccepts(resultFor: captured!),
            "代际推进后迟到的上传结果必须被拒")
    }

    /// 无会话（legacy 路径）不得被防护误伤：capture 返回 nil，核对放行。
    @MainActor
    func testUploadResultWithoutSessionIsNotBlocked() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)

        XCTAssertNil(editor.captureEditingJobContext(), "无会话时无法捕获身份")
        // 无会话时核对放行（保持 legacy 调用点既有行为）。
        XCTAssertNil(editor.captureEditingJobContext())
    }

    /// 锚点（placeholder）所在笔记已被删除：结果必须被拒，不得写进别的
    /// 笔记或复活删除文件。
    @MainActor
    func testUploadResultRejectedWhenAnchorNoteRetired() throws {
        let note = makeNote(body: "v1")
        let editor = EditTextView(frame: .zero)
        editor.publishStorage(NSMutableAttributedString(string: "v1"), owner: note)
        let session = try XCTUnwrap(editor.editingSession)

        let captured = session.currentJobContext
        note.retireAfterRemoval()
        editor.saveTextStorageContent(to: note)

        XCTAssertFalse(session.accepts(resultFor: captured), "锚点笔记退役后结果必须被拒")
        XCTAssertFalse(session.owns(url: note.url))
        XCTAssertFalse(
            editor.editingSessionAccepts(resultFor: captured),
            "退役后迟到的上传结果也必须被拒")
    }
}
