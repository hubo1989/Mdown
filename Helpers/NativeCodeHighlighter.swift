import Foundation

// MARK: - T15 原生代码高亮（SPEC §8.1 / NE-26 / AC-12）
//
// 输出 source UTF-16 token ranges 与样式类别,不产出任何正规化正文——
// token 只是原文的不相交子区间,文字与编辑行为完全保留。
//
// 语言覆盖（SPEC §8.1 首批）:Swift、Objective-C/C/C++、JavaScript/
// TypeScript、Python、JSON、HTML/CSS、Shell、SQL、YAML;别名见
// `languageAliases`。未知语言/nil 返回 nil,调用方落到基础 code 样式
// (plain),不猜测语言。
//
// 边界约定:
// - 未闭合的 string/comment/模板串吞到输入末尾,不崩溃不越界;
// - token 边界不切代理对(string/comment 按语义整体吞并);
// - 未覆盖区间 = plain(调用方保留基础 code 字体/前景);
// - 线性扫描,超长行 O(n);同步调用(替代 Highlightr 的同步 HTML
//   round-trip,预算远低于原实现)。

/// token 样式类别(view 层映射到主题色)。
enum NativeCodeTokenKind: Equatable {
    case keyword
    case string
    case number
    case comment
    case type
    case property  // 对象键 / CSS 属性 / YAML 键
    case tag  // HTML 标签
    case attribute  // HTML 属性
    case literal  // true/false/null/None 等
}

struct NativeCodeToken: Equatable {
    let range: NSRange
    let kind: NativeCodeTokenKind
}

enum NativeCodeHighlighter {

    // MARK: - 语言与别名

    /// SPEC §8.1 首批语言集;别名对齐仓库 fence 常见写法。
    static let languageAliases: [String: String] = [
        "swift": "swift",
        "objc": "objc", "objective-c": "objc", "mm": "objc",
        "c": "c", "h": "c",
        "cpp": "cpp", "c++": "cpp", "cc": "cpp", "hpp": "cpp",
        "js": "js", "javascript": "js", "jsx": "js",
        "ts": "js", "typescript": "js", "tsx": "js",
        "python": "python", "py": "python",
        "json": "json",
        "html": "html", "xml": "html", "svg": "html",
        "css": "css", "scss": "css",
        "shell": "shell", "bash": "shell", "sh": "shell", "zsh": "shell",
        "sql": "sql",
        "yaml": "yaml", "yml": "yaml",
    ]

    /// 归一化语言族;不支持返回 nil(plain code)。
    static func languageFamily(_ language: String?) -> String? {
        guard let language, let family = languageAliases[language.lowercased()] else {
            return nil
        }
        return family
    }

    /// token 化入口。不支持的语言返回 nil(不是空数组——空数组表示
    /// "支持但无 token",nil 表示"plain code 样式")。
    static func highlight(code: String, language: String?) -> [NativeCodeToken]? {
        guard let family = languageFamily(language) else { return nil }
        var scanner = CodeScanner(units: Array(code.utf16))
        switch family {
        case "swift": return scanSwift(&scanner)
        case "objc": return scanCLike(&scanner, isObjC: true)
        case "c", "cpp": return scanCLike(&scanner, isObjC: false)
        case "js": return scanJavaScript(&scanner)
        case "python": return scanPython(&scanner)
        case "json": return scanJSON(&scanner)
        case "html": return scanHTML(&scanner)
        case "css": return scanCSS(&scanner)
        case "shell": return scanShell(&scanner)
        case "sql": return scanSQL(&scanner)
        case "yaml": return scanYAML(&scanner)
        default: return nil
        }
    }

    // MARK: - 扫描基础设施

    /// UTF-16 扫描器;所有 emit 以 [start, cursor) 区间记录。
    struct CodeScanner {
        let units: [unichar]
        private(set) var cursor = 0

        init(units: [unichar]) { self.units = units }

        var isAtEnd: Bool { cursor >= units.count }

        func peek(_ offset: Int = 0) -> unichar {
            let index = cursor + offset
            return index >= 0 && index < units.count ? units[index] : 0
        }

