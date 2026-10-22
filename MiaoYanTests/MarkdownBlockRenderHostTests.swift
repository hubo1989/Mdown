import XCTest

@testable import MiaoYan

/// T17 (PLAN T17 / SPEC §9 / NE-28 / AC-13 / AC-18):隔离渲染宿主合同。
///
/// 离屏 WKWebView 对单个不可变请求产出静态产物;latest-wins 拒 stale;
/// 错误/超时不毒化缓存。页面与资源走本地临时目录(WebContent 不为
/// 外置构建卷签发 file-url 沙箱扩展)。
@MainActor
final class MarkdownBlockRenderHostTests: XCTestCase {

    private func makeRequest(
        source: String,
        kind: MarkdownBlockRenderKind = .mermaid,
        revision: UInt64 = 1
    ) -> MarkdownBlockRenderRequest {
        MarkdownBlockRenderRequest(
            blockID: "b-\(UUID().uuidString)", noteID: "note.md", revision: revision,
            themeGeneration: 1, kind: kind, source: source)
    }

    /// 测试可挂起的门:先 wait,后 open。
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    func testValidMermaidProducesSVGArtifact() async throws {
        let host = MarkdownBlockRenderHost()
        let request = makeRequest(source: "flowchart LR\nA[\"Start\"] --> B[\"End\"]")

        let rendered = await host.render(request, timeout: 20)
        let artifact = try XCTUnwrap(rendered, "有效 mermaid 必须产出 artifact")

        guard case .svg(let svg) = artifact.payload else {
            return XCTFail("mermaid 产物应为 svg,实际 \(artifact.payload)")
        }
        XCTAssertTrue(svg.contains("<svg"), "产物应为 SVG 标记: \(svg.prefix(80))")
        XCTAssertGreaterThan(artifact.naturalSize.width, 0, "宽度应为正")
        XCTAssertGreaterThan(artifact.naturalSize.height, 0, "高度应为正")
        XCTAssertNotNil(host.cachedArtifact(for: request), "ready 产物必须落缓存")
    }

    func testInvalidMermaidReturnsNilAndDoesNotPoisonCache() async throws {
        let host = MarkdownBlockRenderHost()
        let request = makeRequest(source: "flowchart ??? definitely invalid")

        let artifact = await host.render(request, timeout: 20)

        XCTAssertNil(artifact, "invalid mermaid 不得产出 artifact")
        XCTAssertNil(host.cachedArtifact(for: request), "失败结果不得进缓存")
    }

    func testStaleRequestResultIsRejected() async throws {
        let host = MarkdownBlockRenderHost()
        let gate = Gate()
        // A:慢(渲染前挂起制造过期窗口);B:快(html 静态)。
        let staleRequest = makeRequest(
            source: "flowchart LR\nA --> B", kind: .mermaid, revision: 1)
        let freshRequest = makeRequest(
            source: "<p>fresh</p>", kind: .html, revision: 2)

        let staleTask = Task { @MainActor in
            await host.render(staleRequest, timeout: 20, beforeRender: { await gate.wait() })
        }
        // 等 A 完成 capture 并停在 beforeRender
        for _ in 0..<500 {
            if host.lastCapturedRequestForTesting == staleRequest { break }
            await Task.yield()
        }
        XCTAssertEqual(
            host.lastCapturedRequestForTesting, staleRequest, "A 应已 capture")

        // B 覆盖 coordinator 的权威请求
        let fresh = await host.render(freshRequest, timeout: 20)
        XCTAssertNotNil(fresh, "新请求必须成功")
        await gate.open()
        let stale = await staleTask.value

        XCTAssertNil(stale, "过期请求(渲染期间被新请求覆盖)的结果必须被拒")
        XCTAssertNil(host.cachedArtifact(for: staleRequest), "被拒结果不得落缓存")
        XCTAssertNotNil(host.cachedArtifact(for: freshRequest), "新结果正常落缓存")
    }

    func testHTMLArtifactStripsScripts() async throws {
        let host = MarkdownBlockRenderHost()
        let request = makeRequest(
            source: "<p>hello</p><script>alert(1)</script>", kind: .html)

        let rendered = await host.render(request, timeout: 5)
        let artifact = try XCTUnwrap(rendered, "html 块应产出静态 artifact")

        guard case .html(let html) = artifact.payload else {
            return XCTFail("html 块产物应为 html")
        }
        XCTAssertTrue(html.contains("<p>hello</p>"), "正文保留")
        XCTAssertFalse(html.contains("<script"), "编辑侧脚本必须剥除: \(html)")
    }

    func testMathProducesKATeXHTMLArtifact() async throws {
        let host = MarkdownBlockRenderHost()
        let request = makeRequest(source: "a = b", kind: .math)

        let rendered = await host.render(request, timeout: 20)
        let artifact = try XCTUnwrap(rendered, "有效 math 必须产出 artifact")

        guard case .html(let html) = artifact.payload else {
            return XCTFail("math 产物应为 html")
        }
        XCTAssertTrue(
            html.contains("katex"), "产物应含 katex 标记: \(html.prefix(80))")
    }
}
