import XCTest
@testable import MiaoYan

/// T03: display/source 投影与双向映射。
final class MarkdownProjectionTests: XCTestCase {

    private let parser = LosslessMarkdownParser()
    private let builder = MarkdownProjectionBuilder()

    private func projection(of blockText: String, as kind: LosslessMarkdownParser.BlockKind? = nil) -> MarkdownProjectionBuilder.Projection {
        let doc = parser.parse(blockText)
        let block = doc.blocks.first { b in
            kind.map { $0 == b.kind } ?? true
        } ?? doc.blocks[0]
        return builder.buildProjection(for: block, in: doc)
    }

    /// **AB**：只改 B 不删 delimiter——marker 是独立 hidden segment，
    /// B 的 source range 不含任何 delimiter 字节。
    func testEmphasisMarkersAreSeparateFromContent() {
        let p = projection(of: "**AB** 纯文本\n")
        let markerSegments = p.segments.filter { $0.kind == .hiddenMarker }
        XCTAssertEqual(markerSegments.count, 2, "前后各一个 hidden marker")

        let ns = "**AB** 纯文本\n" as NSString
        // 找 B 的文本段：内容段 "AB"
        let content = p.segments.first { $0.kind == .text && $0.displayText == "AB" }
        let ab = content.map(\.sourceRangeUTF16)
        XCTAssertEqual(ab, NSRange(location: 2, length: 2), "AB 的 source 必须在 ** 之间且不含 delimiter")
        // marker 段的切片就是 **（逐字节）
        XCTAssertEqual(ns.substring(with: markerSegments[0].sourceRangeUTF16), "**")
        XCTAssertEqual(ns.substring(with: markerSegments[1].sourceRangeUTF16), "**")
        // display 中 AB 直接可见，marker 无贡献
        XCTAssertEqual(p.display, "AB 纯文本\n")
    }

    func testUnclosedMarkerStaysLiteral() {
        let p = projection(of: "**未完成的加粗\n")
        XCTAssertEqual(p.display, "**未完成的加粗\n", "未闭合 marker 必须原样显示")
        XCTAssertTrue(p.segments.allSatisfy { $0.kind != .hiddenMarker })
    }

    func testEscapedMarkersStayLiteral() {
        let p = projection(of: "\\*文字\\*\n")
        XCTAssertEqual(p.display, "\\*文字\\*\n", "转义星号必须原样（不含隐藏段）")
        XCTAssertTrue(p.segments.allSatisfy { $0.kind != .hiddenMarker })
    }

    func testCodeSpanHidesBackticks() {
        let p = projection(of: "前 `code **原样**` 后\n")
        XCTAssertEqual(p.display, "前 code **原样** 后\n")
        let code = p.segments.first { $0.kind == .codeSpan }
        XCTAssertEqual(code?.displayText, "code **原样**", "code span 内容原样，内部不解析 emphasis")
        // 内部 ** 不产生 hiddenMarker
        let markers = p.segments.filter { $0.kind == .hiddenMarker }
        XCTAssertEqual(markers.count, 2, "仅前后 backtick 各一个 hidden marker")
    }

    func testLinkShowsLabelAndHidesDestination() {
        let p = projection(of: "见 [链接文字](https://example.invalid/x) 尾\n")
        XCTAssertEqual(p.display, "见 链接文字 尾\n")
        let dest = p.segments.first { $0.kind == .linkDestination }
        XCTAssertEqual(dest?.displayText, "", "destination 显示为空")
        let label = p.segments.first { $0.kind == .text && $0.displayText == "链接文字" }
        XCTAssertEqual(label?.sourceRangeUTF16, NSRange(location: 3, length: 4), "label 的 source 恰为括号内文字")
    }

    func testImageShowsPlaceholder() {
        let p = projection(of: "![本地缺失图片](/i/missing.png)\n")
        XCTAssertEqual(p.display, "[图]\n")
        let placeholder = p.segments.first { $0.kind == .attachmentPlaceholder }
        XCTAssertEqual(placeholder?.sourceRangeUTF16, NSRange(location: 2, length: 6), "alt 文字是占位的 source")
    }

