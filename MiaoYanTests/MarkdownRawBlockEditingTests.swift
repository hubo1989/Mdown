import XCTest
@testable import MiaoYan

@MainActor
final class MarkdownRawBlockEditingTests: XCTestCase {
    private var testWindow: NSWindow?

    private func makeView(_ source: String) -> RichMarkdownTextView {
        let view = RichMarkdownTextView(source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        testWindow = window
        return view
    }

    func testMathBlockPreservesLiteralSourceInProjection() {
        let source = "# Before\n\n$$\na_{**x**} + `literal`\n$$\n\nAfter\n"
        let view = makeView(source)
        XCTAssertEqual(view.displayText, "Before\n\n$$\na_{**x**} + `literal`\n$$\n\nAfter\n")
    }

    func testRawCodeCompositionUndoKeepsHiddenMarkersOutsideBlock() throws {
        let source = "# Before\n\n```unknown\nvalue\n```\n\n**After**\n"
        let view = makeView(source)
        let offset = try XCTUnwrap(view.displayOffset(forSourceOffset: (source as NSString).range(of: "value").location))
        view.setSelectedRange(NSRange(location: offset, length: 0))
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("中")
        view.unmarkText()
        let expected = source.replacingOccurrences(of: "value", with: "中value")
        XCTAssertEqual(view.source, expected)
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, source)
        XCTAssertTrue(view.performRedo())
        XCTAssertEqual(view.source, expected)
    }

    func testInvalidDiagramRemainsEditableAndUndoable() throws {
        let source = "```mermaid\ngraph invalid ???\n```\n"
        let view = makeView(source)
        let offset = try XCTUnwrap(view.displayOffset(forSourceOffset: 20))
        view.setSelectedRange(NSRange(location: offset, length: 0))
        view.insertText("中😀")
        XCTAssertEqual(view.source, (source as NSString).replacingCharacters(in: NSRange(location: 20, length: 0), with: "中😀"))
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, source)
    }

    func testMathAndUnknownCodeKeepCRLFAndNestedFenceBytes() {
        let samples = ["$$\r\na_1 + **literal**\r\n$$\r\n", "````unknown\r\n```nested\r\n中😀\r\n````\r\n"]
        for source in samples {
            let view = makeView(source)
            XCTAssertEqual(view.displayText, source)
            view.setSelectedRange(NSRange(location: (source as NSString).range(of: "\r\n").location + 2, length: 0))
            view.insertText("**input**")
            XCTAssertTrue(view.source.contains("**input**"))
            XCTAssertTrue(view.performUndo())
            XCTAssertEqual(view.source, source)
        }
    }

    func testCompositionPlainUnmarkCommitsOneHistoryEntry() throws {
        let source = "# Heading\n\n$$\nx\n$$\n"
        let view = makeView(source)
        let location = try XCTUnwrap(view.displayOffset(forSourceOffset: (source as NSString).range(of: "x").location))
        view.setSelectedRange(NSRange(location: location, length: 0))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        XCTAssertEqual(view.history.undoStack.count, 1)
        XCTAssertEqual(view.source, source.replacingOccurrences(of: "x", with: "中x"))
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, source)
    }

    func testRawCompositionCancelAndThemeRefreshPreserveMarkedText() {
        let source = "# Heading\n\n```swift\nvalue\n```\n"
        let view = makeView(source)
        view.setSelectedRange(NSRange(location: 18, length: 0))
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.refreshFontAttributes()
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertFalse(view.performUndo())
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        XCTAssertEqual(view.source, source)
        XCTAssertTrue(view.history.undoStack.isEmpty)
    }

    func testMultilineHTMLKeepsLiteralSyntaxWithoutExecutingIt() {
        let source = "# Before\n\n<div>\n**literal**\n<script>bad()</script>\n</div>\n\nAfter\n"
        let view = makeView(source)
        XCTAssertEqual(view.displayText, "Before\n\n<div>\n**literal**\n<script>bad()</script>\n</div>\n\nAfter\n")
    }

    func testResponderUndoRedoUsesSameHistoryAsRawTyping() {
        let view = makeView("```unknown\nvalue\n```\n")
        view.setSelectedRange(NSRange(location: 11, length: 0))
        view.insertText("中")
        XCTAssertEqual(view.history.undoStack.count, 1)
        let undo = NSSelectorFromString("undo:")
        let redo = NSSelectorFromString("redo:")
        XCTAssertTrue(view.responds(to: undo))
        XCTAssertTrue(view.responds(to: redo))
        if view.responds(to: undo) { view.perform(undo, with: nil) }
        XCTAssertEqual(view.source, "```unknown\nvalue\n```\n")
        if view.responds(to: redo) { view.perform(redo, with: nil) }
        XCTAssertEqual(view.source, "```unknown\n中value\n```\n")
    }
}
