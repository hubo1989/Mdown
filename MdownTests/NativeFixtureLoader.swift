import CryptoKit
import Foundation
import XCTest

/// MdownTests 内共享的 NativeEditor fixture 加载器（bundle Resources）。
enum NativeFixtureLoader {
    static func load(_ name: String) throws -> Data {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard
            let url = Bundle(for: NativeEditorFixtureTests.self)
                .url(forResource: base, withExtension: ext)
        else {
            throw NSError(
                domain: "NativeFixtureLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "fixture \(name) 不在 test bundle Resources"])
        }
        return try Data(contentsOf: url)
    }

    /// 注意：String(data:encoding:.utf8) 会剥离 UTF-8 BOM。roundtrip 语义
    /// 要求保留 BOM，故检测前缀字节后显式回补（T03 实测行为，T07 的
    /// 文件读取路径同样必须防 BOM 丢失）。
    static func loadString(_ name: String) throws -> String {
        let data = try load(name)
        let text = String(data: data, encoding: .utf8) ?? ""
        if data.count >= 3, Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF] {
            return "\u{FEFF}" + text
        }
        return text
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
