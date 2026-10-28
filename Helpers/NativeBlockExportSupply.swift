import Foundation

// MARK: - T17 native 块导出供给(PLAN T17 / SPEC §9)
//
// 把隔离渲染宿主(Helpers/MarkdownBlockRenderHost)的静态产物映射成
// 既有 RenderedBlockExportController 消费的 RenderedBlockSnapshot:
// 同 fingerprint 的 ready artifact 直接复用;无 cache 时经宿主按需
// 生成;产物映射为纯函数(可独立断言)。html 块无导出 kind(导出器只
// 支持 mermaid/plantuml/katex),显式返回 nil 而非硬塞。

@MainActor
enum NativeBlockExportSupply {

    /// 供给一条快照:缓存优先,miss 时隔离宿主渲染。
    static func supply(
        _ request: MarkdownBlockRenderRequest, host: MarkdownBlockRenderHost
    ) async -> RenderedBlockSnapshot? {
        let artifact: MarkdownBlockArtifact?
        if let cached = host.cachedArtifact(for: request) {
            artifact = cached
        } else {
            artifact = await host.render(request)
        }
        guard let artifact else { return nil }
        return snapshot(for: request, artifact: artifact)
    }

    /// 纯映射:artifact → RenderedBlockSnapshot(交 exportSvg/exportPng)。
    static func snapshot(
        for request: MarkdownBlockRenderRequest, artifact: MarkdownBlockArtifact
    ) -> RenderedBlockSnapshot? {
        let kind: RenderedBlockKind
        switch request.kind {
        case .mermaid: kind = .mermaid
        case .plantuml: kind = .plantuml
        case .math: kind = .katex
        case .html: return nil  // 导出器无 html kind,不硬塞
        }
        let identity = RenderedBlockIdentity(
            noteId: request.noteID,
            previewGeneration: Int(request.themeGeneration),
            blockId: request.blockID,
            renderRevision: Int(request.revision))
        switch artifact.payload {
        case .svg(let svg):
            return RenderedBlockSnapshot(
                identity: identity, kind: kind, svgContent: svg,
                naturalWidth: artifact.naturalSize.width,
                naturalHeight: artifact.naturalSize.height)
        case .html(let html):
            return RenderedBlockSnapshot(
                identity: identity, kind: kind, svgContent: nil, htmlContent: html,
                naturalWidth: artifact.naturalSize.width,
                naturalHeight: artifact.naturalSize.height)
        }
    }
}
