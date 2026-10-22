import XCTest

@testable import MiaoYan

/// T15 (SPEC §8.1 / NE-26 / AC-12)：NativeCodeHighlighter 的语言 corpus。
///
/// 固定每类语言:token 类别与边界(按「token 全文 + 类别」锚定,文本一致即
/// span 一致)、注释/string/转义/Unicode 容错、**source 完全不变**(高亮不
/// 产出正规化正文:token 不越界、不重叠)、未知语言 nil(plain code)。
/// 颜色映射不在本套件(view 层职责);这里只断言 token 化结果。
final class NativeCodeHighlighterTests: XCTestCase {

    // MARK: - 公共不变量

    private func assertTokens(
        _ code: String, language: String,
        contains expected: [(String, NativeCodeTokenKind)],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let tokens = NativeCodeHighlighter.highlight(code: code, language: language) else {
            XCTFail("\(language) 应受支持", file: file, line: line)
            return
        }
        let ns = code as NSString
        // source 完全不变:token 不得越界、不得重叠
        var covered = Array(repeating: false, count: ns.length)
        for token in tokens {
            guard token.range.location >= 0, token.range.length > 0,
                NSMaxRange(token.range) <= ns.length
            else {
                XCTFail("\(language) token 越界/空: \(token.range)", file: file, line: line)
                continue
            }
            for i in token.range.location..<NSMaxRange(token.range) {
                XCTAssertFalse(
                    covered[i], "\(language) token 重叠于 \(i)", file: file, line: line)
                covered[i] = true
            }
        }
        for (text, kind) in expected {
            let hit = tokens.first { $0.kind == kind && ns.substring(with: $0.range) == text }
            XCTAssertNotNil(
                hit, "\(language) 缺少 \(kind) '\(text)';实际: " + describe(tokens, in: code),
                file: file, line: line)
        }
    }

    private func describe(_ tokens: [NativeCodeToken], in code: String) -> String {
        let ns = code as NSString
        return tokens.map { "\($0.kind)('\(ns.substring(with: $0.range))')" }
            .joined(separator: ", ")
    }

    // MARK: - Swift

    func testSwiftTokens() {
        assertTokens(
            """
            import Foundation
            // 行注释
            let greeting = "hello \\(name) ok"
            /* 块注释 */
            struct Runner {
                func run(times: Int) -> Bool { times > 0 }
            }
            """,
            language: "swift",
            contains: [
                ("import", .keyword),
                ("// 行注释", .comment),
                ("let", .keyword),
                ("\"hello \\(name) ok\"", .string),
                ("/* 块注释 */", .comment),
                ("struct", .keyword),
                ("Runner", .type),
                ("func", .keyword),
                ("Int", .type),
                ("Bool", .type),
            ])
    }

    func testSwiftUnicodeStringBoundary() {
        // emoji / CJK 不切代理对;string token 覆盖整个字面量(含 2 单元 emoji)
        assertTokens(
            "let s = \"中文🙂tail\" // 注释🙂",
            language: "swift",
            contains: [
                ("let", .keyword),
                ("\"中文🙂tail\"", .string),
                ("// 注释🙂", .comment),
            ])
    }

    // MARK: - C / Objective-C

    func testCTokens() {
        assertTokens(
            "#include <stdio.h>\n/* main */ int main(void) { // api\n  return 0;\n}\n",
            language: "c",
            contains: [
                ("#include", .keyword),
                ("/* main */", .comment),
                ("int", .keyword),
                ("// api", .comment),
                ("return", .keyword),
                ("0", .number),
            ])
    }

    func testObjectiveCStringEscape() {
        assertTokens(
            "NSString *s = @\"a\\\"b\";",
            language: "objc",
            contains: [
                ("@\"a\\\"b\"", .string),
                ("NSString", .type),
            ])
    }

    // MARK: - JavaScript / TypeScript

    func testJavaScriptTokens() {
        assertTokens(
            "const url = `tmpl ${x}`; // note\nfunction f(n) { return n ?? null; }",
            language: "javascript",
            contains: [
                ("const", .keyword),
                ("`tmpl ${x}`", .string),
                ("// note", .comment),
                ("function", .keyword),
                ("return", .keyword),
                ("null", .literal),
            ])
    }

    // MARK: - Python

    func testPythonTokens() {
        assertTokens(
            "# head\ndef run(n: int) -> str:\n    return f\"n={n}\"\n",
            language: "python",
            contains: [
                ("# head", .comment),
                ("def", .keyword),
                ("int", .keyword),
                ("str", .keyword),
                ("return", .keyword),
                ("f\"n={n}\"", .string),
            ])
    }

    // MARK: - JSON

    func testJSONTokens() {
        assertTokens(
            "{\"k\": [1, 2.5e3, true, null], \"s\": \"v\"}",
            language: "json",
            contains: [
                ("\"k\"", .property),
                ("1", .number),
                ("2.5e3", .number),
                ("true", .literal),
                ("null", .literal),
                ("\"s\"", .property),
                ("\"v\"", .string),
            ])
    }

    // MARK: - HTML / CSS

    func testHTMLTokens() {
        assertTokens(
            "<!-- c --><p class=\"a\">text</p>",
            language: "html",
            contains: [
                ("<!-- c -->", .comment),
                ("<p", .tag),
                ("class", .attribute),
                ("\"a\"", .string),
                ("</p>", .tag),
            ])
    }

