import XCTest

@testable import MiaoYan

/// T08（SPEC §7.1 / NE-13 / NE-18 / AC-09）：离开前 TransitionCoordinator。
/// 统一入口的顺序（finish-composition → capture → flush）、可取消前置
/// （关窗/退出/切笔记）、失败四选一循环（Retry/Save Copy/Discard/Cancel）、
/// Discard 只丢会话草稿不动磁盘、在途写被 discard 的 generation 挡住。
final class EditingTransitionTests: XCTestCase {

    private var tempDir: URL!
    private var saveErrors: [NSError] = []

    override func setUp() {
        super.setUp()
        saveErrors = []
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiaoYanEditingTransitionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // 失败注入可能把目录留在只读态；恢复后清理。
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 测试桩

    @MainActor
    private final class StubPresenter: EditingTransitionPresenting {
        var choices: [EditingTransitionChoice]
        var saveCopyURLs: [URL?]
        var alertCount = 0
        /// 每次告警展示时执行（用于在 retry 前解除失败注入）。
        var onAlert: (() -> Void)?

        init(
            choices: [EditingTransitionChoice] = [],
            saveCopyURLs: [URL?] = []
        ) {
            self.choices = choices
            self.saveCopyURLs = saveCopyURLs
        }

        func presentSaveFailure(noteName: String) -> EditingTransitionChoice {
            onAlert?()
            alertCount += 1
            return choices.indices.contains(alertCount - 1) ? choices[alertCount - 1] : .cancel
        }

        func presentSaveCopyPanel(noteName: String) -> URL? {
            if saveCopyURLs.isEmpty { return nil }
            return saveCopyURLs.removeFirst()
        }
    }

    @MainActor
    private final class StubContext: EditingTransitionContext {
        let note: Note?
        /// CompositionDraft 注入点：false = 组合输入进行中且无法提交。
        var compositionFinishable = true
        var finishCompositionCallCount = 0
        var captureCallCount = 0
        /// 捕获时推进 note.content（模拟 saveTextStorageContent 把 buffer
        /// 推进镜像）。
        var captureHandler: ((Note) -> Void)?

        init(note: Note?) {
            self.note = note
        }

        var activeEditingNote: Note? { note }

        func finishSourceComposition() -> Bool {
            finishCompositionCallCount += 1
            return compositionFinishable
        }

        func captureActiveBuffer(into note: Note) {
            captureCallCount += 1
            captureHandler?(note)
        }

        var dirtyNotes: [Note] {
            note.map { $0.needsSave ? [$0] : [] } ?? []
        }
    }

    @MainActor
    private func makeNote(named: String = "note.md", body: String = "orig") throws -> Note {
        let url = tempDir.appendingPathComponent(named)
        try body.write(to: url, atomically: true, encoding: .utf8)
        let project = Project(url: tempDir, label: "test", isRoot: true)
        let note = Note(url: url, with: project)
        note.saveErrorPresenter = { [weak self] error in
            self?.saveErrors.append(error as NSError)
        }
        note.content = NSMutableAttributedString(string: body)
        return note
    }

    @MainActor
    private func makeCoordinator(
        choices: [EditingTransitionChoice] = [],
        saveCopyURLs: [URL?] = [],
        onAlert: (() -> Void)? = nil
    ) -> (EditingTransitionCoordinator, StubPresenter) {
        let presenter = StubPresenter(choices: choices, saveCopyURLs: saveCopyURLs)
        presenter.onAlert = onAlert
        return (EditingTransitionCoordinator(presenter: presenter), presenter)
    }

    @MainActor
    private func diskBody(_ note: Note) throws -> String {
        try String(contentsOf: note.url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 统一入口顺序（finish → capture → flush）

    @MainActor
    func testFinishActiveEditingCommitsCompositionBeforeCaptureAndFlushes() throws {
        let note = try makeNote(body: "orig")
        note.commit(content: NSMutableAttributedString(string: "v1"))
        let context = StubContext(note: note)
        context.captureHandler = { $0.content = NSMutableAttributedString(string: "v1-captured") }

        let outcome = makeCoordinator().0.finishActiveEditing(
            in: context, forceCompositionFinish: true)

        XCTAssertEqual(outcome.isSaved, true)
        XCTAssertEqual(context.finishCompositionCallCount, 1)
        XCTAssertEqual(context.captureCallCount, 1)
        XCTAssertEqual(note.needsSave, false)
        XCTAssertEqual(
            try diskBody(note), "v1-captured",
            "捕获的 buffer（组合提交后）必须同步落盘，不等 debounce")
    }

    @MainActor
    func testFinishActiveEditingBlockedWhileCompositionUnfinished() throws {
        let note = try makeNote(body: "orig")
        note.commit(content: NSMutableAttributedString(string: "v1"))
        let context = StubContext(note: note)
        context.compositionFinishable = false

        let outcome = makeCoordinator().0.finishActiveEditing(
            in: context, forceCompositionFinish: true)

        XCTAssertEqual(outcome.isBlocked, true)
        XCTAssertEqual(context.captureCallCount, 0, "组合未提交时不得捕获 hidden buffer")
        XCTAssertTrue(note.needsSave, "离开被阻止，草稿保持 dirty")
    }

    @MainActor
    func testFinishActiveEditingWithoutForceSkipsCompositionFinish() throws {
        let note = try makeNote(body: "orig")
        note.commit(content: NSMutableAttributedString(string: "v1"))
        let context = StubContext(note: note)

        _ = makeCoordinator().0.finishActiveEditing(
            in: context, forceCompositionFinish: false)

        XCTAssertEqual(
            context.finishCompositionCallCount, 0,
            "失焦/进 preview 等非离开点不得打断进行中的 IME 组合")
        XCTAssertEqual(context.captureCallCount, 1)
    }

    @MainActor
    func testFinishActiveEditingIdleWhenClean() throws {
        let note = try makeNote(body: "orig")
        let context = StubContext(note: note)

        let outcome = makeCoordinator().0.finishActiveEditing(
            in: context, forceCompositionFinish: true)

        XCTAssertEqual(outcome.isIdle, true)
        XCTAssertEqual(try diskBody(note), "orig", "干净笔记不做多余写盘")
    }

    // MARK: - 退出网关（close/quit 可取消）

    @MainActor
    func testWriteFailureReportsErrorWithoutModalAndRetryPersistsDraft() async throws {
        let note = try makeNote(body: "orig")
        note.commit(content: NSMutableAttributedString(string: "draft"))
        try makeDirReadOnly()

        XCTAssertEqual(note.flushPendingSaveOutcome(globalStorage: false), .failed)
        XCTAssertEqual(saveErrors.count, 1)
        XCTAssertEqual(saveErrors.first?.domain, NSCocoaErrorDomain)
        XCTAssertEqual(saveErrors.first?.code, CocoaError.fileWriteNoPermission.rawValue)
        XCTAssertTrue(note.needsSave)
        XCTAssertEqual(note.content.string, "draft")
        XCTAssertEqual(try diskBody(note), "orig")

        let modalWindow = NSApp.modalWindow
        await Task.yield()
        XCTAssertTrue(NSApp.modalWindow === modalWindow)
        try makeDirWritable()
        XCTAssertEqual(note.flushPendingSaveOutcome(globalStorage: false), .saved)
        XCTAssertFalse(note.needsSave)
        XCTAssertEqual(try diskBody(note), "draft")
        XCTAssertEqual(saveErrors.count, 1)
    }

    @MainActor
    func testPrepareExitAllowsCleanCloseWithoutAlert() throws {
        let note = try makeNote(body: "orig")
        let context = StubContext(note: note)
        let (coordinator, presenter) = makeCoordinator()

        XCTAssertTrue(coordinator.prepareExit(in: context))
        XCTAssertEqual(presenter.alertCount, 0)
    }

    @MainActor
    func testPrepareExitWriteFailureCancelBlocksExit() throws {
        let note = try makeNote(body: "orig")
        note.commit(content: NSMutableAttributedString(string: "draft"))
        try makeDirReadOnly()
        let context = StubContext(note: note)
        let (coordinator, presenter) = makeCoordinator(choices: [.cancel])

        XCTAssertFalse(coordinator.prepareExit(in: context), "Cancel 必须阻止关窗/退出")
        XCTAssertEqual(saveErrors.count, 1)
        XCTAssertEqual(presenter.alertCount, 1)
        XCTAssertTrue(note.needsSave, "失败后草稿保持 dirty 可重试")
    }

    @MainActor
    func testPrepareExitBlockedWhileCompositionUnfinished() throws {
        let note = try makeNote(body: "orig")
        let context = StubContext(note: note)
        context.compositionFinishable = false

        XCTAssertFalse(
            makeCoordinator().0.prepareExit(in: context),
            "组合输入无法提交时关窗返回取消（NE-13 留在原上下文）")
    }

    @MainActor
    func testPrepareExitRetrySucceedsAfterFailureCleared() throws {
        let note = try makeNote(body: "orig")
        note.commit(content: NSMutableAttributedString(string: "draft"))
        try makeDirReadOnly()
        let context = StubContext(note: note)
        // 第一次告警展示时解除只读，retry 的 flush 应成功。
        let (coordinator, _) = makeCoordinator(
            choices: [.retry], onAlert: { try? self.makeDirWritable() })

        XCTAssertTrue(coordinator.prepareExit(in: context))
        XCTAssertFalse(note.needsSave)
        XCTAssertEqual(saveErrors.count, 1)
        XCTAssertEqual(try diskBody(note), "draft")
    }

    @MainActor
    func testPrepareExitSaveCopyWritesCopyAndAllowsExit() throws {
        let note = try makeNote(body: "orig")
        note.commit(content: NSMutableAttributedString(string: "draft"))
        try makeDirReadOnly()
        let copyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("copy-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: copyURL) }
        let context = StubContext(note: note)
        let (coordinator, _) = makeCoordinator(choices: [.saveCopy], saveCopyURLs: [copyURL])

        XCTAssertTrue(coordinator.prepareExit(in: context), "副本确认写成功后放行离开")
        XCTAssertEqual(try String(contentsOf: copyURL, encoding: .utf8), "draft")
        XCTAssertEqual(try diskBody(note), "orig", "Save Copy 不改原笔记磁盘内容")
        XCTAssertTrue(note.needsSave, "原笔记保持 dirty（草稿只保存在副本里）")
    }

    @MainActor
    func testPrepareExitSaveCopyPanelCancelledThenCancelBlocks() throws {
        let note = try makeNote(body: "orig")
        note.commit(content: NSMutableAttributedString(string: "draft"))
        try makeDirReadOnly()
        let context = StubContext(note: note)
        let (coordinator, presenter) = makeCoordinator(
            choices: [.saveCopy, .cancel], saveCopyURLs: [nil])

        XCTAssertFalse(coordinator.prepareExit(in: context))
        XCTAssertEqual(presenter.alertCount, 2, "面板取消后回到告警，再取消才阻止")
    }

    @MainActor
    func testPrepareExitDiscardDropsDraftKeepsDiskFile() throws {
        let note = try makeNote(body: "orig")
        note.commit(content: NSMutableAttributedString(string: "draft"))
        try makeDirReadOnly()
        let context = StubContext(note: note)
        let (coordinator, _) = makeCoordinator(choices: [.discard])

        XCTAssertTrue(coordinator.prepareExit(in: context))
        XCTAssertEqual(try diskBody(note), "orig", "Discard 只丢会话草稿，不删/不改磁盘")
        XCTAssertFalse(note.needsSave)
        XCTAssertEqual(note.content.string, "orig", "镜像回到磁盘真值")
    }

    // MARK: - 切笔记网关（0.5s 旧空窗不丢最后输入）

    @MainActor
    func testPrepareNoteSwitchSavesOutgoingDraftSynchronously() throws {
        let note = try makeNote(body: "orig")
        // 最后一次击键刚提交，1.5s debounce 未到。
        note.commit(content: NSMutableAttributedString(string: "v1"))
        let context = StubContext(note: note)
        context.captureHandler = { $0.content = NSMutableAttributedString(string: "v1-last") }

        XCTAssertTrue(makeCoordinator().0.prepareNoteSwitch(from: note, in: context))
        XCTAssertEqual(
            try diskBody(note), "v1-last",
            "切换必须同步落盘捕获后的最新 buffer，最后 0.5s 输入不丢")
    }

    @MainActor
    func testPrepareNoteSwitchBlockedByCompositionKeepsSelection() throws {
        let note = try makeNote(body: "orig")
        note.commit(content: NSMutableAttributedString(string: "v1"))
        let context = StubContext(note: note)
        context.compositionFinishable = false

        XCTAssertFalse(
            makeCoordinator().0.prepareNoteSwitch(from: note, in: context),
            "组合未提交时选择不切换")
        XCTAssertEqual(context.captureCallCount, 0)
    }

    @MainActor
    func testPrepareNoteSwitchFailureCancelKeepsDirty() throws {
        let note = try makeNote(body: "orig")
        note.commit(content: NSMutableAttributedString(string: "v1"))
        try makeDirReadOnly()
        let context = StubContext(note: note)
        let (coordinator, _) = makeCoordinator(choices: [.cancel])

        XCTAssertFalse(coordinator.prepareNoteSwitch(from: note, in: context))
        XCTAssertTrue(note.needsSave)
    }

    @MainActor
    func testPrepareNoteSwitchAllowsNilOutgoing() {
        let context = StubContext(note: nil)

        XCTAssertTrue(makeCoordinator().0.prepareNoteSwitch(from: nil, in: context))
    }

    // MARK: - Note.discardUnsavedChanges（会话草稿，不动磁盘）

    @MainActor
    func testDiscardReloadsFromDiskAndClearsDirty() throws {
        let note = try makeNote(body: "orig")
        note.commit(content: NSMutableAttributedString(string: "draft"))

        note.discardUnsavedChanges()

        XCTAssertFalse(note.needsSave)
        XCTAssertEqual(note.content.string, "orig")
        XCTAssertEqual(try diskBody(note), "orig")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: note.url.path),
            "Discard 不删磁盘文件")
    }

    @MainActor
    func testDiscardSupersedesStaleInFlightCompletion() throws {
        let note = try makeNote(body: "orig")
        note.commit(content: NSMutableAttributedString(string: "draft"))
        let stale = NotePendingWriteIdentity(
            url: note.getURL(),
            generation: 0,
            revision: 1,
            digest: "draft".md5)

        note.discardUnsavedChanges()

        // discard 后旧捕获的写完成只能得到 superseded，不能复活 dirty。
        let outcome = note.completeSave(stale, writeSucceeded: true, globalStorage: false)
        XCTAssertEqual(outcome, .superseded)
        XCTAssertFalse(note.needsSave)
    }

    // MARK: - 失败注入工具

    /// 把 tempDir 置为只读，使 FileWrapper 写盘失败（.failed）。
    private func makeDirReadOnly() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: tempDir.path)
    }

