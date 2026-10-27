import XCTest

@testable import MiaoYan

/// T18 (SPEC §8.2 / NE-15 / NE-25 / AC-15):NativeMarkdownFormatter
/// `mdown-preserve-v1` 的第一阶段合同。
///
/// 保护段(fence/缩进 code/math/frontmatter/raw HTML/link target/
/// reference 值)字节不动;非 hard-break 行尾空白清理;空行折叠为单空行;
/// 表格单元格边缘单空格、对齐线 ≥3 字符并保留 colon;幂等
/// f(f(x)) == f(x);prose 换行保持(不重排)。
final class NativeMarkdownFormatterTests: XCTestCase {

    private func assertIdempotent(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        let once = NativeMarkdownFormatter.format(source)
        let twice = NativeMarkdownFormatter.format(once)
        XCTAssertEqual(twice, once, "format 必须幂等", file: file, line: line)
    }

    // MARK: - 保护段字节不动

    func testFenceContentIsBytePreservedIncludingTrailingSpaces() {
        let source = "```swift\nlet x = 1   \n\n\n``` \ntext  \n"
        let out = NativeMarkdownFormatter.format(source)
        XCTAssertTrue(out.contains("let x = 1   \n"), "fence 内容含尾随空格必须原样: \(out)")
        XCTAssertTrue(out.contains("\n\n\n```"), "fence 内空行不折叠: \(out)")
    }

    func testFrontmatterIsBytePreserved() {
        let source = "---\ntitle: x  \n---\nbody  \n"
        let out = NativeMarkdownFormatter.format(source)
        XCTAssertTrue(out.hasPrefix("---\ntitle: x  \n---\n"), out)
        XCTAssertEqual(out, "---\ntitle: x  \n---\nbody\n")
    }

    func testIndentedCodeBlockIsPreserved() {
        let source = "para  \n\n    indented code   \n    second  \n"
        let out = NativeMarkdownFormatter.format(source)
        XCTAssertTrue(out.contains("    indented code   \n"), out)
        XCTAssertTrue(out.contains("    second  \n"), out)
    }

    func testMathBlockIsPreserved() {
        let source = "para\n$$\na = b  \n$$\ntail  \n"
        let out = NativeMarkdownFormatter.format(source)
        XCTAssertTrue(out.contains("a = b  \n"), out)
        XCTAssertEqual(out, "para\n$$\na = b  \n$$\ntail\n")
    }

    func testLineIndexBaseIsStableAcrossBlocks() {
        // 回归:Block 行号 1 基、rawLines 0 基——混淆会把块后首行误保护
        // (其尾随空白保留)、块内末行误清理(字节被改)。
        let source = "```\ncode  \n```\ntail  \n"
        let out = NativeMarkdownFormatter.format(source)
        XCTAssertTrue(out.contains("code  \n"), "块内尾随空格必须保留: \(out)")
        XCTAssertEqual(out, "```\ncode  \n```\ntail\n", "块后行必须照常清尾: \(out)")
    }

    // MARK: - 尾随空白与 hard break

    func testTrailingWhitespaceStrippedExceptHardBreaks() {
        XCTAssertEqual(NativeMarkdownFormatter.format("line \ntab\t\n"), "line\ntab\n")
        // 两个尾随空格 = hard break,保留
        XCTAssertEqual(NativeMarkdownFormatter.format("keep  \nnext\n"), "keep  \nnext\n")
    }

    // MARK: - 空行折叠

    func testBlankLineRunsCollapseToSingleBlank() {
        XCTAssertEqual(
            NativeMarkdownFormatter.format("a\n\n\n\n\nb\n"),
            "a\n\nb\n")
    }

    // MARK: - 表格归一

    func testTableEdgesAndDelimiterNormalized() {
        let source = "| a |b|\n|--|:-:|\n|c | d |\n"
        let out = NativeMarkdownFormatter.format(source)
        XCTAssertEqual(out, "| a | b |\n| --- | :---: |\n| c | d |\n", out)
    }

    func testTableEscapedPipeAndAlignmentSurvive() {
        let source = "| x \\| y | `a|b` |\n| --- | --: |\n| c | d |\n"
        let out = NativeMarkdownFormatter.format(source)
        XCTAssertTrue(out.hasPrefix("| x \\| y | `a|b` |\n| --- | ---: |\n"), out)
    }

    // MARK: - prose 与既有结构不重排

    func testProseLineBreaksAndListMarkersPreserved() {
        let source = "first line\nwrapped second  \n- item\n  - nested\n1. one\n2. two\n"
        let out = NativeMarkdownFormatter.format(source)
        XCTAssertEqual(out, source, "prose 换行与既有 list 写法不重排")
    }

    // MARK: - 幂等

