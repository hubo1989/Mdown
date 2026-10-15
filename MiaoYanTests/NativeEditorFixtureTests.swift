import CryptoKit
import XCTest

/// T00 基线：NativeEditor fixtures 已注册进 test bundle Resources，
/// Bundle 查找与字节特征在此固定；hash 期望值来自 manifest.json 生成时记录。
final class NativeEditorFixtureTests: XCTestCase {
    private struct FixtureSpec: Decodable {
        let path: String
        let sha256: String
        let bytes: Int
    }

    private struct Manifest: Decodable {
        let files: [FixtureSpec]
    }

    private func loadFixture(_ name: String) throws -> Data {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = Bundle(for: Self.self).url(forResource: base, withExtension: ext, subdirectory: nil) else {
            throw XCTSkip("fixture \(name) 未注册进 MiaoYanTests Resources（Bundle 查找失败）")
        }
        return try Data(contentsOf: url)
    }

    func testManifestFilesResolvableWithExpectedHash() throws {
        let manifestURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "manifest", withExtension: "json"),
            "manifest.json 未注册进 Resources"
        )
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.files.count, 8, "manifest 记录的文件数变化需同步更新本测试与 specs/typora-research/fixtures")

        for spec in manifest.files {
            let data = try loadFixture(spec.path)
            XCTAssertEqual(data.count, spec.bytes, "\(spec.path) 字节数与研究记录不一致")
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, spec.sha256, "\(spec.path) 内容 hash 不一致")
        }
    }

    func testBomSampleStartsWithUTF8BOM() throws {
        let data = try loadFixture("bom-utf8.md")
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "BOM 样例必须保留 UTF8 BOM 字节")
    }

    func testMixedEOLSampleHasBothLineEndings() throws {
        let text = try XCTUnwrap(String(data: try loadFixture("mixed-eol.md"), encoding: .utf8))
        XCTAssertTrue(text.contains("\r\n"), "必须包含 CRLF")
        XCTAssertTrue(
            text.contains("\n") && !text.replacingOccurrences(of: "\r\n", with: "").isEmpty,
            "必须包含非 CRLF 的 LF 内容")
        XCTAssertFalse(text.contains("\r\n\r\n"), "样例刻意不含空行 CRLF，特征漂移需更新 manifest")
    }

    func testNoFinalNewlineSampleEndsWithoutNewline() throws {
        let data = try loadFixture("roundtrip-no-final-newline.md")
        XCTAssertNotEqual(data.last, UInt8(ascii: "\n"), "无末尾换行样例必须保持该特征")
    }

    func testTabsSampleContainsTabCharacters() throws {
        let text = try XCTUnwrap(String(data: try loadFixture("tabs.md"), encoding: .utf8))
        XCTAssertTrue(text.contains("\t"), "tab 样例必须包含制表符")
        XCTAssertTrue(text.contains("\t\t"), "code block 内必须包含双 tab 缩进")
    }
}