    private func makeDirWritable() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
    }
}

extension EditingFlushOutcome {
    var isIdle: Bool { if case .idle = self { return true }; return false }
    var isSaved: Bool { if case .saved = self { return true }; return false }
    var isBlocked: Bool { if case .blocked = self { return true }; return false }
}

// MARK: - 活动后端采集的最小上下文（供既有 hard-save-point 测试迁移复用）

/// 直接包住 (sourceEditor, vditorView, isWysiwyg) 的采集面，等价于
/// ViewController 的生产 conformance；EditorStorageOwnershipTests 与
/// NoteSaveDebounceTests 的硬保存点用例经它走统一入口。
@MainActor
final class BackendCaptureStubContext: EditingTransitionContext {

    let sourceEditor: EditTextView
    let vditorView: VditorEditView?
    let isWysiwygActive: Bool
    let activeNote: Note?

    init(
        activeNote: Note?,
        sourceEditor: EditTextView,
        vditorView: VditorEditView?,
        isWysiwygActive: Bool
    ) {
        self.activeNote = activeNote
        self.sourceEditor = sourceEditor
        self.vditorView = vditorView
        self.isWysiwygActive = isWysiwygActive
    }

    var activeEditingNote: Note? { activeNote }

    func finishSourceComposition() -> Bool { true }

    func captureActiveBuffer(into note: Note) {
        if isWysiwygActive {
            vditorView?.flushPendingSave()
        } else {
            sourceEditor.saveTextStorageContent(to: note)
        }
    }

    var dirtyNotes: [Note] { [] }
}