    func testHeadingMarkerHidden() {
        let p = projection(of: "## 二级标题\n", as: .heading(level: 2))
        XCTAssertEqual(p.display, "二级标题\n")
        XCTAssertEqual(p.segments.first?.kind, .hiddenMarker)
        XCTAssertEqual(p.segments.first?.sourceRangeUTF16, NSRange(location: 0, length: 3), "## 加空格")
    }

    func testProtectedBlocksFallBackPlain() throws {
        let table = projection(of: "| a\\|b | c |\n| --- | --- |\n| 1 | 2 |\n", as: .table)
        XCTAssertTrue(table.segments.allSatisfy { $0.kind == .plainFallback })
        let fence = projection(of: "```text\n内部 **不解析**\n```\n", as: .codeFence(info: "text"))
        XCTAssertTrue(fence.segments.allSatisfy { $0.kind == .plainFallback })
        XCTAssertEqual(fence.display, "```text\n内部 **不解析**\n```\n", "fence 内容必须逐字节原样")
    }

    func testFenceContentNeverEntersInlineSegments() {
        let doc = parser.parse("```text\n含 **marker** 与 [链接](url)\n```\n后段 **加粗**\n")
        let fenceBlock = doc.blocks.first { if case .codeFence = $0.kind { return true }; return false }!
        let p = builder.buildProjection(for: fenceBlock, in: doc)
        XCTAssertFalse(p.segments.contains { $0.kind == .hiddenMarker || $0.kind == .text && $0.displayText.contains("链接") },
                       "fence 内容不得被 inline 扫描")
    }

    func testDisplayAndSourceOffsetsRoundTripOnBoundaries() {
        let source = "**AB** 普通 `code` [L](url) 尾\n"
        let p = projection(of: source)
        // 不变量：所有段边界（location 与 maxRange）经 display↔source 复合后
        // 仍落在段边界集合内。hidden marker 段内部偏移在 display 无表面，
        // 允许折叠到相邻段边界（SPEC 的 affinity 语义由 T04 caret 层处理）。
        let boundaries = Set(p.segments.flatMap { [
            $0.sourceRangeUTF16.location,
            NSMaxRange($0.sourceRangeUTF16),
        ] })
        for boundary in boundaries {
            guard let d = p.displayOffset(forSource: boundary),
                  let back = p.sourceOffset(forDisplay: d) else {
                return XCTFail("边界 \(boundary) 映射不得失败")
            }
            XCTAssertTrue(boundaries.contains(back),
                          "边界 \(boundary) 往返 \(back) 必须仍是段边界（不得落进段内部）")
        }
        // 非折叠段：内部中点往返必须恒等
        for segment in p.segments where segment.displayRangeUTF16.length > 0
            && segment.kind != .hiddenMarker && segment.kind != .linkDestination {
            let mid = segment.sourceRangeUTF16.location + max(1, segment.sourceRangeUTF16.length / 2)
            guard mid < NSMaxRange(segment.sourceRangeUTF16) else { continue }
            guard let d = p.displayOffset(forSource: mid),
                  let back = p.sourceOffset(forDisplay: d) else { continue }
            XCTAssertEqual(back, mid, "非折叠段内部点必须恒等（\(segment.kind)）")
        }
    }

    func testDisplayLengthEqualsSumOfSegmentContributions() {
        let p = projection(of: "段一 **强** 与 `码` 和 [链](u)。\n")
        XCTAssertEqual(p.display.utf16.count, p.segments.reduce(0) { $0 + $1.displayText.utf16.count })
    }
}

extension MarkdownProjectionTests {
    func testDebugDumpProjectionSegments() {
        let p = projection(of: "段一 **强** 与 `码` 和 [链](u)。\n")
        print("=== display=\(p.display.debugDescription)")
        for seg in p.segments {
            print("  \(seg.kind) src=\(seg.sourceRangeUTF16) disp=\(seg.displayRangeUTF16) text=\(seg.displayText.debugDescription)")
        }
    }
}
