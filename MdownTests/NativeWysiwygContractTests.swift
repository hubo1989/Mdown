import XCTest

@testable import Mdown

/// T22 (PLAN N2 门):VditorIntegrationTests 的 native 契约替换。
///
/// 原 9 个 Vditor 用例的行为面逐项移植到 native rich 后端;Vditor 资源
/// 反向断言已移除(退依赖证据)。布局可见性一例由
/// NativeEditorModeMigrationTests 的路由用例覆盖,不在此重复。
final class NativeWysiwygContractTests: XCTestCase {

    private var tempDir: URL!
    private var testWindow: NSWindow?

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiaoYanNativeWysiwygTests-\(UUID().uuidString)")
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

    @MainActor
    private func makeHost() -> NativeRichEditorHostView {
        let host = NativeRichEditorHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        testWindow = window
        return host
    }

    // MARK: - 退依赖证据(资源反向断言)

    func testVditorEditorResourcesAreGone() throws {
        let bundle = Bundle(for: NativeWysiwygContractTests.self)
        // 测试 bundle 不带 DownView;从仓库源码路径断言(vditor 专属资源已删)
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MiaoYanTests/
            .deletingLastPathComponent()  // repo root
        let vditorDir = repo.appendingPathComponent("Resources/DownView.bundle/vditor")
        let editorHTML = repo.appendingPathComponent("Resources/DownView.bundle/editor.html")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: vditorDir.path),
            "T22:vditor/ 专属目录应已移除")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: editorHTML.path),
            "T22:editor.html 应已移除")
        // renderer 用资源必须保留(不误删)
        let indexHTML = repo.appendingPathComponent("Resources/DownView.bundle/index.html")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: indexHTML.path),
            "renderer 的 index.html 必须保留")
        _ = bundle  // Bundle 引用保持(断言仅对仓库路径)
    }

    // MARK: - 原 73/80/89/96:初始化 / loadNote / 外观 / 初始状态

    @MainActor
    func testNativeHostInitialization() {
        let host = makeHost()
        // 显隐由布局层控制(setVisibleWysiwygBackend);宿主自身不预设。
        XCTAssertNotNil(host.textView)
        XCTAssertTrue(host.textView.isEditable)
    }

    @MainActor
    func testNativeHostLoadNoteSetsCurrentNote() {
        let host = makeHost()
        let note = makeNote(body: "hello")
        host.loadNote(note)
        XCTAssertTrue(host.currentNote === note)
    }

    @MainActor
    func testNativeHostAppearanceUpdateDoesNotCrash() {
        let host = makeHost()
        host.loadNote(makeNote(body: "hello"))
        host.updateAppearance()
        host.updateAppearance()
    }

    @MainActor
    func testNativeHostInitialState() {
        let host = makeHost()
        XCTAssertNil(host.currentNote)
        XCTAssertEqual(host.textView.source, "")
    }

    // MARK: - 原 103:切笔记不编辑不动盘

    @MainActor
    func testSwitchNotesWithoutEditingDoesNotTouchDisk() throws {
        let host = makeHost()
        let a = makeNote(named: "a.md", body: "content-a")
        let b = makeNote(named: "b.md", body: "content-b")
        let aURL = a.url
        host.loadNote(a)
        host.loadNote(b)  // 纯浏览切换
        host.flushPendingSave(completion: nil)

        let diskA = try String(contentsOf: aURL, encoding: .utf8)
        XCTAssertEqual(diskA, "content-a", "未编辑的切换不得写盘")
    }

    // MARK: - 原 135:非预载内容异步装载

    @MainActor
    func testLoadsContentWhenNotPreloaded() async throws {
        let host = makeHost()
        let url = tempDir.appendingPathComponent("lazy.md")
        try "lazy body".write(to: url, atomically: true, encoding: .utf8)
        let project = Project(url: tempDir, label: "test", isRoot: true)
        let note = Note(url: url, with: project)
        // 不 markContentAsLoaded:走异步 ensureContentLoadedAsync 路径

        host.loadNote(note)
        await note.ensureContentLoadedAsync()
        // 异步装载完成后 host 持有该笔记(竞态保护由 loadToken 保证)
        XCTAssertTrue(host.currentNote === note)
    }

    // MARK: - 原 153:快速切换不覆盖

    @MainActor
    func testRapidSwitchDoesNotOverwriteWithStaleContent() {
        let host = makeHost()
        let a = makeNote(named: "a2.md", body: "content-a")
        let b = makeNote(named: "b2.md", body: "content-b")
        host.loadNote(a)
        let token = host.currentLoadTokenForTesting
        host.loadNote(b)
        // 模拟旧 token 的迟到装载完成:必须被丢弃
        host.applyContentLoadedForTesting(a, token: token)
        XCTAssertEqual(
            host.textView.source, "content-b",
            "旧 token 的装载不得覆盖已切换的笔记")
    }

    // MARK: - 编辑镜像与 flush(原 hard-save 用例的主机侧前提)

    @MainActor
    func testEditMirrorsNoteContentAndFlushLandsOnDisk() throws {
        let host = makeHost()
        let note = makeNote(named: "edit.md", body: "v1")
        host.loadNote(note)
        _ = host.textView.applyWholeSourceReplacement("v2", name: "test-edit")
        XCTAssertEqual(note.content.string, "v2", "编辑必须即时镜像进 note.content")
        host.flushPendingSave(completion: nil)
        // Note 层 1.5s debounce 的硬保存点(T08 链:host flush → note flush)
        XCTAssertTrue(note.flushPendingSave())
        let disk = try String(contentsOf: note.url, encoding: .utf8)
        XCTAssertEqual(disk, "v2", "flush 必须落盘")
    }
}