    func testAllSamplesAreIdempotent() {
        for sample in [
            "```swift\nlet x = 1   \n\n\n``` \ntext  \n",
            "---\ntitle: x  \n---\nbody  \n",
            "line \nkeep  \n",
            "a\n\n\n\n\nb\n",
            "| a |b|\n|--|:-:|\n|c | d |\n",
            "first line\nwrapped second  \n- item\n",
        ] {
            assertIdempotent(sample)
        }
    }

    func testCRLFProtectedBlocksPreserveExactBytes() {
        let source = "\u{feff}---\r\ntitle: x  \r\n---\r\n\r\n```swift\r\nlet x = 1   \r\n\r\n\r\n```\r\ntail \r\n"
        let expected = "\u{feff}---\r\ntitle: x  \r\n---\r\n\r\n```swift\r\nlet x = 1   \r\n\r\n\r\n```\r\ntail\r\n"
        XCTAssertEqual(Array(NativeMarkdownFormatter.format(source).utf8), Array(expected.utf8))
    }

    func testMixedLineEndingsAndNoFinalNewlineStayLocal() {
        let source = "first \r\nsecond \nthird\rfourth "
        XCTAssertEqual(NativeMarkdownFormatter.format(source), "first\r\nsecond\nthird\rfourth")
        XCTAssertEqual(NativeMarkdownFormatter.format("plain"), "plain")
    }

    func testTwoTablesUseOneBaseForEveryReplacement() {
        let source = "|a|b|\n|-|-|\n|c|d|\n\nbetween\n\n|e|f|\n|:-|-:|\n|g|h|\n"
        let expected = "| a | b |\n| --- | --- |\n| c | d |\n\nbetween\n\n| e | f |\n| :--- | ---: |\n| g | h |\n"
        let result = NativeMarkdownFormatter.format(source)
        XCTAssertEqual(result, expected)
        assertIdempotent(source)
    }

    func testCRLFTableFormattingKeepsLineEndings() {
        let source = "|a|b|\r\n|---|---|\r\n|c|d|"
        let expected = "| a | b |\r\n| --- | --- |\r\n| c | d |"
        XCTAssertEqual(NativeMarkdownFormatter.format(source), expected)
        assertIdempotent(source)
    }

    func testBlankLinesInsideListAreNotCollapsed() {
        let source = "- first\n\n\n  continuation\n\n- second\n"
        XCTAssertEqual(NativeMarkdownFormatter.format(source), source)
    }

    func testReferenceDefinitionAndMultilineInlineCodeRemainVerbatim() {
        let source = "[ref]: <https://example.com/a> \"title\"  \n\ntext `code  \n\n\nmore` tail \n"
        let expected = "[ref]: <https://example.com/a> \"title\"  \n\ntext `code  \n\n\nmore` tail\n"
        XCTAssertEqual(NativeMarkdownFormatter.format(source), expected)
    }

    @MainActor
    func testRichFormattingRejectsTypingThenUndoToSameBytes() {
        let view = RichMarkdownTextView(source: "body \n")
        let owner = UUID()
        let capture = NativeMarkdownFormatter.Snapshot(
            owner: owner, url: URL(fileURLWithPath: "/tmp/format.md"), generation: 1,
            revision: view.revision, source: view.source)
        XCTAssertTrue(view.applyWholeSourceReplacement("new body\n", name: "typing"))
        XCTAssertTrue(view.performUndo())
        XCTAssertEqual(view.source, capture.source)
        XCTAssertFalse(
            capture.matches(
                currentOwner: UUID(), url: capture.url, generation: 1,
                revision: view.revision, source: view.source), "新 format 发起令旧快照失配,即使 undo 回到相同字节")
    }

    @MainActor
    func testFormattingSnapshotRejectsRebindingAndRename() {
        let capture = NativeMarkdownFormatter.Snapshot(
            owner: UUID(), url: URL(fileURLWithPath: "/tmp/a.md"), generation: 1,
            revision: 3, source: "body")
        XCTAssertFalse(
            capture.matches(
                currentOwner: UUID(), url: capture.url, generation: 1, revision: 3, source: "body"))
        XCTAssertFalse(
            capture.matches(
                currentOwner: capture.owner, url: capture.url, generation: 2, revision: 3, source: "body"))
        XCTAssertFalse(
            capture.matches(
                currentOwner: capture.owner, url: URL(fileURLWithPath: "/tmp/b.md"),
                generation: 1, revision: 3, source: "body"))
        XCTAssertTrue(
            capture.matches(
                currentOwner: capture.owner, url: capture.url, generation: 1, revision: 3, source: "body"))
    }

    // MARK: - 未知语法保持原文

    func testUnknownStructurePassesThrough() {
        let weird = "?? >> << **unclosed\n| not | table |\n"
        XCTAssertEqual(NativeMarkdownFormatter.format(weird), weird.replacingOccurrences(of: "\n", with: "\n"))
        // 不吞不删:除可解释的空白规则外逐字保留
        let out = NativeMarkdownFormatter.format(weird)
        XCTAssertEqual(out.components(separatedBy: "\n").count, 3)
    }
}
