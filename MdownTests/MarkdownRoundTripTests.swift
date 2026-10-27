import XCTest
@testable import Mdown

/// T03: 无损性——块切片重建 == 原文，特征字节保留。
final class MarkdownRoundTripTests: XCTestCase {

    private let parser = LosslessMarkdownParser()

    private func roundTrip(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try NativeFixtureLoader.loadString(name)
        let doc = parser.parse(source)

        XCTAssertTrue(doc.isLossless, "\(name)：块联合必须覆盖全文", file: file, line: line)

        // 重建 oracle：按块切片重拼 == 原文（逐字节）
        let ns = source as NSString
        var rebuilt = ""
        for block in doc.blocks {
            rebuilt += ns.substring(with: block.rangeUTF16)
        }
        XCTAssertEqual(rebuilt, source, "\(name)：切片重建必须等于原文", file: file, line: line)
        XCTAssertEqual(Array(rebuilt.utf8), Array(source.utf8), "\(name)：UTF-8 字节逐一致", file: file, line: line)
    }

    func testAllFixturesRoundTrip() throws {
        for name in [
            "editor-behavior.md", "roundtrip-crlf.md",
            "roundtrip-no-final-newline.md", "bom-utf8.md",
            "mixed-eol.md", "tabs.md", "bad-math.md",
        ] {
            try roundTrip(name)
        }
    }

    func testEmptyAndSingleLineSources() {
        let empty = parser.parse("")
        XCTAssertTrue(empty.isLossless)

        let single = parser.parse("唯一一行")
        XCTAssertTrue(single.isLossless)
        XCTAssertEqual(single.blocks.count, 1)
        XCTAssertEqual(single.blocks.first?.kind, .paragraph)
    }

    func testOnlyFrontmatterStillLossless() {
        let source = "---\ntitle: x\n---\n"
        let doc = parser.parse(source)
        XCTAssertTrue(doc.isLossless)
        XCTAssertEqual(doc.blocks.first?.kind, .frontmatter)
        XCTAssertEqual(doc.blocks.first?.startLine, 1)
        XCTAssertEqual(doc.blocks.first?.endLine, 3)
    }

    func testCRLFStaysInsideBlockSlices() throws {
        let source = try NativeFixtureLoader.loadString("roundtrip-crlf.md")
        XCTAssertTrue(source.contains("\r\n"))
        let doc = parser.parse(source)
        // 任何块的切片都不切断 CRLF（块边界都是行边界）
        let ns = source as NSString
        for block in doc.blocks {
            let slice = ns.substring(with: block.rangeUTF16)
            XCTAssertFalse(
                slice.hasSuffix("\r"),
                "块不得结束在 CR 与 LF 之间：\(block)")
        }
    }

    func testBOMStaysInFirstBlockSlice() throws {
        let source = try NativeFixtureLoader.loadString("bom-utf8.md")
        let doc = parser.parse(source)
        let ns = source as NSString
        let first = ns.substring(with: doc.blocks[0].rangeUTF16)
        XCTAssertTrue(first.hasPrefix("\u{FEFF}"), "BOM 必须留在第一块切片内")
    }

    func testFrontmatterDelimitsSubsequentBlocks() throws {
        let source = try NativeFixtureLoader.loadString("editor-behavior.md")
        let doc = parser.parse(source)
        XCTAssertEqual(doc.blocks.first?.kind, .frontmatter, "editor-behavior.md 以 frontmatter 开头")
        // frontmatter 后应出现 heading（## 1. Unicode 与输入法）
        let afterFrontmatter = doc.blocks.dropFirst().prefix(3)
        XCTAssertTrue(
            afterFrontmatter.contains {
                if case .heading = $0.kind { return true }; return false
            },
            "frontmatter 之后应有 heading 块")
    }
}
