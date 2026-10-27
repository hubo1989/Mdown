import CMarkGFM
import XCTest
@testable import Mdown

/// T03: 块结构 + cmark sourcepos 对照（pin cmark 行为：1-based line、
/// 列按 UTF-8 byte、container 节点 end 不准确——在此固定为已知差异）。
final class LosslessMarkdownParserTests: XCTestCase {

    private let parser = LosslessMarkdownParser()

    func testBlockKindSequenceOnEditorBehaviorFixture() throws {
        let source = try NativeFixtureLoader.loadString("editor-behavior.md")
        let doc = parser.parse(source)
        XCTAssertTrue(doc.isLossless)

        // 关键块存在性 spot check
        let kinds = doc.blocks.map(\.kind)
        XCTAssertTrue(
            kinds.contains {
                if case .frontmatter = $0 { return true }; return false
            })
        XCTAssertTrue(
            kinds.contains {
                if case .heading = $0 { return true }; return false
            })
        XCTAssertTrue(
            kinds.contains {
                if case .listItem = $0 { return true }; return false
            })
        XCTAssertTrue(
            kinds.contains {
                if case .codeFence = $0 { return true }; return false
            })
        XCTAssertTrue(
            kinds.contains {
                if case .table = $0 { return true }; return false
            })
        XCTAssertTrue(
            kinds.contains {
                if case .quote = $0 { return true }; return false
            })
    }

    func testFencedCodeBlockSpansToClosingFence() {
        let source = "```swift\nlet a = 1\n```\n后文\n"
        let doc = parser.parse(source)
        XCTAssertEqual(doc.blocks.count, 3, "fence + 段落 + 末尾换行产生的 blank 块")
        guard case .codeFence(let info) = doc.blocks[0].kind else {
            return XCTFail("第一块应为 codeFence，实际 \(doc.blocks[0].kind)")
        }
        XCTAssertEqual(info, "swift")
        XCTAssertEqual(doc.blocks[0].startLine, 1)
        XCTAssertEqual(doc.blocks[0].endLine, 3)
        XCTAssertEqual(doc.blocks[1].kind, .paragraph)
    }

    /// 缩进 fence（≤3 空格，CommonMark 合法，列表内嵌 fence 的常见形态）：
    /// info 不得串入反引号，块内空行不得提前闭合 fence。
    /// 修复前 openLen 按原始行计算恒为 0，闭 fence 判定退化为恒真。
    func testIndentedFenceKeepsInfoAndSpansPastBlankLine() {
        let source = "  ```swift\nlet a = 1\n\nlet b = 2\n  ```\n后文\n"
        let doc = parser.parse(source)
        XCTAssertTrue(doc.isLossless)
        guard case .codeFence(let info) = doc.blocks[0].kind else {
            return XCTFail("缩进 fence 应为 codeFence，实际 \(doc.blocks[0].kind)")
        }
        XCTAssertEqual(info, "swift", "info 必须剥掉缩进与反引号")
        XCTAssertEqual(doc.blocks[0].startLine, 1)
        XCTAssertEqual(doc.blocks[0].endLine, 5, "块内空行（第 3 行）不得提前闭合 fence")
        XCTAssertEqual(doc.blocks[1].kind, .paragraph, "闭合 fence 之后的行回到段落")
    }

    /// ≥4 空格（或 1 tab）缩进的开 fence 行是 indented code，不是 fence
    /// （CommonMark 内容列规则）。
    func testFourSpaceAndTabIndentedFenceIsIndentedCode() {
        let fourSpace = parser.parse("    ```js\nlet x\n")
        XCTAssertTrue(
            fourSpace.blocks.contains {
                if case .codeIndented = $0.kind { return true }; return false
            },
            "4 空格缩进的 ``` 行应为 indented code")
        XCTAssertFalse(
            fourSpace.blocks.contains {
                if case .codeFence = $0.kind { return true }; return false
            })

        let tabbed = parser.parse("\t```js\nlet x\n")
        XCTAssertTrue(
            tabbed.blocks.contains {
                if case .codeIndented = $0.kind { return true }; return false
            },
            "tab 缩进的 ``` 行应为 indented code")
        XCTAssertFalse(
            tabbed.blocks.contains {
                if case .codeFence = $0.kind { return true }; return false
            })
    }