    func testCSSTokens() {
        assertTokens(
            "/* base */ .btn { color: #fff; margin: 0 auto; }",
            language: "css",
            contains: [
                ("/* base */", .comment),
                ("color", .property),
                ("#fff", .number),
                ("margin", .property),
                ("0", .number),
            ])
    }

    // MARK: - Shell / SQL / YAML

    func testShellTokens() {
        assertTokens(
            "#!/bin/bash\n# set up\necho \"hi $USER\"\nif [ -n \"$x\" ]; then exit 0; fi",
            language: "shell",
            contains: [
                ("#!/bin/bash", .comment),
                ("# set up", .comment),
                ("echo", .keyword),
                ("\"hi $USER\"", .string),
                ("if", .keyword),
                ("then", .keyword),
                ("exit", .keyword),
                ("0", .number),
            ])
    }

    func testSQLTokens() {
        assertTokens(
            "-- q1\nSELECT id, name FROM users WHERE age > 18; -- filter",
            language: "sql",
            contains: [
                ("-- q1", .comment),
                ("SELECT", .keyword),
                ("FROM", .keyword),
                ("WHERE", .keyword),
                ("18", .number),
                ("-- filter", .comment),
            ])
    }

    func testYAMLTokens() {
        assertTokens(
            "# cfg\nname: miao\nport: 8080\nflag: true\n",
            language: "yaml",
            contains: [
                ("# cfg", .comment),
                ("name", .property),
                ("8080", .number),
                ("true", .literal),
            ])
    }

    // MARK: - 回归(审查发现的缺陷)

    func testNumbersDoNotSwallowOperatorsOrCommentOpeners() {
        assertTokens(
            "let n = 1+2 // x", language: "swift",
            contains: [("let", .keyword), ("1", .number), ("2", .number), ("// x", .comment)])
        assertTokens(
            "for i in 1...3 {}", language: "swift",
            contains: [("1", .number), ("3", .number)])
        assertTokens(
            "SELECT 1-- c\nFROM t", language: "sql",
            contains: [("1", .number), ("-- c", .comment), ("FROM", .keyword)])
    }

    func testPythonEmptyStringAndBareTripleQuoted() {
        assertTokens(
            "\"\"; print(1)", language: "python",
            contains: [("\"\"", .string), ("print", .keyword), ("1", .number)])
        assertTokens(
            "x = \"\"\"a\nb\"\"\"\nprint(1)", language: "python",
            contains: [("\"\"\"a\nb\"\"\"", .string), ("print", .keyword)])
    }

    func testSwiftNestedBlockCommentStaysOneComment() {
        assertTokens(
            "/* o /* i */ let hidden = 1 */ let visible = 2",
            language: "swift",
            contains: [
                ("/* o /* i */ let hidden = 1 */", .comment),
                ("let", .keyword),
            ])
    }

    func testCCharLiteralWithDoubleQuoteDoesNotOpenString() {
        assertTokens(
            "char q = '\"'; int n = 1;", language: "c",
            contains: [("'\"'", .string), ("int", .keyword), ("1", .number)])
    }

    func testJavaScriptTemplateSpansLines() {
        assertTokens(
            "const s = `a\n// b\nc`;\nconst n = 1;",
            language: "javascript",
            contains: [("`a\n// b\nc`", .string), ("const", .keyword), ("1", .number)])
    }

    // MARK: - 边界容错

    func testUnterminatedStringAndCommentDoNotCrashAndStayInBounds() {
        let code = "let s = \"unterminated\n// tail"
        assertTokens(
            code, language: "swift",
            contains: [
                ("let", .keyword),
                ("\"unterminated", .string),
                ("// tail", .comment),
            ])
    }

    func testUnknownLanguageReturnsNilForPlainFallback() {
        XCTAssertNil(NativeCodeHighlighter.highlight(code: "?:;", language: "cobol"))
        XCTAssertNil(NativeCodeHighlighter.highlight(code: "x", language: nil))
    }

    func testLanguageAliasesAreSupported() {
        for alias in [
            "swift", "objc", "objective-c", "c", "cpp", "c++", "js", "javascript",
            "ts", "typescript", "python", "json", "html", "css", "shell", "bash",
            "sql", "yaml", "yml",
        ] {
            XCTAssertNotNil(
                NativeCodeHighlighter.highlight(code: "x", language: alias),
                "别名 \(alias) 应受支持")
        }
    }

    @MainActor
    func testCodeBlockHighlighterAppliesNativeTokensAndKeepsSource() {
        let code = "let s = \"hi\" // c\n"
        let attr = NSMutableAttributedString(string: "```swift\n\(code)```\n")
        let range = NSRange(location: 0, length: attr.length)
        attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: range)
        let before = attr.string
        CodeBlockHighlighter.highlightCode(attributedString: attr, range: range, language: "swift")
        XCTAssertEqual(attr.string, before, "高亮不得改正文")
        // keyword 'let' 涂了非默认前景色(相对基础色)
        let ns = attr.string as NSString
        let letRange = ns.range(of: "let")
        let kw = attr.attribute(.foregroundColor, at: letRange.location, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(kw)
        XCTAssertNotEqual(kw, NSColor.black, "keyword 需要有 token 色")
    }

    func testVeryLongLineStaysWithinBudget() {
        let long = "let a = 1 // " + String(repeating: "x", count: 64_000) + "\n"
        let start = Date()
        _ = NativeCodeHighlighter.highlight(code: long, language: "swift")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "超长行应在线性时间内完成")
    }
}
