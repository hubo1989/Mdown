import XCTest
@testable import MiaoYan

/// T02: UTF-16/UTF-8/grapheme 坐标转换。期望值由 NSString（UTF16 切分）
/// 与 String.utf8 字节独立推导，不与被测函数互相断言。
final class MarkdownSourceMapTests: XCTestCase {

    private let mixed = "aé中🙂\r\n👨‍👩‍👧‍👦\u{FEFF}tail"
    // UTF-16 布局（手工推导）：
    // a=0, é=1, 中=2, 🙂=3..<5, \r=5, \n=6, 👨=7..<9, ZWJ=9, 👩=10..<12,
    // ZWJ=12, 👧=13..<15, ZWJ=15, 👦=16..<18, BOM=18, t=19, a=20, i=21, l=22

    func testUTF16LayoutAssumption() {
        // 用 NSString oracle 固定 UTF-16 布局假设本身
        let ns = mixed as NSString
        XCTAssertEqual(ns.length, 23)
        XCTAssertEqual(ns.substring(with: NSRange(location: 0, length: 1)), "a")
        XCTAssertEqual(ns.substring(with: NSRange(location: 1, length: 1)), "é")
        XCTAssertEqual(ns.substring(with: NSRange(location: 3, length: 2)), "🙂")
        XCTAssertEqual(ns.substring(with: NSRange(location: 5, length: 2)), "\r\n")
    }

    func testGraphemeBoundaries() {
        let map = MarkdownSourceMap(source: mixed)
        // 边界点
        for boundary in [0, 1, 2, 3, 5, 7, 18, 19, 23] {
            XCTAssertTrue(map.isGraphemeBoundary(boundary), "\(boundary) 应为 grapheme 边界")
        }
        // 非边界：代理对中间（4、8、11、14、17）、CRLF 中间（6）、ZWJ 序列中间（9、12、15）
        for nonBoundary in [4, 6, 8, 9, 11, 12, 14, 15, 17] {
            XCTAssertFalse(map.isGraphemeBoundary(nonBoundary), "\(nonBoundary) 不得是 grapheme 边界")
        }
        // 越界
        XCTAssertFalse(map.isGraphemeBoundary(-1))
        XCTAssertFalse(map.isGraphemeBoundary(24))
    }

    func testUTF8OffsetsAgainstByteOracle() {
        let map = MarkdownSourceMap(source: mixed)
        // oracle：NSString 取前 x 个 UTF-16 单元（仅边界点），其 UTF-8 字节数
        let ns = mixed as NSString
        for boundary in [0, 1, 2, 3, 5, 7, 18, 19, 23] {
            let prefix = ns.substring(to: boundary)
            let expectedBytes = prefix.utf8.count
            XCTAssertEqual(
                map.utf8Offset(forUTF16: boundary), expectedBytes,
                "UTF16 \(boundary) 的字节偏移与 NSString oracle 不符")
        }
        // 手工锚点：a=1, aé=3, aé中=6（é 组合重音 2 字节 / 中文 3 字节）
        XCTAssertEqual(map.utf8Offset(forUTF16: 1), 1)
        XCTAssertEqual(map.utf8Offset(forUTF16: 2), 3)
        XCTAssertEqual(map.utf8Offset(forUTF16: 3), 6)
    }

    func testUTF16OffsetsRoundTrip() {
        let map = MarkdownSourceMap(source: mixed)
        for utf16Boundary in [0, 1, 2, 3, 5, 7, 18, 23] {
            guard let byte = map.utf8Offset(forUTF16: utf16Boundary),
                let back = map.utf16Offset(forUTF8: byte)
            else {
                return XCTFail("边界 \(utf16Boundary) 转换不应失败")
            }
            XCTAssertEqual(back, utf16Boundary, "UTF16→UTF8→UTF16 必须还原")
        }
    }

    func testByteRangeForUTF16Range() {
        let map = MarkdownSourceMap(source: mixed)
        // "🙂"（UTF16 3..<5）在 UTF-8 是 4 字节：字节 6..<10
        XCTAssertEqual(map.byteRange(forUTF16Range: NSRange(location: 3, length: 2)), 6..<10)
        // "\r\n"（UTF16 5..<7）是字节 10..<12
        XCTAssertEqual(map.byteRange(forUTF16Range: NSRange(location: 5, length: 2)), 10..<12)
        // 半代理 range 必须 nil
        XCTAssertNil(map.byteRange(forUTF16Range: NSRange(location: 3, length: 1)))
    }

    func testNonBoundaryConversionReturnsNil() {
        let map = MarkdownSourceMap(source: mixed)
        XCTAssertNil(map.utf8Offset(forUTF16: 6), "CRLF 中间无字节偏移")
        XCTAssertNil(map.utf8Offset(forUTF16: 4), "代理对中间无字节偏移")
        XCTAssertNil(map.utf8Offset(forUTF16: 99), "越界无偏移")
    }

    func testComposedAccentIsOneGrapheme() {
        // e + U+0301 组合成一个 é：中间不是删除边界
        let decomposed = "e\u{0301}x"
        let map = MarkdownSourceMap(source: decomposed)
        XCTAssertEqual((decomposed as NSString).length, 3)
        XCTAssertTrue(map.isGraphemeBoundary(0))
        XCTAssertFalse(map.isGraphemeBoundary(1), "组合附标前不得是边界")
        XCTAssertTrue(map.isGraphemeBoundary(2))
    }

    /// UTF-8 偏移落在 scalar 边界但切开组合 grapheme（e 与 U+0301 之间）
    /// 时必须拒绝，与正向转换（该处非 grapheme 边界 → nil）语义一致。
    func testUTF8OffsetInsideComposedGraphemeRejected() {
        let decomposed = "e\u{0301}x"
        let map = MarkdownSourceMap(source: decomposed)
        // UTF-8 布局：e=0..<1，U+0301=1..<3（2 字节），x=3..<4
        XCTAssertEqual(map.utf16Offset(forUTF8: 0), 0)
        XCTAssertNil(map.utf16Offset(forUTF8: 1), "e 与 U+0301 之间的字节偏移切开 grapheme，必须拒绝")
        XCTAssertEqual(map.utf16Offset(forUTF8: 3), 2)
        XCTAssertEqual(map.utf16Offset(forUTF8: 4), 3, "末尾 endIndex 是合法边界")
    }
}
