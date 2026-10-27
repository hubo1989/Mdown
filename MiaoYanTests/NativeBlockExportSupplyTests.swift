import XCTest

@testable import MiaoYan

/// T17:artifact → RenderedBlockSnapshot 的映射合同(纯函数部分);
/// 缓存供给路径不经 WebKit。
final class NativeBlockExportSupplyTests: XCTestCase {

    private func makeRequest(
        kind: MarkdownBlockRenderKind = .mermaid
    ) -> MarkdownBlockRenderRequest {
        MarkdownBlockRenderRequest(
            blockID: "b1", noteID: "note.md", revision: 3,
            themeGeneration: 2, kind: kind, source: "src")
    }

    @MainActor
    func testMermaidSVGMapsToSnapshot() {
        let request = makeRequest(kind: .mermaid)
        let artifact = MarkdownBlockArtifact(
            payload: .svg("<svg>g</svg>"),
            naturalSize: NSSize(width: 320, height: 180))
        let snapshot = NativeBlockExportSupply.snapshot(for: request, artifact: artifact)
        XCTAssertEqual(snapshot?.kind, .mermaid)
        XCTAssertEqual(snapshot?.svgContent, "<svg>g</svg>")
        XCTAssertEqual(snapshot?.naturalWidth, 320)
        XCTAssertEqual(snapshot?.naturalHeight, 180)
        XCTAssertEqual(snapshot?.identity.blockId, "b1")
        XCTAssertEqual(snapshot?.identity.noteId, "note.md")
        XCTAssertEqual(snapshot?.identity.renderRevision, 3)
        XCTAssertEqual(snapshot?.identity.previewGeneration, 2)
    }

    @MainActor
    func testMathHTMLMapsToKatexSnapshot() {
        let request = makeRequest(kind: .math)
        let artifact = MarkdownBlockArtifact(
            payload: .html("<span class=\"katex\">x</span>"),
            naturalSize: NSSize(width: 100, height: 40))
        let snapshot = NativeBlockExportSupply.snapshot(for: request, artifact: artifact)
        XCTAssertEqual(snapshot?.kind, .katex)
        XCTAssertNil(snapshot?.svgContent)
        XCTAssertEqual(snapshot?.htmlContent, "<span class=\"katex\">x</span>")
    }

    @MainActor
    func testPlantUMLMapsAndHTMLKindIsRefused() {
        let request = makeRequest(kind: .plantuml)
        let artifact = MarkdownBlockArtifact(payload: .svg("s"), naturalSize: .zero)
        XCTAssertEqual(
            NativeBlockExportSupply.snapshot(for: request, artifact: artifact)?.kind, .plantuml)

        let htmlRequest = makeRequest(kind: .html)
        XCTAssertNil(
            NativeBlockExportSupply.snapshot(for: htmlRequest, artifact: artifact),
            "导出器无 html kind,必须显式拒绝")
    }

    @MainActor
    func testSupplyReusesCachedArtifactWithoutRendering() async {
        let request = makeRequest()
        let artifact = MarkdownBlockArtifact(
            payload: .svg("<svg>cached</svg>"),
            naturalSize: NSSize(width: 10, height: 10))
        let cache = MarkdownBlockRenderCache(capacity: 4)
        cache.store(artifact, for: request)
        let host = MarkdownBlockRenderHost(cache: cache)

        // 缓存命中:不需要渲染(fingerprint 内容同源),快照正常
        let snapshot = await NativeBlockExportSupply.supply(request, host: host)
        XCTAssertEqual(snapshot?.svgContent, "<svg>cached</svg>")
    }
}
