import XCTest

@testable import MiaoYan

/// T10 (SPEC NE-01 / NE-18 / NE-32 / NE-33 / NE-36 / AC-16 / AC-17)：
/// native rich backend 的模式路由、pref 迁移与 host 生命周期。
///
/// 覆盖三组行为：
/// 1. editorLayoutMode 迁移语义——新用户 source 默认、legacy splitViewMode
///    迁移、stored 值优先、读取无写副作用、wysiwygMode setter 只从
///    wysiwyg 退出；
/// 2. native rich host 的装载/镜像/保存——投影装载、编辑镜像进 note.content、
///    flush 落盘、切换笔记前先落盘旧笔记、Trash 只读、晚到异步装载竞态、
///    selection 锚点往返；
/// 3. 布局路由源码断言——⌘3/Toggle Preview 只做纯 preview、wysiwyg 路由
///    经 activeWysiwygBackend（不并行两个 backend 发布正文）。
final class NativeEditorModeMigrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiaoYanNativeModeTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    // MARK: - defaults 隔离

    /// editorLayoutMode / splitViewMode / useNativeWysiwyg 三个键的
    /// 保存-清空-恢复，迁移断言不污染真实用户 defaults。
    private func withIsolatedLayoutDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = [
            UserDefaultsManagement.LayoutDefaultsTesting.editorLayoutMode,
            UserDefaultsManagement.LayoutDefaultsTesting.splitViewMode,
            UserDefaultsManagement.LayoutDefaultsTesting.useNativeWysiwyg,
        ]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try body()
    }

    @MainActor
    private func makeNote(named: String = "note.md", body: String = "orig") -> Note {
        let url = tempDir.appendingPathComponent(named)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        let project = Project(url: tempDir, label: "test", isRoot: true)
        let note = Note(url: url, with: project)
        note.content = NSMutableAttributedString(string: body)
        // 同步装载:host.loadNote 直接走 applyNote(不经异步 Task),
        // 断言时序确定;异步竞态由专用测试注入晚到结果覆盖。
        note.markContentAsLoaded()
        return note
    }

    /// G0 同款:挂 window 保证文本输入协议(firstResponder)稳定。
    private var testWindow: NSWindow?

    @MainActor
    private func makeHost() -> NativeRichEditorHostView {
        let host = NativeRichEditorHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        testWindow = window
        return host
    }

    override func tearDown() {
        testWindow = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 迁移语义（NE-01）

    @MainActor
    func testFreshDefaultsMigrateToSourceMode() {
        withIsolatedLayoutDefaults {
            XCTAssertEqual(
                UserDefaultsManagement.editorLayoutMode, .source,
                "新用户（无 stored key、无 legacy flag）必须默认 source")
        }
    }

    @MainActor
    func testLegacySplitViewModeMigratesToSplitLayout() {
        withIsolatedLayoutDefaults {
            UserDefaults.standard.set(true, forKey: UserDefaultsManagement.LayoutDefaultsTesting.splitViewMode)
            XCTAssertEqual(
                UserDefaultsManagement.editorLayoutMode, .split,
                "legacy splitViewMode=true 迁移到 split；legacy=false 迁移到 source")
            UserDefaults.standard.set(false, forKey: UserDefaultsManagement.LayoutDefaultsTesting.splitViewMode)
            XCTAssertEqual(UserDefaultsManagement.editorLayoutMode, .source)
        }
    }

    @MainActor
    func testStoredLayoutModeWinsOverLegacySplitFlag() {
        withIsolatedLayoutDefaults {
            UserDefaults.standard.set(true, forKey: UserDefaultsManagement.LayoutDefaultsTesting.splitViewMode)
            UserDefaults.standard.set(
                EditorLayoutMode.wysiwyg.rawValue,
                forKey: UserDefaultsManagement.LayoutDefaultsTesting.editorLayoutMode)
            XCTAssertEqual(
                UserDefaultsManagement.editorLayoutMode, .wysiwyg,
                "stored editorLayoutMode 优先于 legacy splitViewMode")
        }
    }

    @MainActor
    func testLayoutModeReadMigrationHasNoWriteSideEffect() {
        withIsolatedLayoutDefaults {
            UserDefaults.standard.set(true, forKey: UserDefaultsManagement.LayoutDefaultsTesting.splitViewMode)
            _ = UserDefaultsManagement.editorLayoutMode
            XCTAssertNil(
                UserDefaults.standard.string(forKey: UserDefaultsManagement.LayoutDefaultsTesting.editorLayoutMode),
                "读取迁移只做计算，不得把迁移结果写进 stored key")
        }
    }

    @MainActor
    func testWysiwygModeSetterExitsToSourceOnlyFromWysiwyg() {
        withIsolatedLayoutDefaults {
            UserDefaultsManagement.editorLayoutMode = .wysiwyg
            UserDefaultsManagement.wysiwygMode = false
            XCTAssertEqual(UserDefaultsManagement.editorLayoutMode, .source)

            UserDefaultsManagement.editorLayoutMode = .split
            UserDefaultsManagement.wysiwygMode = false
            XCTAssertEqual(
                UserDefaultsManagement.editorLayoutMode, .split,
                "split 下 wysiwygMode=false 不得扰动当前布局")
        }
    }

    @MainActor
    func testNativeWysiwygBackendDefaultsOnAndIsWritable() {
        withIsolatedLayoutDefaults {
            XCTAssertTrue(
                UserDefaultsManagement.useNativeWysiwyg,
                "native rich 是 wysiwyg 的默认 backend；legacy Vditor 是显式回退")
            UserDefaultsManagement.useNativeWysiwyg = false
            XCTAssertFalse(UserDefaultsManagement.useNativeWysiwyg)
        }
    }

    // MARK: - backend 协议面

    @MainActor
    func testVditorEditViewConformsToWysiwygBackend() {
        // 纯 Swift 协议无 ObjC 运行时 conformance 检查；经泛型约束在
        // 编译期证明 VditorEditView 实现协议面（缺实现即编译失败）。
        func requireBackend<B: WysiwygEditingBackend>(_ type: B.Type) -> Bool { true }
        XCTAssertTrue(
            requireBackend(VditorEditView.self),
            "legacy Vditor 必须经同一协议面路由，不得单独接线")
    }

    // MARK: - native host：装载与投影

    @MainActor
    func testNativeHostConformsToWysiwygBackend() {
        let host = makeHost()
        func requireBackend<B: WysiwygEditingBackend>(_ type: B.Type) -> Bool { true }
        XCTAssertTrue(requireBackend(NativeRichEditorHostView.self))
        XCTAssertNil(host.currentNote)
    }

    @MainActor
    func testNativeHostLoadNotePublishesProjection() {
        let note = makeNote(body: "# 标题\n\n正文段落。\n")
        let host = makeHost()

        host.loadNote(note)

        XCTAssertEqual(host.currentNote, note)
        XCTAssertEqual(host.textView.source, "# 标题\n\n正文段落。\n", "装载必须以 note 正文为 source 权威")
        XCTAssertEqual(host.textView.displayText, "标题\n\n正文段落。\n", "heading marker 投影隐藏")
        XCTAssertFalse(host.textView.allowsUndo, "历史由 RichMarkdownTextView 内部 MarkdownEditorHistory 拥有")
    }

    // MARK: - native host：编辑镜像与保存（NE-36：不丢草稿）

    @MainActor
    func testNativeHostEditingMirrorsIntoNoteAndPersistsOnFlush() {
        let note = makeNote(body: "# 标题\n\n正文段落。\n")
        let host = makeHost()
        host.loadNote(note)

        // display: "标(0)题(1)\n(2)\n(3)正(4)文(5)段(6)落(7)。(8)\n(9)"
        // → caret 落"落"与"。"之间 = display 8
        host.textView.setSelectedRange(NSRange(location: 8, length: 0))
        host.textView.insertText("新")

        XCTAssertEqual(
            note.content.string, "# 标题\n\n正文段落新。\n",
            "编辑必须即时镜像进 note.content（预览/保存读镜像）")

        host.flushPendingSave()
        // flush → persistNote → note.save(content:)（与 Vditor persistNote
        // 同层，commit 即 dirty）；同步磁盘写是 Note 层职责，模拟 T08
        // 离开点的完整链。
        XCTAssertTrue(note.needsSave, "flush 必须把草稿 commit 进 Note（dirty 立即可见）")
        XCTAssertTrue(note.flushPendingSave())
        let onDisk = try? String(contentsOf: note.url, encoding: .utf8)
        XCTAssertEqual(onDisk, "# 标题\n\n正文段落新。\n", "T08 离开点链路下正文必须落盘")
    }

    @MainActor
    func testNativeHostLoadNoteFlushesUnsavedOutgoingNote() {
        let noteA = makeNote(named: "a.md", body: "A 原文\n")
        let noteB = makeNote(named: "b.md", body: "B 原文\n")
        let host = makeHost()
        host.loadNote(noteA)
        host.textView.setSelectedRange(NSRange(location: 1, length: 0))
        host.textView.insertText("+")

        host.loadNote(noteB)

        XCTAssertTrue(noteA.needsSave, "切换前旧笔记草稿必须已 commit（不丢草稿）")
        _ = noteA.flushPendingSave()
        XCTAssertEqual(
            try? String(contentsOf: noteA.url, encoding: .utf8), "A+ 原文\n",
            "切换笔记前必须把旧笔记未保存草稿落盘（不丢草稿）")
        XCTAssertEqual(host.textView.source, "B 原文\n")
        XCTAssertEqual(host.currentNote, noteB)
    }

    @MainActor
    func testNativeHostTrashNoteLoadsReadOnly() {
        let trashDir = tempDir.appendingPathComponent("Trash")
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let url = trashDir.appendingPathComponent("trashed.md")
        try? "已删除\n".write(to: url, atomically: true, encoding: .utf8)
        let project = Project(url: trashDir, label: "trash", isTrash: true, isRoot: true)
        let note = Note(url: url, with: project)
        note.content = NSMutableAttributedString(string: "已删除\n")

        let host = makeHost()
        host.loadNote(note)

        XCTAssertFalse(host.textView.isEditable, "Trash 笔记在 native backend 必须只读")
    }

    // MARK: - native host：竞态与锚点

    /// 晚到的异步装载（用户已切到下一笔记）不得覆盖当前内容。
    @MainActor
    func testNativeHostLateAsyncLoadDoesNotCrosstalk() {
        let noteA = makeNote(named: "a.md", body: "A 内容\n")
        let noteB = makeNote(named: "b.md", body: "B 内容\n")
        let host = makeHost()

        host.loadNote(noteA)
        let staleToken = host.currentLoadTokenForTesting
        host.loadNote(noteB)

        // 模拟 A 的异步 ensureContentLoadedAsync 在切换之后完成。
        host.applyContentLoadedForTesting(noteA, token: staleToken)

        XCTAssertEqual(host.textView.source, "B 内容\n", "旧 token 的晚到装载必须被拒绝")
        XCTAssertEqual(host.currentNote, noteB)
    }

    @MainActor
    func testNativeHostSelectionAnchorRoundTrip() {
        let note = makeNote(body: "一二三\n四五六\n")
        let host = makeHost()
        host.loadNote(note)
        host.textView.setSelectedRange(NSRange(location: 2, length: 0))
        host.saveSelectionAnchor()

        host.textView.setSelectedRange(NSRange(location: 5, length: 0))
        host.restoreSelectionAnchor()

        XCTAssertEqual(
            host.textView.selectedRange(), NSRange(location: 2, length: 0),
            "进 preview/切模式前保存的 selection 锚点必须可恢复")
    }

    // MARK: - 布局路由源码断言（AC-16：⌘3 统一纯 preview）

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// ⌘3 / previewButton 的共同无参入口只做纯 preview 进出，不得把布局
    /// 切到 wysiwyg（wysiwyg 是独立菜单/设置入口）。
    func testTogglePreviewRoutesPurePreviewOnly() throws {
        let editor = try source("Controllers/ViewController+Editor.swift")
        let start = try XCTUnwrap(editor.range(of: "func togglePreview() {"))
        let end = try XCTUnwrap(
            editor.range(of: "@IBAction func toggleSplitView", range: start.upperBound..<editor.endIndex))
        let body = String(editor[start.lowerBound..<end.lowerBound])

        XCTAssertNil(
            body.range(of: "sessionLayoutMode = .wysiwyg"),
            "togglePreview 不得进入 wysiwyg backend")
        XCTAssertTrue(body.contains("enablePreview"), "非 preview 状态进 preview")
        XCTAssertTrue(body.contains("disablePreview"), "preview 状态退出")
    }

    /// wysiwyg 的启用/禁用必须经 activeWysiwygBackend 路由（native 或
    /// legacy Vditor），不得直连 vditorEditView——否则两个 backend 并行。
    func testEnableWysiwygRoutesThroughActiveBackend() throws {
        let editor = try source("Controllers/ViewController+Editor.swift")
        for marker in ["func enableWysiwygMode() {", "func disableWysiwygMode() {"] {
            let start = try XCTUnwrap(editor.range(of: marker), marker)
            let end = try XCTUnwrap(
                editor.range(of: "\n    func ", range: start.upperBound..<editor.endIndex))
            let body = String(editor[start.lowerBound..<end.lowerBound])
            XCTAssertNil(
                body.range(of: "vditorEditView"),
                "\(marker) 必须经 activeWysiwygBackend，不得直连 Vditor")
            XCTAssertTrue(
                body.contains("activeWysiwygBackend"),
                "\(marker) 必须经 activeWysiwygBackend 路由 backend")
        }
    }
}