        func hasPrefix(_ string: String) -> Bool {
            let target = Array(string.utf16)
            guard cursor + target.count <= units.count else { return false }
            return Array(units[cursor..<cursor + target.count]) == target
        }

        mutating func advance(_ count: Int = 1) {
            cursor = min(cursor + count, units.count)
        }

        /// 直接定位(YAML 按行扫描后跳到行尾)。
        mutating func move(to position: Int) {
            cursor = min(max(position, 0), units.count)
        }

        /// 前进到行尾换行符之前(换行本身不吞)。
        mutating func advanceToLineEnd() {
            while !isAtEnd, units[cursor] != 0x0A, units[cursor] != 0x0D {
                cursor += 1
            }
        }

        mutating func skipLineBreak() {
            if !isAtEnd, units[cursor] == 0x0D {
                cursor += 1
                if !isAtEnd, units[cursor] == 0x0A { cursor += 1 }
            } else if !isAtEnd, units[cursor] == 0x0A {
                cursor += 1
            }
        }

        /// [a-zA-Z0-9_$] 连续 run;非 ASCII(CJK 等)一并视作标识符,
        /// 按 code unit 整体吞,不切代理对。
        mutating func advanceIdentifier() {
            while !isAtEnd {
                let u = units[cursor]
                let isASCIIWord =
                    (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A)
                    || (u >= 0x61 && u <= 0x7A) || u == 0x5F || u == 0x24
                guard isASCIIWord || u >= 0x80 else { break }
                cursor += 1
            }
        }

        /// 数字 token 扫描:`0x` 十六进制 | 整数[.小数][eE[±]指数];下划线
        /// 分组允许。`+`/`-` 只出现在指数符号位,`.` 只在数字后一次
        /// (不吞 `1+2` / `1...3` / SQL `1-- comment`)。CSS 十六色经
        /// `allowHexLetters` 放行 a-f(先吞可选 `#`)。
        mutating func advanceNumberUnits(allowHexLetters: Bool) {
            if peek() == 0x23 { advance() }  // CSS #fff
            if peek() == 0x30, peek(1) == 0x78 || peek(1) == 0x58 {
                advance(2)
                while !isAtEnd {
                    let u = units[cursor]
                    if (u >= 0x30 && u <= 0x39) || (u >= 0x61 && u <= 0x66)
                        || (u >= 0x41 && u <= 0x46) || u == 0x5F
                    {
                        cursor += 1
                    } else {
                        break
                    }
                }
                return
            }
            var seenDigit = false
            var seenDot = false
            while !isAtEnd {
                let u = units[cursor]
                if (u >= 0x30 && u <= 0x39) || u == 0x5F {
                    seenDigit = true
                    cursor += 1
                    continue
                }
                if allowHexLetters, (u >= 0x61 && u <= 0x66) || (u >= 0x41 && u <= 0x46) {
                    cursor += 1
                    continue
                }
                if u == 0x2E, !seenDot, seenDigit {
                    let n = peek(1)
                    if n >= 0x30, n <= 0x39 { seenDot = true; cursor += 1; continue }
                    break
                }
                if u == 0x65 || u == 0x45, seenDigit {
                    let n = peek(1)
                    if n >= 0x30, n <= 0x39 { cursor += 1; continue }
                    if n == 0x2B || n == 0x2D, peek(2) >= 0x30, peek(2) <= 0x39 {
                        cursor += 2
                        continue
                    }
                    break
                }
                break
            }
        }
    }

