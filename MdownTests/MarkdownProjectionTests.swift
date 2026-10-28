import XCTest
@testable import Mdown

/// T03: display/source 投影与双向映射。
final class MarkdownProjectionTests: XCTestCase {

    private let parser = LosslessMarkdownParser()
    private let builder = MarkdownProjectionBuilder()

    private func projection(of blockText: String, as kind: LosslessMarkdownParser.BlockKind? = nil) -> MarkdownProjectionBuilder.Projection {
        let doc = parser.parse(blockText)
        let block =
            doc.blocks.first { b in
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
        let content = p.segments.first { $0.kind == .strongBody && $0.displayText == "AB" }
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
        XCTAssertEqual(p.display, "*文字*\n")
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
        let label = p.segments.first { $0.kind == .linkLabel && $0.displayText == "链接文字" }
        XCTAssertEqual(label?.sourceRangeUTF16, NSRange(location: 3, length: 4), "label 的 source 恰为括号内文字")
    }

    func testImageShowsPlaceholder() {
        let p = projection(of: "![本地缺失图片](/i/missing.png)\n")
        XCTAssertEqual(p.display, "本地缺失图片\n")
        let placeholder = p.segments.first { $0.kind == .attachmentPlaceholder }
        XCTAssertEqual(placeholder?.sourceRangeUTF16, NSRange(location: 0, length: 25), "图片占位作为完整引用映射")
    }

    func testHeadingMarkerHidden() {
        let p = projection(of: "## 二级标题\n", as: .heading(level: 2))
        XCTAssertEqual(p.display, "二级标题\n")
        XCTAssertEqual(p.segments.first?.kind, .hiddenMarker)
        XCTAssertEqual(p.segments.first?.sourceRangeUTF16, NSRange(location: 0, length: 3), "## 加空格")
    }

    /// 非首块 heading 的 marker 段必须是文档绝对坐标（与内容段一致），
    /// 不得回到块相对 0（会指向文档开头）。修复前 marker 段恒为 location 0。
    func testHeadingMarkerRangeIsDocumentAbsolute() {
        let source = "前段\n\n## 标\n"
        let p = projection(of: source, as: .heading(level: 2))
        XCTAssertEqual(p.display, "标\n")
        XCTAssertEqual(
            p.segments.first?.sourceRangeUTF16, NSRange(location: 4, length: 3),
            "marker 段起点 = 前面块的总长（\"前段\\n\\n\" = 4 个 UTF-16 单元）")
        XCTAssertEqual(
            p.segments.first?.displayRangeUTF16, NSRange(location: 0, length: 0),
            "finalize 后零显示长段不得残留 -1 哨兵")
        XCTAssertEqual(p.displayOffset(forSource: 4), 0, "source 块起点映射到 display 0，不得返回哨兵 -1")
    }

    /// 懒延续行（无 marker 的容器延续行）首字符不得被并入隐藏 marker 段。
    /// 修复前 max(1, 0) 会吞掉 "- 一\n二" 中 "二" 的首字符。
    func testLazyContinuationKeepsFirstCharacter() {
        let list = projection(of: "- 一\n二\n", as: .listItem(depth: 0, ordered: false))
        XCTAssertEqual(list.display, "一\n二\n", "懒延续行首字符必须完整显示")

        let quote = projection(of: "> 引\n用\n", as: .quote(depth: 1))
        XCTAssertEqual(quote.display, "引\n用\n")

        // 空 quote 行（">\n"）的换行留在 display，不被前缀段吞掉
        let emptyQuoteLine = projection(of: ">\n>\n", as: .quote(depth: 1))
        XCTAssertEqual(emptyQuoteLine.display, "\n\n", "空 quote 行的换行必须保留")
    }

    /// 非首块的保护块（code fence 等）plain 投影段必须是文档绝对坐标：
    /// textDidChange 把段的 source 坐标当文档全局用，块相对 0 会把
    /// 非首块 fence 的编辑全部打到文档开头。
    func testPlainFallbackUsesDocumentAbsoluteRange() {
        let source = "正文段。\n\n```js\nx\n```\n"
        let fenceOffset = "正文段。\n\n".utf16.count  // 6
        let p = projection(of: source, as: .codeFence(info: "js"))
        XCTAssertEqual(p.segments.count, 1)
        XCTAssertEqual(p.segments[0].sourceRangeUTF16, NSRange(location: fenceOffset, length: 12))
        XCTAssertEqual(p.sourceOffset(forDisplay: 0), fenceOffset, "编辑 fence 首字符必须映射到 fence 块起点而非 0")
    }

    /// marker 前缀只吃缩进 + 一个 marker + 空白：`- **bold**` 不得把
    /// "- **" 整段当 marker 隐藏（会留下残缺的 "bold**"）。
    func testListItemPrefixDoesNotSwallowInlineMarkers() {
        let p = projection(of: "- **bold**\n", as: .listItem(depth: 0, ordered: false))
        XCTAssertEqual(p.display, "bold\n", "行内 emphasis 由 inline 扫描隐藏，marker 前缀只隐藏 '- '")
        let markers = p.segments.filter { $0.kind == .hiddenMarker }
        // 行前缀 1 个 + emphasis 前后各 1 个 = 3；不得出现吞掉 "**" 的前缀段
        XCTAssertEqual(markers.count, 3)
        XCTAssertEqual(markers[0].sourceRangeUTF16, NSRange(location: 0, length: 2), "前缀段恰为 '- '")
    }

    /// 转义的 emphasis marker（`\*`）不是闭符：`*a\*b*` 的闭符是末尾 `*`。
    func testEscapedMarkerIsNotTreatedAsClosing() {
        let p = projection(of: "*a\\*b*\n")
        XCTAssertEqual(p.display, "a\\*b\n", "外层 * 与末尾 * 配对，中间 \\* 保留为内容")
        let markers = p.segments.filter { $0.kind == .hiddenMarker }
        XCTAssertEqual(markers.count, 2, "只有首尾两个 * 被隐藏，转义的 \\* 不得当闭符")
    }

    /// 行内扫描不得跨行配对：列表两行各有一个反引号时保持原样，
    /// 不把后行的 backtick 吞进前行（内容会重复显示）。
    func testCodeSpanDoesNotPairAcrossLines() {
        let p = projection(of: "- a `x\nb` c\n", as: .listItem(depth: 0, ordered: false))
        XCTAssertEqual(p.display, "a `x\nb` c\n", "跨行的单个反引号无配对，原样显示")
        XCTAssertFalse(p.segments.contains { $0.kind == .codeSpan })
    }

    func testFenceContentStripsFences() {
        // 标准:开/闭围栏行剥除,内容行间换行保留
        XCTAssertEqual(
            MarkdownProjectionBuilder.fenceContent(of: "```mermaid\nflowchart LR\nA-->B\n```\n"),
            "flowchart LR\nA-->B\n")
        // EOF 无闭围栏:内容到块尾(与 consumeFence 的截断语义一致)
        XCTAssertEqual(
            MarkdownProjectionBuilder.fenceContent(of: "~~~mermaid\nA-->B\n"),
            "A-->B\n")
        // 嵌套围栏:CRLF 字节原样保留,短围栏行是内容不是闭围栏
        XCTAssertEqual(
            MarkdownProjectionBuilder.fenceContent(of: "````mermaid\r\n```\r\n````\r\n"),
            "```\r\n")
    }

    func testProtectedBlocksFallBackPlain() throws {
        let fence = projection(of: "```text\n内部 **不解析**\n```\n", as: .codeFence(info: "text"))
        XCTAssertTrue(fence.segments.allSatisfy { $0.kind == .plainFallback })
        XCTAssertEqual(fence.display, "```text\n内部 **不解析**\n```\n", "fence 内容必须逐字节原样")
    }

    /// ND-04 表格网格投影:cell 内容 1:1、管道/分隔行隐藏、尾部填充列对齐;
    /// 内容区映射 1:1,填充区映射到 cell 源末尾。
    func testTableCellsProjectToGrid() throws {
        let source = "| a\\|b | c |\n| --- | --- |\n| 1 | 2 |\n"
        let table = projection(of: source, as: .table)
        XCTAssertTrue(table.segments.contains { $0.kind == .tableCell }, "cell 必须投影")
        XCTAssertFalse(table.segments.contains { $0.kind == .plainFallback })
        XCTAssertFalse(table.display.contains("|"), "管道必须隐藏")
        XCTAssertFalse(table.display.contains("---"), "分隔行必须隐藏")
        XCTAssertTrue(table.display.contains("a\\|b"), "cell 内容原样")

        let ns = source as NSString
        let cellRange = ns.range(of: "a\\|b")
        let firstCell = try XCTUnwrap(table.segments.first { $0.kind == .tableCell })
        XCTAssertEqual(firstCell.sourceRangeUTF16, cellRange)
        XCTAssertEqual(
            table.sourceOffset(forDisplay: firstCell.displayRangeUTF16.location),
            cellRange.location, "内容起点映射 1:1")
        XCTAssertEqual(
            table.sourceOffset(forDisplay: NSMaxRange(firstCell.displayRangeUTF16) - 1),
            NSMaxRange(cellRange), "填充/间隙区映射到 cell 源末尾")
        XCTAssertEqual(
            table.displayOffset(forSource: cellRange.location),
            firstCell.displayRangeUTF16.location, "source→display 内容区 1:1")
    }

    func testFenceContentNeverEntersInlineSegments() {
        let doc = parser.parse("```text\n含 **marker** 与 [链接](url)\n```\n后段 **加粗**\n")
        let fenceBlock = doc.blocks.first {
            if case .codeFence = $0.kind { return true }; return false
        }!
        let p = builder.buildProjection(for: fenceBlock, in: doc)
        XCTAssertFalse(
            p.segments.contains { $0.kind == .hiddenMarker || $0.kind == .text && $0.displayText.contains("链接") },
            "fence 内容不得被 inline 扫描")
    }

    func testDisplayAndSourceOffsetsRoundTripOnBoundaries() {
        let source = "**AB** 普通 `code` [L](url) 尾\n"
        let p = projection(of: source)
        // 不变量：所有段边界（location 与 maxRange）经 display↔source 复合后
        // 仍落在段边界集合内。hidden marker 段内部偏移在 display 无表面，
        // 允许折叠到相邻段边界（SPEC 的 affinity 语义由 T04 caret 层处理）。
        let boundaries = Set(
            p.segments.flatMap {
                [
                    $0.sourceRangeUTF16.location,
                    NSMaxRange($0.sourceRangeUTF16),
                ]
            })
        for boundary in boundaries {
            guard let d = p.displayOffset(forSource: boundary),
                let back = p.sourceOffset(forDisplay: d)
            else {
                return XCTFail("边界 \(boundary) 映射不得失败")
            }
            XCTAssertTrue(
                boundaries.contains(back),
                "边界 \(boundary) 往返 \(back) 必须仍是段边界（不得落进段内部）")
        }
        // 非折叠段：内部中点往返必须恒等
        for segment in p.segments
        where segment.displayRangeUTF16.length > 0
            && segment.kind != .hiddenMarker && segment.kind != .linkDestination
        {
            let mid = segment.sourceRangeUTF16.location + max(1, segment.sourceRangeUTF16.length / 2)
            guard mid < NSMaxRange(segment.sourceRangeUTF16) else { continue }
            guard let d = p.displayOffset(forSource: mid),
                let back = p.sourceOffset(forDisplay: d)
            else { continue }
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
