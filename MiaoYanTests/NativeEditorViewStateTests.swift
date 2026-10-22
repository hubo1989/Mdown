import XCTest

@testable import MiaoYan

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