    private static func isIdentifierStart(_ u: unichar) -> Bool {
        (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F || u == 0x24 || u >= 0x80
    }

    private static func isDigit(_ u: unichar) -> Bool { u >= 0x30 && u <= 0x39 }

    private static func token(
        _ start: Int, _ end: Int, _ kind: NativeCodeTokenKind
    ) -> NativeCodeToken {
        NativeCodeToken(range: NSRange(location: start, length: end - start), kind: kind)
    }

    /// 行注释:从当前位置到行尾(不含换行)。
    private static func emitLineComment(
        _ scanner: inout CodeScanner, out: inout [NativeCodeToken]
    ) {
        let start = scanner.cursor
        scanner.advanceToLineEnd()
        out.append(token(start, scanner.cursor, .comment))
    }

    /// 块注释:`startLen` 为开标记长(如 `<!--` 是 4),到闭合符或末尾。
    private static func emitBlockComment(
        _ scanner: inout CodeScanner, ender: String, startLen: Int? = nil,
        out: inout [NativeCodeToken]
    ) {
        let start = scanner.cursor
        scanner.advance(startLen ?? ender.count)
        while !scanner.isAtEnd, !scanner.hasPrefix(ender) {
            scanner.advance()
        }
        if scanner.hasPrefix(ender) { scanner.advance(ender.count) }
        out.append(token(start, scanner.cursor, .comment))
    }

    /// 带转义的字符串;`prefixLen` 处理 @"…" / f"…" 等前缀;
    /// `includeStart` 让 token 从前缀起点起算。
    private static func emitQuoted(
        _ scanner: inout CodeScanner, quote: unichar, prefixLen: Int,
        out: inout [NativeCodeToken], includeStart: Int? = nil, multiline: Bool = false
    ) {
        let start = includeStart ?? scanner.cursor
        if includeStart == nil { scanner.advance(prefixLen) }
        scanner.advance()  // 开引号
        while !scanner.isAtEnd {
            let u = scanner.peek()
            if u == 0x5C {
                scanner.advance(2)  // 转义对(含 \" 与代理对)
                continue
            }
            if u == quote || (!multiline && (u == 0x0A || u == 0x0D)) {
                if u == quote { scanner.advance() }
                break
            }
            scanner.advance()
        }
        out.append(token(start, scanner.cursor, .string))
    }

    /// 宽松数字 token。
    private static func emitNumber(
        _ scanner: inout CodeScanner, out: inout [NativeCodeToken], allowHexLetters: Bool = false
    ) {
        let start = scanner.cursor
        scanner.advanceNumberUnits(allowHexLetters: allowHexLetters)
        out.append(token(start, scanner.cursor, .number))
    }

    /// 标识符判定:关键字/字面量/大写开头类型。
    /// 返回 true 表示已 emit(调用方 continue)。
    private static func emitClassifiedIdentifier(
        _ scanner: inout CodeScanner, out: inout [NativeCodeToken],
        keywords: Set<String>, literals: Set<String>, upperCaseIsType: Bool
    ) {
        let start = scanner.cursor
        scanner.advanceIdentifier()
        let text = String(decoding: scanner.units[start..<scanner.cursor], as: UTF16.self)
        let range = NSRange(location: start, length: scanner.cursor - start)
        if keywords.contains(text) {
            out.append(NativeCodeToken(range: range, kind: .keyword))
        } else if literals.contains(text) {
            out.append(NativeCodeToken(range: range, kind: .literal))
        } else if upperCaseIsType, let first = text.utf16.first, first >= 0x41 && first <= 0x5A {
            out.append(NativeCodeToken(range: range, kind: .type))
        }
    }

    // MARK: - Swift

    private static let swiftKeywords: Set<String> = [
        "import", "let", "var", "func", "struct", "class", "enum", "protocol", "extension",
        "if", "else", "guard", "switch", "case", "default", "for", "while", "repeat",
        "return", "break", "continue", "throw", "throws", "rethrows", "try", "catch",
        "defer", "in", "is", "as", "init", "deinit", "self", "super", "where", "inout",
        "static", "final", "override", "public", "private", "internal", "fileprivate",
        "open", "lazy", "weak", "unowned", "mutating", "indirect", "associatedtype",
        "typealias", "operator", "subscript", "get", "set", "willSet", "didSet", "some",
        "any", "async", "await", "actor",
    ]
    private static let swiftLiterals: Set<String> = ["true", "false", "nil"]

    private static func scanSwift(_ scanner: inout CodeScanner) -> [NativeCodeToken] {
        var out: [NativeCodeToken] = []
        while !scanner.isAtEnd {
            let u = scanner.peek()
            if u == 0x2F, scanner.peek(1) == 0x2F {  // //
                emitLineComment(&scanner, out: &out)
            } else if u == 0x2F, scanner.peek(1) == 0x2A {  // /*(Swift 可嵌套)
                let start = scanner.cursor
                scanner.advance(2)
                var depth = 1
                while !scanner.isAtEnd, depth > 0 {
                    if scanner.peek() == 0x2A, scanner.peek(1) == 0x2F {
                        scanner.advance(2)
                        depth -= 1
                    } else if scanner.peek() == 0x2F, scanner.peek(1) == 0x2A {
                        scanner.advance(2)
                        depth += 1
                    } else {
                        scanner.advance()
                    }
                }
                out.append(token(start, scanner.cursor, .comment))
            } else if u == 0x22 {
                emitQuoted(&scanner, quote: 0x22, prefixLen: 0, out: &out)
            } else if u == 0x40 {  // @propertyWrapper / @objc 等
                let start = scanner.cursor
                scanner.advance()
                scanner.advanceIdentifier()
                out.append(token(start, scanner.cursor, .keyword))
            } else if isIdentifierStart(u) {
                emitClassifiedIdentifier(
                    &scanner, out: &out,
                    keywords: swiftKeywords, literals: swiftLiterals, upperCaseIsType: true)
            } else if isDigit(u) {
                emitNumber(&scanner, out: &out)
            } else {
                scanner.advance()
            }
        }
        return out
    }

    // MARK: - C / Objective-C / C++

    private static let cKeywords: Set<String> = [
        "int", "char", "long", "short", "void", "float", "double", "unsigned", "signed",
        "struct", "union", "enum", "const", "static", "extern", "register", "volatile",
        "inline", "sizeof", "typedef", "auto", "if", "else", "switch", "case", "default",
        "for", "while", "do", "break", "continue", "return", "goto",
    ]
    private static let cPreprocessor: Set<String> = [
        "include", "define", "ifdef", "ifndef", "endif", "pragma", "import", "else",
        "elif", "undef", "error",
    ]
    private static let objcKeywords: Set<String> = [
        "@interface", "@implementation", "@property", "@end", "@class", "@protocol",
        "@selector", "@autoreleasepool", "@try", "@catch", "@finally", "@throw",
        "@synthesize", "@dynamic", "@optional", "@required", "@synchronized",
        "BOOL", "id", "self", "super",
    ]
    private static let cLiterals: Set<String> = ["YES", "NO", "true", "false", "nil", "Nil"]

    private static func scanCLike(_ scanner: inout CodeScanner, isObjC: Bool) -> [NativeCodeToken] {
        var out: [NativeCodeToken] = []
        var keywords = cKeywords
        if isObjC { keywords.formUnion(objcKeywords) }
        while !scanner.isAtEnd {
            let u = scanner.peek()
            if u == 0x2F, scanner.peek(1) == 0x2F {
                emitLineComment(&scanner, out: &out)
            } else if u == 0x2F, scanner.peek(1) == 0x2A {
                emitBlockComment(&scanner, ender: "*/", out: &out)
            } else if u == 0x22 || (isObjC && u == 0x40 && scanner.peek(1) == 0x22) {
                emitQuoted(
                    &scanner, quote: 0x22, prefixLen: (isObjC && u == 0x40) ? 1 : 0, out: &out)
            } else if u == 0x23, isIdentifierStart(scanner.peek(1)) {  // 预处理指令
                let start = scanner.cursor
                scanner.advance()
                scanner.advanceIdentifier()
                let text = String(decoding: scanner.units[start + 1..<scanner.cursor], as: UTF16.self)
                if cPreprocessor.contains(text) {
                    out.append(token(start, scanner.cursor, .keyword))
                }
            } else if u == 0x27 {  // 'x' / '\n' 字符字面量(含 '"' 不误开串)
                let start = scanner.cursor
                scanner.advance()
                if scanner.peek() == 0x5C { scanner.advance(2) } else { scanner.advance() }
                if scanner.peek() == 0x27 { scanner.advance() }
                out.append(token(start, scanner.cursor, .string))
            } else if isIdentifierStart(u) {
                emitClassifiedIdentifier(
                    &scanner, out: &out,
                    keywords: keywords, literals: cLiterals, upperCaseIsType: true)
            } else if isDigit(u) {
                emitNumber(&scanner, out: &out)
            } else {
                scanner.advance()
            }
        }
        return out
    }

    // MARK: - JavaScript / TypeScript

    private static let jsKeywords: Set<String> = [
        "const", "let", "var", "function", "class", "extends", "implements", "interface",
        "type", "enum", "if", "else", "switch", "case", "default", "for", "while", "do",
        "return", "break", "continue", "throw", "try", "catch", "finally", "new", "delete",
        "typeof", "instanceof", "in", "of", "this", "super", "import", "export", "from",
        "async", "await", "yield", "static", "get", "set", "void", "public", "private",
        "protected", "readonly", "declare", "namespace", "as", "is", "keyof", "infer",
    ]
    private static let jsLiterals: Set<String> = ["true", "false", "null", "undefined"]

    private static func scanJavaScript(_ scanner: inout CodeScanner) -> [NativeCodeToken] {
        var out: [NativeCodeToken] = []
        while !scanner.isAtEnd {
            let u = scanner.peek()
            if u == 0x2F, scanner.peek(1) == 0x2F {
                emitLineComment(&scanner, out: &out)
            } else if u == 0x2F, scanner.peek(1) == 0x2A {
                emitBlockComment(&scanner, ender: "*/", out: &out)
            } else if u == 0x22 || u == 0x27 {
                emitQuoted(&scanner, quote: u, prefixLen: 0, out: &out)
            } else if u == 0x60 {  // 模板串(${} 原样吞并,可跨行)
                emitQuoted(&scanner, quote: 0x60, prefixLen: 0, out: &out, multiline: true)
            } else if isIdentifierStart(u) {
                emitClassifiedIdentifier(
                    &scanner, out: &out,
                    keywords: jsKeywords, literals: jsLiterals, upperCaseIsType: true)
            } else if isDigit(u) {
                emitNumber(&scanner, out: &out)
            } else {
                scanner.advance()
            }
        }
        return out
    }

    // MARK: - Python

    private static let pythonKeywords: Set<String> = [
        "def", "class", "lambda", "if", "elif", "else", "for", "while", "break",
        "continue", "return", "yield", "import", "from", "as", "with", "try", "except",
        "finally", "raise", "pass", "global", "nonlocal", "assert", "del", "in", "is",
        "not", "and", "or", "async", "await", "match", "case", "int", "str", "float",
        "bool", "bytes", "list", "dict", "set", "tuple", "print",
    ]
    private static let pythonLiterals: Set<String> = ["True", "False", "None"]
    private static let pythonStringPrefixes: Set<unichar> = [
        0x66, 0x72, 0x62, 0x46, 0x52, 0x42,  // f r b F R B
    ]

    private static func scanPython(_ scanner: inout CodeScanner) -> [NativeCodeToken] {
        var out: [NativeCodeToken] = []
        while !scanner.isAtEnd {
            let u = scanner.peek()
            if u == 0x23 {
                emitLineComment(&scanner, out: &out)
            } else if u == 0x22 || u == 0x27 {
                emitPythonQuoted(&scanner, quote: u, prefixStart: nil, out: &out)
            } else if isIdentifierStart(u) {
                let start = scanner.cursor
                scanner.advanceIdentifier()
                let next = scanner.peek()
                if next == 0x22 || next == 0x27,
                    pythonStringPrefixes.contains(scanner.units[scanner.cursor - 1])
                {
                    // f/r/b 前缀串:前缀 + 引号体合并为一个 string token
                    emitPythonQuoted(&scanner, quote: next, prefixStart: start, out: &out)
                    continue
                }
                let text = String(decoding: scanner.units[start..<scanner.cursor], as: UTF16.self)
                let range = NSRange(location: start, length: scanner.cursor - start)
                if pythonKeywords.contains(text) {
                    out.append(NativeCodeToken(range: range, kind: .keyword))
                } else if pythonLiterals.contains(text) {
                    out.append(NativeCodeToken(range: range, kind: .literal))
                } else if let first = text.utf16.first, first >= 0x41 && first <= 0x5A {
                    out.append(NativeCodeToken(range: range, kind: .type))
                }
            } else if isDigit(u) {
                emitNumber(&scanner, out: &out)
            } else {
                scanner.advance()
            }
        }
        return out
    }

    /// Python 字符串(含三引号与前缀):prefixStart 非 nil 时 token 从前缀起。
    private static func emitPythonQuoted(
        _ scanner: inout CodeScanner, quote: unichar, prefixStart: Int?,
        out: inout [NativeCodeToken]
    ) {
        // 入口约定:cursor 恰在开引号上(前缀已被调用方作为标识符消费)。
        let start = prefixStart ?? scanner.cursor
        let quoteChar = String(UnicodeScalar(quote) ?? " ")
        let isTriple = scanner.hasPrefix(String(repeating: quoteChar, count: 3))
        scanner.advance(isTriple ? 3 : 1)
        if isTriple {
            let closer = String(repeating: quoteChar, count: 3)
            while !scanner.isAtEnd {
                if scanner.peek() == 0x5C { scanner.advance(2); continue }
                if scanner.hasPrefix(closer) { scanner.advance(3); break }
                scanner.advance()
            }
        } else {
            while !scanner.isAtEnd {
                let u = scanner.peek()
                if u == 0x5C { scanner.advance(2); continue }
                if u == quote { scanner.advance(); break }
                if u == 0x0A || u == 0x0D { break }  // 单引号串不跨行
                scanner.advance()
            }
        }
        out.append(token(start, scanner.cursor, .string))
    }

    // MARK: - JSON

    private static func scanJSON(_ scanner: inout CodeScanner) -> [NativeCodeToken] {
        var out: [NativeCodeToken] = []
        while !scanner.isAtEnd {
            let u = scanner.peek()
            if u == 0x22 {
                let start = scanner.cursor
                emitQuoted(&scanner, quote: 0x22, prefixLen: 0, out: &out)
                let range = NSRange(location: start, length: scanner.cursor - start)
                // 冒号前 = 键
                var probe = scanner.cursor
                while probe < scanner.units.count,
                    scanner.units[probe] == 0x20 || scanner.units[probe] == 0x09
                { probe += 1 }
                let isKey = probe < scanner.units.count && scanner.units[probe] == 0x3A
                out[out.count - 1] = NativeCodeToken(
                    range: range, kind: isKey ? .property : .string)
            } else if isDigit(u) || u == 0x2D {
                emitNumber(&scanner, out: &out)
            } else if isIdentifierStart(u) {
                let start = scanner.cursor
                scanner.advanceIdentifier()
                let text = String(decoding: scanner.units[start..<scanner.cursor], as: UTF16.self)
                if text == "true" || text == "false" || text == "null" {
                    out.append(token(start, scanner.cursor, .literal))
                }
            } else {
                scanner.advance()
            }
        }
        return out
    }

    // MARK: - HTML

    private static func scanHTML(_ scanner: inout CodeScanner) -> [NativeCodeToken] {
        var out: [NativeCodeToken] = []
        while !scanner.isAtEnd {
            let u = scanner.peek()
            if u == 0x3C, scanner.hasPrefix("<!--") {
                emitBlockComment(&scanner, ender: "-->", startLen: 4, out: &out)
            } else if u == 0x3C, isIdentifierStart(scanner.peek(1)) || scanner.peek(1) == 0x2F {
                // 标签整体范围:<name attr="v" … > / </name>
                let tagStart = scanner.cursor
                scanner.advance()  // <
                if scanner.peek() == 0x2F { scanner.advance() }
                scanner.advanceIdentifier()
                var quote: unichar = 0
                while !scanner.isAtEnd {
                    let c = scanner.peek()
                    if quote != 0 {
                        if c == quote { quote = 0 }
                    } else if c == 0x22 || c == 0x27 {
                        quote = c
                    } else if c == 0x3E {
                        scanner.advance()
                        break
                    }
                    scanner.advance()
                }
                emitHTMLTag(
                    scanner.units,
                    range: NSRange(location: tagStart, length: scanner.cursor - tagStart),
                    out: &out)
            } else {
                scanner.advance()
            }
        }
        return out
    }

    /// 标签内部拆分:<tag attr="v">——tag/attribute/string 互不重叠。
    private static func emitHTMLTag(
        _ units: [unichar], range: NSRange, out: inout [NativeCodeToken]
    ) {
        var i = range.location
        let end = NSMaxRange(range)
        // 闭标签(</p>)无属性,整体一个 tag token。
        if i + 1 < end, units[i + 1] == 0x2F {
            out.append(token(i, end, .tag))
            return
        }
        out.append(token(i, i + 1, .tag))  // '<'
        i += 1
        let nameStart = i
        while i < end, units[i] != 0x20, units[i] != 0x3E, units[i] != 0x2F, units[i] != 0x09,
            units[i] != 0x0A
        { i += 1 }
        if i > nameStart {  // 名字并入 '<' 前缀 token → '<p'
            out[out.count - 1] = token(range.location, i, .tag)
        }
        // 属性区:'=' 保持 plain(属性名与值的分隔符)
        while i < end {
            let u = units[i]
            if u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D || u == 0x2F || u == 0x3D {
                i += 1
            } else if u == 0x22 || u == 0x27 {
                let quote = u
                let start = i
                i += 1
                while i < end, units[i] != quote { i += 1 }
                if i < end { i += 1 }
                out.append(token(start, i, .string))
            } else if u == 0x3E {
                out.append(token(i, i + 1, .tag))
                i += 1
            } else {
                let start = i
                while i < end, units[i] != 0x20, units[i] != 0x3E, units[i] != 0x22,
                    units[i] != 0x27, units[i] != 0x2F, units[i] != 0x3D
                { i += 1 }
                out.append(token(start, i, .attribute))
            }
        }
    }

    // MARK: - CSS

    private static func scanCSS(_ scanner: inout CodeScanner) -> [NativeCodeToken] {
        var out: [NativeCodeToken] = []
        var inBlock = false
        var expectValue = false
        while !scanner.isAtEnd {
            let u = scanner.peek()
            if u == 0x2F, scanner.peek(1) == 0x2A {
                emitBlockComment(&scanner, ender: "*/", out: &out)
            } else if u == 0x22 || u == 0x27 {
                emitQuoted(&scanner, quote: u, prefixLen: 0, out: &out)
            } else if u == 0x7B {  // {
                inBlock = true
                expectValue = false
                scanner.advance()
            } else if u == 0x7D {  // }
                inBlock = false
                expectValue = false
                scanner.advance()
            } else if u == 0x3A {  // :
                expectValue = inBlock
                scanner.advance()
            } else if u == 0x3B {  // ;
                expectValue = false
                scanner.advance()
            } else if expectValue, u == 0x23 || isDigit(u) || (u == 0x2D && isDigit(scanner.peek(1))) {
                // 值:#hex / 数字(负号保持 plain)
                let start = scanner.cursor
                scanner.advanceNumberUnits(allowHexLetters: u == 0x23)
                if scanner.cursor == start { scanner.advance() }  // 防空 token
                out.append(token(start, scanner.cursor, .number))
            } else if isIdentifierStart(u) {
                let start = scanner.cursor
                scanner.advanceIdentifier()
                let range = NSRange(location: start, length: scanner.cursor - start)
                if inBlock, !expectValue {
                    out.append(NativeCodeToken(range: range, kind: .property))
                }
            } else {
                scanner.advance()
            }
        }
        return out
    }

    // MARK: - Shell

    private static let shellKeywords: Set<String> = [
        "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case",
        "esac", "in", "function", "return", "exit", "echo", "export", "local", "source",
        "cd", "set", "unset", "shift", "read", "printf", "test", "exec", "trap", "eval",
    ]

    private static func scanShell(_ scanner: inout CodeScanner) -> [NativeCodeToken] {
        var out: [NativeCodeToken] = []
        while !scanner.isAtEnd {
            let u = scanner.peek()
            if u == 0x23 {  // shebang 同样按注释
                emitLineComment(&scanner, out: &out)
            } else if u == 0x22 || u == 0x27 {  // POSIX 引号串可跨行
                emitQuoted(&scanner, quote: u, prefixLen: 0, out: &out, multiline: true)
            } else if isIdentifierStart(u) {
                emitClassifiedIdentifier(
                    &scanner, out: &out,
                    keywords: shellKeywords, literals: [], upperCaseIsType: false)
            } else if isDigit(u) {
                emitNumber(&scanner, out: &out)
            } else {
                scanner.advance()
            }
        }
        return out
    }

    // MARK: - SQL

    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
        "create", "table", "index", "view", "drop", "alter", "add", "and", "or", "not",
        "null", "is", "in", "as", "on", "join", "left", "right", "inner", "outer", "full",
        "group", "by", "order", "having", "limit", "offset", "distinct", "union", "all",
        "primary", "key", "foreign", "references", "default", "unique", "begin",
        "commit", "rollback", "transaction", "case", "when", "then", "else", "end",
        "like", "between", "exists", "asc", "desc",
    ]

