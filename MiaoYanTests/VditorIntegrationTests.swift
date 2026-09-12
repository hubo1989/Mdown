import XCTest
@testable import MiaoYan

final class VditorIntegrationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VditorTests-\(UUID().uuidString)")
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

    func testVditorHTMLTemplateExists() {
        guard let bundle = HtmlManager.getDownViewBundle() else {
            XCTFail("DownView.bundle not found")
            return
        }
        let editorURL = bundle.url(forResource: "editor", withExtension: "html")
        XCTAssertNotNil(editorURL, "editor.html must exist in DownView.bundle")

        if let url = editorURL, let content = try? String(contentsOf: url, encoding: .utf8) {
            XCTAssertTrue(content.contains("vditor/dist/index.min.js"), "editor.html should reference vditor/dist/index.min.js")
            XCTAssertTrue(content.contains("vditor/dist/index.css"), "editor.html should reference vditor/dist/index.css")
            XCTAssertTrue(content.contains("vditor/dist/js/i18n/zh_CN.js"), "editor.html should reference zh_CN.js")
            XCTAssertTrue(content.contains("mode: 'wysiwyg'"), "editor.html should initialize Vditor in wysiwyg mode")
            XCTAssertTrue(content.contains("cdn: './vditor'"), "editor.html should use local offline cdn")
        }
    }

    func testVditorDistAssetsExist() {
        guard let bundle = HtmlManager.getDownViewBundle() else {
            XCTFail("DownView.bundle not found")
            return
        }
        let bundleURL = bundle.bundleURL
        let requiredFiles = [
            "vditor/dist/index.min.js",
            "vditor/dist/index.css",
            "vditor/dist/js/i18n/zh_CN.js",
            "vditor/dist/js/lute/lute.min.js",
            "vditor/dist/js/highlight.js/highlight.min.js",
            "vditor/dist/js/katex/katex.min.js",
        ]

        for relativePath in requiredFiles {
            let assetURL = bundleURL.appendingPathComponent(relativePath)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: assetURL.path),
                "Missing required Vditor offline asset: \(relativePath)"
            )
        }
    }

    @MainActor
    func testVditorEditViewInitialization() {
        let view = VditorEditView()
        XCTAssertNil(view.currentNote)
        XCTAssertFalse(view.canGoBack)
    }

    @MainActor
    func testVditorEditViewLoadNoteSetsCurrentNote() {
        let view = VditorEditView()
        let note = makeTestNote(name: "test.md", content: "# Hello Vditor\n\nThis is a test.")

        view.loadNote(note)
        XCTAssertEqual(view.currentNote?.url, note.url)
    }

    @MainActor
    func testVditorEditViewAppearanceUpdateDoesNotCrash() {
        let view = VditorEditView()
        view.updateAppearance()
        view.focus()
    }

    @MainActor
    func testVditorEditViewInitialStateAndAlpha() {
        let view = VditorEditView()
        XCTAssertEqual(view.alphaValue, 1.0, "VditorEditView should have alphaValue = 1.0 to prevent transition flashing")
        XCTAssertFalse(view.hasUnsavedChanges, "Initially hasUnsavedChanges should be false")
    }

    @MainActor
    func testVditorEditViewSwitchNotesWithoutEditingDoesNotTouchDisk() {
        let view = VditorEditView()
        let note1 = makeTestNote(name: "note1.md", content: "Original note 1 content")
        let note2 = makeTestNote(name: "note2.md", content: "Original note 2 content")

        view.loadNote(note1)
        XCTAssertEqual(view.currentNote?.url, note1.url)
        XCTAssertFalse(view.hasUnsavedChanges)

        // Switching to note2 without any user typing
        view.loadNote(note2)
        XCTAssertEqual(view.currentNote?.url, note2.url)
        XCTAssertFalse(view.hasUnsavedChanges)

        // Verify note1's content remains completely unchanged
        let readBack1 = try? String(contentsOf: note1.url, encoding: .utf8)
        XCTAssertEqual(readBack1, "Original note 1 content")
    }

    @MainActor
    private func makeUnloadedNote(name: String, diskContent: String) -> Note {
        let fileURL = tempDirectory.appendingPathComponent(name)
        try? diskContent.write(to: fileURL, atomically: true, encoding: .utf8)
        let project = Project(url: tempDirectory, label: "TestProject", isTrash: false, isRoot: true)
        let note = Note(url: fileURL, with: project)
        // Verify simulated cold launch state: content not loaded, empty string
        XCTAssertFalse(note.isContentLoaded)
        XCTAssertEqual(note.content.string, "")
        return note
    }

    @MainActor
    func testVditorEditViewLoadsContentWhenNotPreloaded() async {
        let view = VditorEditView()
        let note = makeUnloadedNote(name: "unloaded.md", diskContent: "# Cold Launch Test\nContent from disk.")

        view.loadNote(note)
        XCTAssertEqual(view.currentNote?.url, note.url)

        // Wait for async ensureContentLoadedAsync task to complete
        for _ in 0..<50 {
            if note.isContentLoaded { break }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }

        XCTAssertTrue(note.isContentLoaded)
        XCTAssertEqual(note.content.string, "# Cold Launch Test\nContent from disk.")
    }

    @MainActor
    func testVditorEditViewRapidSwitchDoesNotOverwriteWithStaleContent() async {
        let view = VditorEditView()
        let note1 = makeUnloadedNote(name: "note1.md", diskContent: "Note 1 content")
        let note2 = makeUnloadedNote(name: "note2.md", diskContent: "Note 2 content")

        // Rapidly switch from note1 to note2
        view.loadNote(note1)
        view.loadNote(note2)

        XCTAssertEqual(view.currentNote?.url, note2.url)

        for _ in 0..<50 {
            if note2.isContentLoaded { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(note2.isContentLoaded)
        XCTAssertEqual(view.currentNote?.url, note2.url)
    }

    @MainActor
    func testEnableWysiwygModeSetsLayoutVisibility() {
        guard let vc = ViewController.shared() else { return }
        vc.enableWysiwygMode()
        XCTAssertEqual(vc.vditorEditView?.isHidden, false)
        XCTAssertEqual(vc.editAreaScroll.isHidden, true)
    }
}
