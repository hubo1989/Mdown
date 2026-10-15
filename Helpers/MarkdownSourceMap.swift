import Foundation

/// source 坐标系辅助：UTF-16（编辑坐标）↔ UTF-8 字节（磁盘/parser 坐标）
/// ↔ grapheme 边界查询。T02 原型：纯函数，不读用户库/renderer；
/// T03 的 projection/segment 映射在此基础上扩展。
struct MarkdownSourceMap {
    let source: String

    init(source: String) {
        self.source = source
    }

    var utf16Count: Int { source.utf16.count }
    var utf8Count: Int { source.utf8.count }

    /// UTF16 偏移 → UTF8 字节偏移。非 grapheme 边界返回 nil。
    func utf8Offset(forUTF16 utf16Offset: Int) -> Int? {
        guard isGraphemeBoundary(utf16Offset) else { return nil }
        let utf16View = source.utf16
        guard let index16 = utf16View.index(
            utf16View.startIndex, offsetBy: utf16Offset, limitedBy: utf16View.endIndex
        ) else { return nil }
        return source.utf8.distance(from: source.utf8.startIndex, to: index16.samePosition(in: source.utf8)!)
    }

    /// UTF8 字节偏移 → UTF16 偏移。非 grapheme 边界返回 nil。
    func utf16Offset(forUTF8 utf8Offset: Int) -> Int? {
        let utf8View = source.utf8
        guard let index8 = utf8View.index(
            utf8View.startIndex, offsetBy: utf8Offset, limitedBy: utf8View.endIndex
        ) else { return nil }
        guard let index16 = index8.samePosition(in: source.utf16) else { return nil }
        return source.utf16.distance(from: source.utf16.startIndex, to: index16)
    }

    /// NSRange(UTF16) → UTF8 字节区间。
    func byteRange(forUTF16Range range: NSRange) -> Range<Int>? {
        guard let lower = utf8Offset(forUTF16: range.location),
              let upper = utf8Offset(forUTF16: range.location + range.length) else { return nil }
        return lower..<upper
    }

    /// 该 UTF16 偏移是否为 grapheme cluster 边界（组合序列边界）。
    /// 0 与 utf16Count 恒为边界；代理对中间、CRLF 中间、组合附标中间均非边界。
    func isGraphemeBoundary(_ utf16Offset: Int) -> Bool {
        Self.isGraphemeBoundary(utf16Offset, utf16: Array(source.utf16), source: source)
    }

    /// 预取 utf16 数组版本的边界查询（applier 热路径复用同一数组）。
    static func isGraphemeBoundary(_ utf16Offset: Int, utf16: [UInt16], source: String) -> Bool {
        guard utf16Offset >= 0, utf16Offset <= utf16.count else { return false }
        guard utf16Offset > 0, utf16Offset < utf16.count else { return true }

        // 代理对中间：前一个 code unit 是 high surrogate 且当前是 low surrogate
        let prev = utf16[utf16Offset - 1]
        let current = utf16[utf16Offset]
        if prev >= 0xD800 && prev <= 0xDBFF && current >= 0xDC00 && current <= 0xDFFF {
            return false
        }
        // CRLF 中间：CR 后紧跟 LF
        if prev == 0x0D && current == 0x0A { return false }
        // 其余（组合附标/ZWJ/emoji 序列）交给 String(grapheme) 判定：
        // 偏移可对应一个 Character 切分位置 ⇔ 是 cluster 边界。
        let view = source.utf16
        guard let index = view.index(
            view.startIndex, offsetBy: utf16Offset, limitedBy: view.endIndex
        ) else { return false }
        return index.samePosition(in: source) != nil
    }
}