    /// ≥4 空格（或 1 tab）缩进的 `#` 行是 indented code，不是 heading
    /// （CommonMark 内容列规则；与 fence 的同类规则一致）。
    func testFourSpaceIndentedHeadingIsIndentedCode() {
        let fourSpace = parser.parse("    # 不是标题\n")
        XCTAssertTrue(
            fourSpace.blocks.contains {
                if case .codeIndented = $0.kind { return true }; return false
            },
            "4 空格缩进的 # 行应为 indented code")
        XCTAssertFalse(
            fourSpace.blocks.contains {
                if case .heading = $0.kind { return true }; return false
            })

        let indented = parser.parse("  # 是标题\n")
        XCTAssertTrue(
            indented.blocks.contains {
                if case .heading = $0.kind { return true }; return false
            },
            "1-3 空格缩进的 # 行仍是 heading")
    }

    /// table header 前还有段落行（懒延续并入同一段落块）时，段落前缀
    /// 行必须保留覆盖，否则 isLossless 破（块联合出现缺口）。
    func testTableWithPrecedingParagraphLinesStaysLossless() {
        let source = "引言行\n表头 | 列\n| --- | --- |\n| 1 | 2 |\n"
        let doc = parser.parse(source)
        XCTAssertTrue(doc.isLossless, "段落前缀行 + table 必须联合覆盖全文")
        if case .paragraph = doc.blocks[0].kind {
        } else {
            return XCTFail("首块应为保留下的段落前缀行，实际 \(doc.blocks[0].kind)")
        }
        XCTAssertEqual(doc.blocks[0].startLine, 1)
        XCTAssertEqual(doc.blocks[0].endLine, 1, "段落截到 header 行之前")
        guard case .table = doc.blocks[1].kind else {
            return XCTFail("第二块应为 table，实际 \(doc.blocks[1].kind)")
        }
        XCTAssertEqual(doc.blocks[1].startLine, 2, "table 从 header 行起")
    }

    func testNestedFenceRequiresLongerClosingFence() throws {
        // editor-behavior.md 的 ````text 外层 fence 包含 ```swift 内层
        let source = try NativeFixtureLoader.loadString("editor-behavior.md")
        let doc = parser.parse(source)
        let ns = source as NSString
        let fenceBlocks = doc.blocks.filter {
            if case .codeFence = $0.kind { return true }
            return false
        }
        // 至少存在一个 4-backtick 外层 fence，其切片包含内层 ``` 行
        let outer = fenceBlocks.first { block in
            let slice = ns.substring(with: block.rangeUTF16)
            return slice.hasPrefix("````")
        }
        let outerBlock = try XCTUnwrap(outer, "应识别 ````text 外层 fence")
        let slice = ns.substring(with: outerBlock.rangeUTF16)
        XCTAssertTrue(slice.contains("```swift"), "外层 fence 切片应包含内层三反引号行")
        XCTAssertTrue(slice.hasSuffix("````\n"), "外层 fence 应以 ```` 闭合并含换行")
    }

