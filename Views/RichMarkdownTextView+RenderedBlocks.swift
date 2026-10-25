import AppKit
import Foundation

// MARK: 渲染块附件(PRD ND-02/03:Typora 式图/码切换)
//
// mermaid 等可渲染块在富编辑里的显示/挂载/切换:附件挂载与异步渲染
// 请求。主文件的 stored 状态(renderedImages/expandedRenderedBlocks/
// inFlightRenderBlocks/renderedImageProvider)为 internal,供本扩展访问。

extension RichMarkdownTextView {

    /// 块指纹(kind+source):渲染图缓存的 key;非渲染块返回 nil。
    /// 展开态按块序位记录(见主文件属性注释),与图缓存 key 分离。
    static func renderedBlockFingerprint(
        block: LosslessMarkdownParser.Block, document: LosslessMarkdownParser.Document
    ) -> String? {
        guard case .codeFence(let fenceInfo) = block.kind,
            MarkdownProjectionBuilder.isRenderableBlock(kind: block.kind, info: fenceInfo)
        else { return nil }
        let text = (document.source as NSString).substring(with: block.rangeUTF16)
        return fenceInfo.lowercased() + "\u{1F}" + text
    }

    /// 把已缓存的渲染图挂到 renderedBlock 段的 U+FFFC 字符上;缺图则发起渲染请求。
    func mountRenderedBlockAttachments(storage: NSTextStorage) {
        for item in rendered {
            let fingerprint = Self.renderedBlockFingerprint(block: item.block, document: document)
            guard let fingerprint else { continue }
            let attachmentSegments = item.projection.segments.filter { $0.kind == .renderedBlock }
            guard let segment = attachmentSegments.last else { continue }
            let range = displayRange(of: item, segment)
            guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
            if let image = renderedImages[fingerprint] {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(origin: .zero, size: image.size)
                storage.addAttribute(.attachment, value: attachment, range: range)
            } else {
                requestRenderedImage(fingerprint: fingerprint, block: item.block, document: document)
            }
        }
    }

    /// 异步渲染 mermaid → NSImage;完成后缓存并重建投影挂图。
    /// latest-wins:同指纹并发只保留最后一次;失败不缓存(下次重试,INV-4)。
    private func requestRenderedImage(
        fingerprint: String, block: LosslessMarkdownParser.Block, document: LosslessMarkdownParser.Document
    ) {
        guard !inFlightRenderBlocks.contains(fingerprint) else { return }
        guard case .codeFence(let fenceInfo) = block.kind else { return }
        // kind 判定与 isRenderableBlock 同规则;在线渲染当前仅 mermaid,
        // 其余语言(待接的 plantuml)没有产物,不发起注定失败的请求。
        guard fenceInfo.trimmingCharacters(in: .whitespaces).lowercased() == "mermaid" else { return }
        inFlightRenderBlocks.insert(fingerprint)
        // host 合同:source 是剥离围栏后的图源码(与主预览 cmark 输出
        // 一致)——整块原文含 ```mermaid 围栏行,mermaid 解析必失败。
        let blockText = (document.source as NSString).substring(with: block.rangeUTF16)
        let request = MarkdownBlockRenderRequest(
            blockID: fingerprint, noteID: "", revision: revision,
            themeGeneration: 0, kind: .mermaid,
            source: MarkdownProjectionBuilder.fenceContent(of: blockText))
        Task { @MainActor in
            defer { self.inFlightRenderBlocks.remove(fingerprint) }
            let image: NSImage?
            if let provider = self.renderedImageProvider {
                image = await provider(request)
            } else {
                let host = MarkdownBlockRenderHost()
                guard let artifact = await host.render(request) else {
                    #if DEBUG
                        print("[RichMarkdownTextView] mermaid render failed, fallback to source")
                    #endif
                    return
                }
                switch artifact.payload {
                case .svg(let svg):
                    image = await host.svgToImage(
                        svg, naturalSize: artifact.naturalSize)
                case .html:
                    image = nil  // math 的 HTML 产物暂不转图(留 ND-02 后续)
                }
            }
            guard let image else { return }
            // 核对 revision:渲染期间编辑过则丢弃迟到结果;编辑触发的
            // rebuild 已对本块发起过请求(被 in-flight 标记挡住),所以
            // 这里必须清标记并重建一次,让挂载对缺图块补发——否则图
            // 停在源码回退,直到下一次无关重建才恢复。Set.remove 幂等,
            // defer 的清理不受影响。
            guard request.revision == self.revision else {
                self.inFlightRenderBlocks.remove(fingerprint)
                self.rebuildProjection()
                return
            }
            self.renderedImages[fingerprint] = image
            self.rebuildProjection()
        }
    }

    /// 点击渲染块附件:在 collapsed(只显示图)⇄ expanded(源码+图)间切换。
    /// 只改显示态:不推进 revision、不入历史、不动 dirty。
    /// rendered 与 document.blocks 同序(rebuild 按序构建),序号即块序位。
    public func toggleRenderedBlock(at displayOffset: Int) -> Bool {
        for (blockIndex, item) in rendered.enumerated() {
            let fingerprint = Self.renderedBlockFingerprint(block: item.block, document: document)
            guard let fingerprint else { continue }
            let attachmentSegments = item.projection.segments.filter { $0.kind == .renderedBlock }
            guard let segment = attachmentSegments.last else { continue }
            let range = displayRange(of: item, segment)
            guard displayOffset >= range.location, displayOffset <= NSMaxRange(range) else {
                continue
            }
            if expandedRenderedBlocks.contains(blockIndex) {
                expandedRenderedBlocks.remove(blockIndex)
            } else {
                expandedRenderedBlocks.insert(blockIndex)
            }
            rebuildProjection()
            return true
        }
        return false
    }
}
