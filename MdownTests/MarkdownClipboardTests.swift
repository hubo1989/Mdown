import XCTest
@testable import Mdown

@MainActor
final class MarkdownClipboardTests: XCTestCase {
    private var testWindow: NSWindow?

    private final class DragInfo: NSObject, NSDraggingInfo {
        var draggingDestinationWindow: NSWindow?
        var draggingSourceOperationMask: NSDragOperation = .copy
        var draggingLocation = NSPoint.zero
        var draggedImageLocation = NSPoint.zero
        nonisolated var draggedImage: NSImage? { nil }
        let draggingPasteboard: NSPasteboard
        var draggingSource: Any? { nil }
        var draggingSequenceNumber = 1
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var springLoadingHighlight: NSSpringLoadingHighlight = .none

        @MainActor init(board: NSPasteboard) { draggingPasteboard = board }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
    }

    private func makeView(_ source: String) -> RichMarkdownTextView {
        let view = RichMarkdownTextView(source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        testWindow = window
        return view
    }

    private func board(_ text: String, html: String? = nil) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.setString(text, forType: .string)
        if let html { board.setString(html, forType: .html) }
        return board
    }

    func testExternalPlainPasteCannotCreateMarkdownStructure() {
        let view = makeView("")
        let pasteboard = board("# Title\n- item **bold** [label](https://example.com)")
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.readSelection(from: pasteboard))
        XCTAssertEqual(view.source, "\\# Title\n\\- item \\*\\*bold\\*\\* \\[label\\](https://example.com)")
        XCTAssertEqual(view.history.undoStack.last?.origin, .paste)
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "")
        XCTAssertTrue(view.performRedo())
        XCTAssertTrue(view.source.hasPrefix("\\# Title"))
    }

    func testStructuredHTMLPasteUsesExistingConversionGate() {
        let view = makeView("")
        let pasteboard = board("Heading", html: "<h2>Heading</h2><ul><li>Item</li></ul>")
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.readSelection(from: pasteboard))
        XCTAssertEqual(view.source, "## Heading\n\n- Item")
        XCTAssertEqual(view.history.undoStack.count, 1)
        XCTAssertEqual(view.history.undoStack.last?.origin, .paste)
    }

    func testCodePasteKeepsPlainBytesDespiteStructuredHTML() {
        let source = "```swift\nvalue\n```\n"
        let view = makeView(source)
        view.setSelectedRange(NSRange(location: 9, length: 5))
        let pasteboard = board("**literal**", html: "<h1>Not code</h1>")
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.readSelection(from: pasteboard))
        XCTAssertEqual(view.source, "```swift\n**literal**\n```\n")
        XCTAssertEqual(view.history.undoStack.last?.origin, .paste)
    }

    func testCopyOffersVisibleTextAndSeparateMarkdownFlavor() {
        let source = "# Heading\n\n**bold** [label](https://example.com)\n"
        let view = makeView(source)
        view.selectAll(nil)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "Heading\n\nbold label\n")
        XCTAssertEqual(pasteboard.string(forType: NSPasteboard.PasteboardType("com.miaoyan.markdown")), source)
    }

    func testCrossBlockPasteIsOneUndoUnit() {
        let view = makeView("# Heading\n\n- item\n")
        view.selectAll(nil)
        let pasteboard = board("replacement")
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.readSelection(from: pasteboard))
        XCTAssertEqual(view.source, "replacement")
        XCTAssertEqual(view.history.undoStack.count, 1)
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "# Heading\n\n- item\n")
    }

    func testExplicitModesAndInternalMarkdownFlavor() {
        let view = makeView("")
        let pasteboard = board("**bold**", html: "<h1>HTML</h1>")
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.paste(from: pasteboard, mode: .plain))
        XCTAssertEqual(view.source, "\\*\\*bold\\*\\*")
        XCTAssertEqual(view.displayText, "**bold**")
        view.setSource("")
        XCTAssertTrue(view.paste(from: pasteboard, mode: .markdown))
        XCTAssertEqual(view.source, "**bold**")
        pasteboard.setString("- internal", forType: MarkdownClipboardAdapter.markdownType)
        view.setSource("")
        XCTAssertTrue(view.readSelection(from: pasteboard))
        XCTAssertEqual(view.source, "- internal")
    }

    func testInlineCodePasteIgnoresHTMLAndDoesNotEscape() throws {
        let view = makeView("before `value` after")
        view.setSelectedRange(NSRange(location: 8, length: 0))
        let pasteboard = board("[x] **literal**", html: "<h1>HTML</h1>")
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.readSelection(from: pasteboard))
        XCTAssertEqual(view.source, "before `v[x] **literal**alue` after")
    }

    func testVisibleEscapesAndPartialMarkdownCopy() {
        let view = makeView("before **bold** after")
        view.setSelectedRange(NSRange(location: 7, length: 4))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "bold")
        XCTAssertEqual(pasteboard.string(forType: MarkdownClipboardAdapter.markdownType), "**bold**")
    }

    func testPlainPastePreservesUnicodeCRLFAndDoesNotTriggerInputRule() {
        let view = makeView("")
        let pasteboard = board("1. 中😀\r\n> e\u{301}\r\n---")
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.readSelection(from: pasteboard))
        XCTAssertEqual(view.source, "1\\. 中😀\r\n\\> e\u{301}\r\n\\---")
        XCTAssertEqual(view.displayText, "1. 中😀\r\n> e\u{301}\r\n---")
        XCTAssertNil(view.lastInputRuleTriggered)
    }

    func testPasteRejectsReadOnlyAndMarkedText() {
        let view = makeView("value")
        let pasteboard = board("**paste**")
        defer { pasteboard.releaseGlobally() }
        view.isEditable = false
        XCTAssertFalse(view.readSelection(from: pasteboard))
        XCTAssertEqual(view.source, "value")
        view.isEditable = true
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = view.source
        XCTAssertFalse(view.readSelection(from: pasteboard))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.source, marked)
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
    }

    private func attachmentOwner() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MdownT13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("note.md")
        try "before after".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func imageBytes() throws -> Data {
        let image = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }

    func testFileDropLifecycleKeepsCopyOperationAndWritesAtDropPoint() async throws {
        let owner = try attachmentOwner()
        let imageURL = owner.deletingLastPathComponent().appendingPathComponent("drop.png")
        try imageBytes().write(to: imageURL)
        let view = makeView("before after")
        view.configureAttachmentOwner(url: owner, isValid: { true })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([imageURL as NSURL]))
        let info = DragInfo(board: pasteboard)
        info.draggingDestinationWindow = testWindow
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: 7, length: 1), in: container)
        info.draggingLocation = view.convert(NSPoint(x: rect.minX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y), to: nil)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(view.draggingEntered(info), .copy)
        XCTAssertEqual(view.draggingUpdated(info), .copy)
        guard view.prepareForDragOperation(info) else { XCTFail("drop rejected during prepare"); return }
        let completed = expectation(description: "drop saved")
        view.onAttachmentFinished = { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            completed.fulfill()
        }
        XCTAssertTrue(view.performDragOperation(info))
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertTrue(view.source.hasPrefix("before ![drop](/i/"))
        XCTAssertTrue(view.source.hasSuffix(")after"))
        XCTAssertEqual(view.history.undoStack.last?.origin, .attachment)
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "before after")
    }

    func testDropRevalidatesReadOnlyCompositionAndSourceOperation() {
        let view = makeView("body")
        let pasteboard = board("text")
        defer { pasteboard.releaseGlobally() }
        let info = DragInfo(board: pasteboard)
        XCTAssertEqual(view.draggingEntered(info), .copy)
        view.isEditable = false
        XCTAssertEqual(view.draggingUpdated(info), [])
        XCTAssertFalse(view.prepareForDragOperation(info))
        XCTAssertFalse(view.performDragOperation(info))
        view.isEditable = true
        info.draggingSourceOperationMask = .move
        XCTAssertEqual(view.draggingEntered(info), [])
        XCTAssertFalse(view.prepareForDragOperation(info))
        info.draggingSourceOperationMask = .copy
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.draggingEntered(info), [])
        XCTAssertFalse(view.prepareForDragOperation(info))
        XCTAssertFalse(view.performDragOperation(info))
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        XCTAssertEqual(view.source, "body")
    }

    func testDropRejectsMultipleFilesBeforeChangingSelectionOrSource() throws {
        let owner = try attachmentOwner()
        let view = makeView("before after")
        view.configureAttachmentOwner(url: owner, isValid: { true })
        view.setSelectedRange(NSRange(location: 3, length: 0))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([owner as NSURL, owner.deletingLastPathComponent().appendingPathComponent("second.txt") as NSURL]))
        let info = DragInfo(board: pasteboard)
        XCTAssertEqual(view.draggingEntered(info), [])
        XCTAssertFalse(view.prepareForDragOperation(info))
        XCTAssertFalse(view.performDragOperation(info))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertEqual(view.source, "before after")
    }

    func testAttachmentWritesImageBeforeInsertingAndUndoKeepsRecoverableFile() async throws {
        let owner = try attachmentOwner()
        let view = makeView("before after")
        view.configureAttachmentOwner(url: owner, isValid: { true })
        view.setSelectedRange(NSRange(location: 7, length: 0))
        let data = try imageBytes()
        let task = try XCTUnwrap(view.importAttachment(.image(data)))
        await task.value
        XCTAssertNil(view.lastAttachmentError)
        let folder = owner.deletingLastPathComponent().appendingPathComponent("i")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(view.source, "before ![](/i/\(file.lastPathComponent))after")
        view.insertText("tail")
        XCTAssertTrue(view.source.hasSuffix(")tailafter"))
        XCTAssertTrue(view.performUndo())
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "before after")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testFilePasteboardStoresNonImageInFilesAndKeepsBytes() async throws {
        let owner = try attachmentOwner()
        let origin = owner.deletingLastPathComponent().appendingPathComponent("document[1].bin")
        let bytes = Data([0, 1, 127, 255])
        try bytes.write(to: origin)
        let view = makeView("")
        view.configureAttachmentOwner(url: owner, isValid: { true })
        let task = try XCTUnwrap(view.importAttachment(.file(origin)))
        await task.value
        let files = try FileManager.default.contentsOfDirectory(at: owner.deletingLastPathComponent().appendingPathComponent("files"), includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(view.source, "[document\\[1\\]](/files/\(file.lastPathComponent))")
        XCTAssertEqual(view.history.undoStack.last?.origin, .attachment)
    }

    func testAttachmentFailureNeverInsertsReference() async throws {
        let owner = try attachmentOwner()
        let view = makeView("unchanged")
        view.configureAttachmentOwner(url: owner, isValid: { true })
        let task = try XCTUnwrap(view.importAttachment(.file(owner.appendingPathComponent("missing"))))
        await task.value
        XCTAssertNotNil(view.lastAttachmentError)
        XCTAssertEqual(view.source, "unchanged")
        XCTAssertTrue(view.history.undoStack.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owner.deletingLastPathComponent().appendingPathComponent("files").path))
    }

    func testAttachmentAnchorTracksEditsBeforeItAndIgnoresCurrentCaret() throws {
        let owner = try attachmentOwner()
        let view = makeView("before after")
        view.configureAttachmentOwner(url: owner, isValid: { true })
        view.setSelectedRange(NSRange(location: 7, length: 0))
        let request = try XCTUnwrap(view.beginAttachmentRequest())
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("😀")
        let written = try MarkdownAttachmentWriter.write(.image(imageBytes()), noteURL: owner)
        XCTAssertTrue(view.completeAttachmentRequest(request, written: written))
        XCTAssertEqual(view.source, "😀before \(written.markdown)after")
        XCTAssertFalse(view.completeAttachmentRequest(request, written: written))
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.url.path))
    }

    func testDeletedAnchorRejectsLateResultAndCleansOwnedFile() throws {
        let owner = try attachmentOwner()
        let view = makeView("aaaa")
        view.configureAttachmentOwner(url: owner, isValid: { true })
        view.setSelectedRange(NSRange(location: 1, length: 1))
        let request = try XCTUnwrap(view.beginAttachmentRequest())
        view.insertText("")
        let written = try MarkdownAttachmentWriter.write(.image(imageBytes()), noteURL: owner)
        XCTAssertFalse(view.completeAttachmentRequest(request, written: written))
        XCTAssertEqual(view.source, "aaa")
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.url.path))
    }

    func testAttachmentRejectsChangedOwnerAndMarkedText() throws {
        let owner = try attachmentOwner()
        let view = makeView("value")
        var valid = true
        view.configureAttachmentOwner(url: owner, isValid: { valid })
        let request = try XCTUnwrap(view.beginAttachmentRequest())
        let written = try MarkdownAttachmentWriter.write(.image(imageBytes()), noteURL: owner)
        valid = false
        XCTAssertFalse(view.completeAttachmentRequest(request, written: written))
        XCTAssertEqual(view.source, "value")
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.url.path))
        valid = true
        let second = try XCTUnwrap(view.beginAttachmentRequest())
        let secondFile = try MarkdownAttachmentWriter.write(.image(imageBytes()), noteURL: owner)
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.completeAttachmentRequest(second, written: secondFile))
        XCTAssertTrue(view.hasMarkedText())
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        XCTAssertEqual(view.source, "value")
    }

    func testAttachmentCannotEscapeViaSymlinkOrRecreateMissingNote() throws {
        let owner = try attachmentOwner()
        let outside = owner.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: owner.deletingLastPathComponent().appendingPathComponent("i"), withDestinationURL: outside)
        XCTAssertThrowsError(try MarkdownAttachmentWriter.write(.image(imageBytes()), noteURL: owner))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        try FileManager.default.removeItem(at: owner)
        XCTAssertThrowsError(try MarkdownAttachmentWriter.write(.image(imageBytes()), noteURL: owner))
        XCTAssertFalse(FileManager.default.fileExists(atPath: owner.path))
    }

    func testImageMetadataEditKeepsNeighborBytesAndTitle() throws {
        let source = "before ![alt](/i/a.png \"old title\") after"
        let view = makeView(source)
        view.setSelectedRange(NSRange(location: 8, length: 0))
        let span = try XCTUnwrap(view.linkAtSelection())
        XCTAssertEqual(span.target, "/i/a.png")
        XCTAssertEqual(span.title, "old title")
        XCTAssertTrue(view.updateImage(alt: "新图片", target: "/i/new(1).png", title: "new \"title\""))
        XCTAssertEqual(view.source, "before ![新图片](/i/new\\(1\\).png \"new \\\"title\\\"\") after")
        XCTAssertEqual(view.displayText, "before 新图片 after")
        view.setSelectedRange(NSRange(location: 8, length: 0))
        XCTAssertEqual(view.linkAtSelection()?.title, "new \"title\"")
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, source)
        view.setSelectedRange(NSRange(location: 8, length: 0))
        XCTAssertFalse(view.updateImage(alt: "new", target: "javascript:alert(1)", title: nil))
        XCTAssertEqual(view.source, source)
    }

    func testContextMenuOffersClipboardAndImageActions() throws {
        let view = makeView("![alt](/i/a.png)")
        view.setSelectedRange(NSRange(location: 0, length: 3))
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: try XCTUnwrap(testWindow).windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(view.menu(for: event))
        for action in ["copyVisibleText:", "copyMarkdown:", "pasteAsPlainText:", "pasteMarkdown:", "editImage:"] {
            let item = try XCTUnwrap(menu.items.last { $0.action == NSSelectorFromString(action) }, action)
            XCTAssertTrue(item.target === view, action)
        }
    }

    func testEscapedImageAltDisplaysLiteralPunctuation() throws {
        let source = "![a\\[b\\]](/i/a\\(1\\).png)"
        let view = makeView(source)
        XCTAssertEqual(view.displayText, "a[b]")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        let span = try XCTUnwrap(view.linkAtSelection())
        XCTAssertTrue(view.updateImage(alt: InlineLinkScanner.unescape(span.label), target: InlineLinkScanner.unescape(span.target), title: span.title))
        XCTAssertEqual(view.source, source)
        XCTAssertFalse(view.updateImage(alt: "alt", target: "/i/a\tb.png", title: nil))
        XCTAssertEqual(view.source, source)
        XCTAssertTrue(view.updateImage(alt: "alt", target: "/i/<a>\".png", title: nil))
        XCTAssertEqual(view.source, "![alt](/i/%3Ca%3E%22.png)")
    }

    func testImagePlaceholderIsAtomicWhenPastingAndTyping() {
        let view = makeView("![😀alt](/i/a.png) tail")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertText("X")
        XCTAssertEqual(view.source, "![😀alt](/i/a.png)X tail")
        XCTAssertTrue(view.performUndo())
        view.setSelectedRange(NSRange(location: 0, length: 5))
        let pasteboard = board("replacement")
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.readSelection(from: pasteboard))
        XCTAssertEqual(view.source, "replacement tail")
    }

    func testRealFilePasteboardCompletesInCapturedNoteAndFlushesToDisk() async throws {
        let owner = try attachmentOwner()
        let project = Project(url: owner.deletingLastPathComponent(), label: "T13", isRoot: true)
        let note = Note(url: owner, with: project)
        note.content = NSMutableAttributedString(string: "before after")
        note.markContentAsLoaded()
        let host = NativeRichEditorHostView(frame: NSRect(x: 0, y: 0, width: 500, height: 350))
        host.loadNote(note)
        let imageURL = owner.deletingLastPathComponent().appendingPathComponent("original.png")
        try imageBytes().write(to: imageURL)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([imageURL as NSURL]))
        let completed = expectation(description: "attachment completed")
        host.textView.onAttachmentFinished = { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            completed.fulfill()
        }
        host.textView.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertTrue(host.textView.readSelection(from: pasteboard))
        await fulfillment(of: [completed], timeout: 5)
        host.flushPendingSave()
        note.flushPendingSave()
        XCTAssertEqual(try String(contentsOf: owner, encoding: .utf8), host.textView.source)
        XCTAssertTrue(host.textView.source.contains("![original](/i/"))
        XCTAssertEqual(note.content.string, host.textView.source)
    }

    func testHostSwitchAndRetireRejectLateAttachmentWithoutRecreatingNote() throws {
        let owner = try attachmentOwner()
        let project = Project(url: owner.deletingLastPathComponent(), label: "T13", isRoot: true)
        let note = Note(url: owner, with: project)
        note.content = NSMutableAttributedString(string: "before after")
        note.markContentAsLoaded()
        let host = NativeRichEditorHostView(frame: .zero)
        host.loadNote(note)
        let request = try XCTUnwrap(host.textView.beginAttachmentRequest())
        let written = try MarkdownAttachmentWriter.write(.image(imageBytes()), noteURL: owner)
        let secondURL = owner.deletingLastPathComponent().appendingPathComponent("second.md")
        try "second".write(to: secondURL, atomically: true, encoding: .utf8)
        let second = Note(url: secondURL, with: project)
        second.content = NSMutableAttributedString(string: "second")
        second.markContentAsLoaded()
        host.loadNote(second)
        XCTAssertFalse(host.textView.completeAttachmentRequest(request, written: written))
        XCTAssertEqual(host.textView.source, "second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.url.path))
        let secondRequest = try XCTUnwrap(host.textView.beginAttachmentRequest())
        let secondFile = try MarkdownAttachmentWriter.write(.image(imageBytes()), noteURL: secondURL)
        second.retireAfterRemoval()
        try FileManager.default.removeItem(at: secondURL)
        XCTAssertFalse(host.textView.completeAttachmentRequest(secondRequest, written: secondFile))
        host.flushPendingSave()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testPastedEscapedCharactersRemainEditableAndUndoable() {
        let view = makeView("")
        let pasteboard = board("*中*")
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.readSelection(from: pasteboard))
        XCTAssertEqual(view.displayText, "*中*")
        view.setSelectedRange(NSRange(location: 0, length: 1))
        view.insertText("!")
        XCTAssertEqual(view.source, "!中\\*")
        XCTAssertEqual(view.displayText, "!中*")
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, "\\*中\\*")
    }

    func testRemovingEntireBlockInvalidatesEmptyAnchorAtItsEnd() throws {
        let owner = try attachmentOwner()
        let view = makeView("paragraph")
        view.configureAttachmentOwner(url: owner, isValid: { true })
        view.setSelectedRange(NSRange(location: 9, length: 0))
        let request = try XCTUnwrap(view.beginAttachmentRequest())
        view.selectAll(nil)
        let pasteboard = board("")
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.readSelection(from: pasteboard))
        let written = try MarkdownAttachmentWriter.write(.image(imageBytes()), noteURL: owner)
        XCTAssertFalse(view.completeAttachmentRequest(request, written: written))
        XCTAssertEqual(view.source, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.url.path))
    }
}