    func testTableBlockIncludesHeaderDelimiterAndRows() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |\n\n段落\n"
        let doc = parser.parse(source)
        XCTAssertTrue(doc.isLossless)
        guard
            let table = doc.blocks.first(where: {
                if case .table = $0.kind { return true }; return false
            })
        else {
            return XCTFail("应识别 table 块")
        }
        XCTAssertEqual(table.startLine, 1)
        XCTAssertEqual(table.endLine, 3)
    }

    // MARK: - cmark sourcepos 对照（pin）

    /// cmark（CMARK_OPT_SOURCEPOS）的 heading/code fence 节点行号必须与
    /// 行扫描一致；列按 UTF-8 byte 计（tab=1、中文多 byte）。
    func testCmarkSourcePosMatchesLineScannerForHeadingAndFence() {
        let source = "# 标题一\n\n正文段。\n\n```swift\nlet x = \"中文\"\n```\n"
        let doc = parser.parse(source)

        cmark_gfm_core_extensions_ensure_registered()
        guard let cparser = cmark_parser_new(CMARK_OPT_SOURCEPOS | CMARK_OPT_FOOTNOTES) else {
            return XCTFail("cmark parser 创建失败")
        }
        defer { cmark_parser_free(cparser) }
        cmark_parser_feed(cparser, source, source.utf8.count)
        guard let root = cmark_parser_finish(cparser) else {
            return XCTFail("cmark finish 失败")
        }
        defer { cmark_node_free(root) }

        // 收集 cmark 顶层 heading / code_block 的行号
        var cmarkHeadings: [(Int, Int)] = []
        var cmarkFences: [(Int, Int)] = []
        var child = cmark_node_first_child(root)
        while let node = child {
            switch cmark_node_get_type(node) {
            case CMARK_NODE_HEADING:
                cmarkHeadings.append((Int(cmark_node_get_start_line(node)), Int(cmark_node_get_end_line(node))))
            case CMARK_NODE_CODE_BLOCK:
                cmarkFences.append((Int(cmark_node_get_start_line(node)), Int(cmark_node_get_end_line(node))))
            default:
                break
            }
            child = cmark_node_next(node)
        }

        XCTAssertEqual(cmarkHeadings.count, 1, "cmark heading 行号（中文内容不影响行号）")
        XCTAssertEqual(cmarkHeadings.first?.0, 1)
        XCTAssertEqual(cmarkHeadings.first?.1, 1)
        XCTAssertEqual(cmarkFences.count, 1, "cmark code fence 行号（含开闭 fence 行）")
        XCTAssertEqual(cmarkFences.first?.0, 5)
        XCTAssertEqual(cmarkFences.first?.1, 7)

        let scannerHeading = doc.blocks.first {
            if case .heading = $0.kind { return true }; return false
        }
        XCTAssertEqual(scannerHeading?.startLine, 1)
        XCTAssertEqual(scannerHeading?.endLine, 1)
        let scannerFence = doc.blocks.first {
            if case .codeFence = $0.kind { return true }; return false
        }
        XCTAssertEqual(scannerFence?.startLine, 5)
        XCTAssertEqual(scannerFence?.endLine, 7)
    }

    /// pin：cmark 列按 UTF-8 byte 计（中文 3 byte/字），tab 计 1 byte。
    func testCmarkColumnsAreUTF8Bytes() {
        let source = "# 标题行中文"
        cmark_gfm_core_extensions_ensure_registered()
        guard let cparser = cmark_parser_new(CMARK_OPT_SOURCEPOS) else { return XCTFail("parser") }
        defer { cmark_parser_free(cparser) }
        cmark_parser_feed(cparser, source, source.utf8.count)
        guard let root = cmark_parser_finish(cparser) else { return XCTFail("finish") }
        defer { cmark_node_free(root) }
        guard let heading = cmark_node_first_child(root),
            cmark_node_get_type(heading) == CMARK_NODE_HEADING
        else {
            return XCTFail("应为 heading")
        }
        // heading 起点列 1；终点列 = 全行 UTF-8 字节数（中文每字 3 byte）
        XCTAssertEqual(Int(cmark_node_get_start_column(heading)), 1)
        XCTAssertEqual(Int(cmark_node_get_end_column(heading)), source.utf8.count, "cmark end_column 按 UTF-8 byte 计")

        // utf16Offset 换算验证：列(1-based byte) → UTF-16
        let doc = parser.parse(source)
        XCTAssertEqual(doc.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertEqual(doc.utf16Offset(line: 1, utf8Column: 1 + "# 标题行".utf8.count), 5)
    }

    func testCRLFLineNumbersAgreeWithScanner() throws {
        let source = try NativeFixtureLoader.loadString("roundtrip-crlf.md")
        let doc = parser.parse(source)

        cmark_gfm_core_extensions_ensure_registered()
        guard let cparser = cmark_parser_new(CMARK_OPT_SOURCEPOS) else { return XCTFail("parser") }
        defer { cmark_parser_free(cparser) }
        cmark_parser_feed(cparser, source, source.utf8.count)
        guard let root = cmark_parser_finish(cparser) else { return XCTFail("finish") }
        defer { cmark_node_free(root) }

        var cmarkHeadings: [(Int, Int)] = []
        var child = cmark_node_first_child(root)
        while let node = child {
            if cmark_node_get_type(node) == CMARK_NODE_HEADING {
                cmarkHeadings.append((Int(cmark_node_get_start_line(node)), Int(cmark_node_get_end_line(node))))
            }
            child = cmark_node_next(node)
        }
        let scannerHeadings = doc.blocks.compactMap { block -> (Int, Int)? in
            guard case .heading = block.kind else { return nil }
            return (block.startLine, block.endLine)
        }
        // pin 已知差异：cmark 无 frontmatter 概念，`title:...` + `---`（无空行）
        // 被解析为 setext heading；行扫描器把 `---` 开栏整体当 frontmatter。
        // 因此 cmark heading 集是扫描器集合加上 setext 伪 heading。
        let cmarkSet = Set(cmarkHeadings.map { "\($0.0)-\($0.1)" })
        for scanner in scannerHeadings {
            XCTAssertTrue(
                cmarkSet.contains("\(scanner.0)-\(scanner.1)"),
                "扫描器 heading \(scanner) 必须与 cmark ATX heading 一致（CRLF 当单换行）")
        }
        XCTAssertFalse(scannerHeadings.isEmpty)
    }

    func testTabIndentedLineBecomesIndentedCode() throws {
        let source = try NativeFixtureLoader.loadString("tabs.md")
        let doc = parser.parse(source)
        XCTAssertTrue(doc.isLossless)
        // G0 修复后：`\t- tab 缩进二级`（紧跟列表项）正确分类为嵌套 listItem，
        // 不再误分为 codeIndented（此前条件恒 false 的 bug）。
        XCTAssertTrue(
            doc.blocks.contains {
                if case .listItem = $0.kind { return true }; return false
            },
            "tab 缩进的嵌套列表应识别为 listItem")
        // 非列表的 tab 缩进行（不在 fence 内）仍应识别为 indented code。
        let codeSource = "# t\n\n\tnon-list tab line\n"
        let codeDoc = parser.parse(codeSource)
        XCTAssertTrue(
            codeDoc.blocks.contains {
                if case .codeIndented = $0.kind { return true }; return false
            },
            "非列表的 \\t 开头行应识别为 indented code")
    }
}