    private static func scanSQL(_ scanner: inout CodeScanner) -> [NativeCodeToken] {
        var out: [NativeCodeToken] = []
        while !scanner.isAtEnd {
            let u = scanner.peek()
            if u == 0x2D, scanner.peek(1) == 0x2D {
                emitLineComment(&scanner, out: &out)
            } else if u == 0x2F, scanner.peek(1) == 0x2A {
                emitBlockComment(&scanner, ender: "*/", out: &out)
            } else if u == 0x27 {  // SQL 字符串可跨行
                emitQuoted(&scanner, quote: 0x27, prefixLen: 0, out: &out, multiline: true)
            } else if isIdentifierStart(u) {
                let start = scanner.cursor
                scanner.advanceIdentifier()
                let text = String(decoding: scanner.units[start..<scanner.cursor], as: UTF16.self)
                    .lowercased()
                if sqlKeywords.contains(text) {
                    out.append(token(start, scanner.cursor, .keyword))
                }
            } else if isDigit(u) {
                emitNumber(&scanner, out: &out)
            } else {
                scanner.advance()
            }
        }
        return out
    }

    // MARK: - YAML

    private static func scanYAML(_ scanner: inout CodeScanner) -> [NativeCodeToken] {
        var out: [NativeCodeToken] = []
        while !scanner.isAtEnd {
            // 行首缩进
            while !scanner.isAtEnd, scanner.peek() == 0x20 || scanner.peek() == 0x09 {
                scanner.advance()
            }
            if scanner.isAtEnd { break }
            if scanner.peek() == 0x23 {
                emitLineComment(&scanner, out: &out)
                scanner.skipLineBreak()
                continue
            }
            // 逐行:首个 `key:` 模式 → property;值区数字/literal/尾注释
            let lineStart = scanner.cursor
            scanner.advanceToLineEnd()
            let lineEnd = scanner.cursor
            var i = lineStart
            var keyEnd = -1
            while i < lineEnd {
                let u = scanner.units[i]
                if u == 0x3A { keyEnd = i; break }
                if u == 0x22 || u == 0x27 || u == 0x23 { break }
                i += 1
            }
            if keyEnd > lineStart {
                out.append(token(lineStart, keyEnd, .property))
                var j = keyEnd + 1
                while j < lineEnd, scanner.units[j] == 0x20 || scanner.units[j] == 0x09 {
                    j += 1
                }
                if j < lineEnd {
                    if scanner.units[j] == 0x23 {
                        out.append(token(j, lineEnd, .comment))
                    } else {
                        let valueStart = j
                        while j < lineEnd, scanner.units[j] != 0x20, scanner.units[j] != 0x09 {
                            j += 1
                        }
                        let text = String(
                            decoding: scanner.units[valueStart..<j], as: UTF16.self)
                        if Int(text) != nil || Double(text) != nil {
                            out.append(token(valueStart, j, .number))
                        } else if text == "true" || text == "false" || text == "null" {
                            out.append(token(valueStart, j, .literal))
                        }
                    }
                }
            }
            scanner.move(to: lineEnd)
            scanner.skipLineBreak()
        }
        return out
    }
}
