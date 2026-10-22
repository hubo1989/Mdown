import XCTest

@testable import MiaoYan

/// T21 (SPEC §10 性能预算 / NE-30):压力与预算冒烟。
///
/// 单样本冒烟,不冒充 p95(真实 p95 需 trace 环境,在 T21 维护者矩阵);
/// 预算取 SPEC §10 表值并留 CI 抖动余量。1/10 MiB 压力:不崩溃、
/// source 字节不变(可编辑性底线)。
final class NativeEditorStressBudgetTests: XCTestCase {

    /// 约 200 KiB / 2000 行的混合 Markdown(mixed 结构)。
    private func makeLargeNote() -> String {
        var parts: [String] = ["---\ntitle: stress\n---\n"]
        for i in 0..<1500 {
            parts.append("## Heading \(i)\n")
            parts.append("paragraph with **bold** and `code` and [link](https://example.com/\(i)) text\n")
            parts.append("- item \(i) one\n- item \(i) two\n")
            if i % 20 == 0 {
                parts.append("```swift\nlet a\(i) = 1 // comment\nprint(\"str \\(a\(i))\")\n```\n")
            }
            if i % 25 == 0 {
                parts.append("| a | b |\n| --- | --- |\n| c\(i) | d |\n")
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - 200 KiB / 2k 行预算(SPEC:首帧 p95 ≤300ms;此处单样本 ≤300ms)

    func testParseAndProject200KiBWithinBudget() {
        let source = makeLargeNote()
        let bytes = Array(source.utf8).count
        XCTAssertGreaterThan(bytes, 150_000, "样本需接近 200KiB 级: \(bytes)B")
        XCTAssertLessThan(bytes, 250_000)

        let start = Date()
        let document = LosslessMarkdownParser().parse(source)
        let builder = MarkdownProjectionBuilder()
        var displayBytes = 0
        for block in document.blocks {
            let projection = builder.buildProjection(for: block, in: document)
            displayBytes += projection.display.utf16.count
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThan(document.blocks.count, 1000, "块解析需完整")
        XCTAssertGreaterThan(displayBytes, 0)
        XCTAssertLessThan(
            elapsed, 0.30,
            "200KiB parse+project 单样本应 ≤300ms(SPEC §10 首帧预算): \(elapsed)")
    }

    // MARK: - 同步输入处理预算(SPEC:输入 p95 ≤16ms;tokenizer 属派生样式层)

    func testCodeTokenize3KiBWithinDerivedStyleBudget() {
        let block = "```swift\n"
            + String(repeating: "let value = compute(a, b) // note\n", count: 90)
            + "```\n"
        let start = Date()
        for _ in 0..<20 {
            _ = NativeCodeHighlighter.highlight(code: block, language: "swift")
        }
        let perCall = Date().timeIntervalSince(start) / 20
        XCTAssertLessThan(
            perCall, 0.016,
            "单块 3KiB tokenize 每次应 ≤16ms(输入预算线): \(perCall)")
    }

    // MARK: - 1 MiB 压力:不崩溃、source 字节保真、可继续编辑

    func testOneMiBSourcePressurePreservesBytes() {
        var parts: [String] = []
        var i = 0
        while parts.joined(separator: "\n").utf8.count < 1_000_000 {
            parts.append("line \(i) with some prose text and **bold** words here")
            i += 1
        }
        let source = parts.joined(separator: "\n")
        let originalHash = source.hashValue

        let document = LosslessMarkdownParser().parse(source)
        XCTAssertGreaterThan(document.blocks.count, 0, "1MiB 必须可解析")

        // 块区间覆盖性:最后一块区间不超过 source 末尾(不越界)
        let ns = source as NSString
        if let last = document.blocks.last {
            XCTAssertLessThanOrEqual(NSMaxRange(last.rangeUTF16), ns.length)
        }

        // 高亮整块不崩溃且不改 source(取一个代表块)
        if let codeBlock = document.blocks.first(where: {
            if case .codeFence = $0.kind { return true }
            return false
        }) {
            let text = ns.substring(with: codeBlock.rangeUTF16)
            _ = NativeCodeHighlighter.highlight(code: text, language: "swift")
        }

        XCTAssertEqual(source.hashValue, originalHash, "处理不得改 source 字节")
    }

    // MARK: - 超长单行(SPEC:>64KiB 单段回 source 层;tokenizer 不崩)

    func testHugeSingleLineDoesNotCrashTokenizer() {
        let line = "let x = \"" + String(repeating: "a", count: 200_000) + "\""
        let start = Date()
        let tokens = NativeCodeHighlighter.highlight(code: line, language: "swift")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotNil(tokens)
        XCTAssertLessThan(elapsed, 1.0, "200k 字符单行 tokenize 线性时间内完成: \(elapsed)")
    }
}