extension LosslessMarkdownParserTests {
    /// T03 诊断输出（保留：失败排查用）。
    func testDebugDumpBlocksOnFixtures() throws {
        for name in ["editor-behavior.md", "bom-utf8.md"] {
            let source = try NativeFixtureLoader.loadString(name)
            let doc = parser.parse(source)
            print("=== \(name) lossless=\(doc.isLossless) blocks=\(doc.blocks.count)")
            if name == "bom-utf8.md" {
                print("  source.prefix(6)=\(source.prefix(6).unicodeScalars.map { String($0.value, radix: 16) })")
                print("  lineStarts=\(doc.lineStartUTF16.prefix(4)) total=\(source.utf16.count)")
            }
            for block in doc.blocks.prefix(12) {
                let ns = source as NSString
                let first = ns.substring(with: NSRange(location: block.rangeUTF16.location, length: min(1, block.rangeUTF16.length)))
                print("  L\(block.startLine)-\(block.endLine) \(block.kind) \(block.kind) range=\(block.rangeUTF16) first=\(first.debugDescription)")
            }
        }
    }
}

extension LosslessMarkdownParserTests {
    /// T03：乱序/迟到的 parse 结果不得覆盖更新的 document（200/500ms 注入
    /// 语义的确定性等价：提交顺序乱序化）。
    @MainActor
    func testOutOfOrderParseResultsDoNotOverrideNewer() {
        let coordinator = LosslessParseCoordinator()
        let d0 = parser.parse("版本零\n")
        let d1 = parser.parse("版本一\n")
        let d2 = parser.parse("版本二\n")

        XCTAssertTrue(coordinator.publish(d1, revision: 1))
        // 迟到的 rev0 与乱序的同 rev 结果全部拒绝
        XCTAssertFalse(coordinator.publish(d0, revision: 0))
        XCTAssertFalse(coordinator.publish(d1, revision: 1))
        XCTAssertTrue(coordinator.publish(d2, revision: 2))
        XCTAssertFalse(coordinator.publish(d1, revision: 1), "旧 revision 永远拒绝")

        XCTAssertEqual(coordinator.currentDocument?.source, "版本二\n", "最新 projection 必须收敛到最新 revision")
        XCTAssertEqual(coordinator.currentRevision, 2)
    }
}
