import XCTest

@testable import Mdown

/// T19 (SPEC §8.3 / NE-32 / AC-17):view-state 合同——typewriter 居中
/// 滚动、protected kind 的 spell/auto-replacement 分流。
///
/// 纯计算与视图属性断言;实机 keyboard/VoiceOver 属实测项,不在此冒充。
final class NativeEditorViewStateTests: XCTestCase {

    // MARK: - typewriter 滚动几何(纯计算)

    func testTypewriterOffsetCentersCaretLine() {
        // caret 行中心对准视口中心
        XCTAssertEqual(
            RichMarkdownTextView.typewriterScrollOffset(
                caretLineCenterY: 500, viewportHeight: 200, contentHeight: 1000),
            400)
    }

    func testTypewriterOffsetClampsAtTop() {
        XCTAssertEqual(
            RichMarkdownTextView.typewriterScrollOffset(
                caretLineCenterY: 20, viewportHeight: 200, contentHeight: 1000),
            0, "顶部 caret 不得出现负滚动")
    }

    func testTypewriterOffsetClampsAtBottom() {
        XCTAssertEqual(
            RichMarkdownTextView.typewriterScrollOffset(
                caretLineCenterY: 990, viewportHeight: 200, contentHeight: 1000),
            800, "底部 caret 不得越过内容底")
    }

    func testTypewriterOffsetShortContentStaysZero() {
        XCTAssertEqual(
            RichMarkdownTextView.typewriterScrollOffset(
                caretLineCenterY: 50, viewportHeight: 300, contentHeight: 100),
            0, "内容不足一屏时保持在顶")
    }

    // MARK: - 视图状态(NE-32:只改 view state,不动 revision/dirty/history)

    // MARK: - T19 focus 降噪 / zoom 滚动锚

    @MainActor
    func testFocusDimmingDimsBlocksAwayFromCaret() {
        let view = RichMarkdownTextView(source: "first block\n\nsecond block\n")
        view.contentTextColor = NSColor.black
        view.isFocusDimmingEnabled = true
        view.setSelectedRange(NSRange(location: 2, length: 0))  // first block
        view.updateFocusDimming()

        let ns = view.string as NSString
        let first =
            view.textStorage?.attribute(
                .foregroundColor, at: ns.range(of: "first").location, effectiveRange: nil) as? NSColor
        let second =
            view.textStorage?.attribute(
                .foregroundColor, at: ns.range(of: "second").location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(first, .black, "caret 块保持全彩")
        XCTAssertNotEqual(second, .black, "非 caret 块降噪")
        XCTAssertEqual(second?.alphaComponent ?? 1, 0.4, accuracy: 0.01)
    }

    @MainActor
    func testFocusDimmingDisabledKeepsAllBlocksFullColor() {
        let view = RichMarkdownTextView(source: "first block\n\nsecond block\n")
        view.contentTextColor = NSColor.black
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.updateFocusDimming()
        let ns = view.string as NSString
        let second =
            view.textStorage?.attribute(
                .foregroundColor, at: ns.range(of: "second").location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(second, .black, "关闭降噪时全部块保持正文色")
    }

    @MainActor
    func testFocusDimmingIsViewStateOnly() {
        let view = RichMarkdownTextView(source: "a\n\nb\n")
        let revisionBefore = view.revision
        view.isFocusDimmingEnabled = true
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.updateFocusDimming()
        XCTAssertEqual(view.revision, revisionBefore, "降噪不动 revision")
        XCTAssertFalse(view.history.debugDepth > 0, "降噪不入历史")
    }

    func testAnchoredScrollOffsetKeepsCaretStationary() {
        // zoom/mode 切换后:caret 在视口中的偏移保持,scroll 重算并 clamp
        XCTAssertEqual(
            RichMarkdownTextView.anchoredScrollOffset(
                caretContentY: 500, caretOffsetFromViewportTop: 120),
            380)
        XCTAssertEqual(
            RichMarkdownTextView.anchoredScrollOffset(
                caretContentY: 30, caretOffsetFromViewportTop: 120),
            0, "顶部 clamp")
    }

    @MainActor
    func testTypewriterModeToggleDoesNotTouchRevisionOrHistory() {
        let view = RichMarkdownTextView(source: "hello world\n")
        let revisionBefore = view.revision
        let historyDepth = view.history.debugDepth

        view.isTypewriterMode = true
        XCTAssertTrue(view.isTypewriterMode)
        XCTAssertEqual(view.revision, revisionBefore, "view state 不得推进 revision")
        XCTAssertEqual(view.history.debugDepth, historyDepth, "view state 不得入历史")
    }

    // MARK: - protected kind 的输入策略(SPEC §8.3)

    @MainActor
    func testAutomaticReplacementsStayOffInRichView() {
        let view = RichMarkdownTextView(source: "code `x` and prose\n")
        XCTAssertFalse(view.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(view.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(view.isAutomaticTextReplacementEnabled)
    }

    @MainActor
    func testSpellCheckingDisabledInCodeHeavyRichView() {
        // code/math/URL 区不得被 spell 改写:rich 面整体关 continuous
        // spell(N1 保守策略;按 range 分流的精确开关留 N2,如实记录)。
        let view = RichMarkdownTextView(source: "```\nmisspeled\n```\n")
        XCTAssertFalse(view.isContinuousSpellCheckingEnabled)
    }
}
