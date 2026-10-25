import AppKit
import Foundation
import WebKit

// MARK: - T17 隔离渲染宿主(PLAN T17 剩余 1 / SPEC §9 / NE-28)
//
// 离屏 WKWebView 对单个不可变请求生成静态产物(mermaid → svg+尺寸;
// math → katex 静态 html+尺寸;html → 去脚本静态页)。不读主预览 DOM、
// 不改正文/模式;结果经 MarkdownBlockRenderCoordinator latest-wins
// 核对后才进 MarkdownBlockRenderCache。错误/超时/取消返回 nil 且不落
// 缓存。资源按 MermaidExportTests 修好的模式:bundle 内容拷进本地临时
// 目录、页面用相对路径引用、read access 只给该目录(WebContent 不为
// 外置构建卷签发 file-url 沙箱扩展)。plantuml 走既有
// RenderedBlockExportController 路径,本宿主返回 nil。

@MainActor
final class MarkdownBlockRenderHost {

    private let cache: MarkdownBlockRenderCache
    private let coordinator = MarkdownBlockRenderCoordinator()

    /// 测试观察口:最近一次 captureContext 的请求(latest-wins 时序断言)。
    private(set) var lastCapturedRequestForTesting: MarkdownBlockRenderRequest?

    init(cache: MarkdownBlockRenderCache = MarkdownBlockRenderCache(capacity: 8)) {
        self.cache = cache
    }

    func cachedArtifact(for request: MarkdownBlockRenderRequest) -> MarkdownBlockArtifact? {
        cache.artifact(for: request)
    }

    /// 渲染单个请求。同指纹命中缓存直接返回;否则经离屏渲染产出
    /// artifact,身份核对通过才落缓存。`beforeRender` 供测试在
    /// capture 之后、渲染之前挂起(制造过期窗口);超时/取消显式化。
    func render(
        _ request: MarkdownBlockRenderRequest,
        timeout: TimeInterval = 10,
        beforeRender: (@MainActor () async -> Void)? = nil
    ) async -> MarkdownBlockArtifact? {
        if let hit = cache.artifact(for: request) { return hit }
        let context = coordinator.captureContext(for: request)
        lastCapturedRequestForTesting = request

        if let beforeRender {
            await beforeRender()
        }
        guard !Task.isCancelled else { return nil }

        let artifact: MarkdownBlockArtifact?
        switch request.kind {
        case .html:
            artifact = MarkdownBlockArtifact(
                payload: .html(Self.staticHTMLPage(body: request.source)),
                naturalSize: .zero)
        case .mermaid:
            artifact = await renderMermaid(request, timeout: timeout)
        case .math:
            artifact = await renderMath(request, timeout: timeout)
        case .plantuml:
            artifact = nil  // 既有 RenderedBlockExportController 路径
        }
        guard !Task.isCancelled else { return nil }
        guard let artifact else { return nil }

        // latest-wins:迟到结果(渲染期间更新了请求)直接丢弃,不落缓存。
        let result = MarkdownBlockRenderResult.ready(context, artifact)
        guard coordinator.accepts(result) else { return nil }
        cache.store(artifact, for: request)
        return artifact
    }

    // MARK: - mermaid → 静态 SVG

    private func renderMermaid(
        _ request: MarkdownBlockRenderRequest, timeout: TimeInterval
    ) async -> MarkdownBlockArtifact? {
        guard
            let workspace = try? stageWorkspace(
                files: [
                    "js/mermaid.min.js", "js/theme-config.js", "js/theme-manager.js",
                    "js/diagram-handler.js",
                ])
        else { return nil }
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let page = """
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <script defer src="js/mermaid.min.js"></script>
              <script defer src="js/theme-config.js"></script>
              <script defer src="js/theme-manager.js"></script>
              <script defer src="js/diagram-handler.js"></script>
            </head>
            <body>
              <div id="write"><pre><code class="language-mermaid">\(Self.escapedHTMLText(request.source))</code></pre></div>
              <script>
                window.__miaoyanBlockRenderDone = false;
                window.__miaoyanBlockRenderError = null;
                document.addEventListener('DOMContentLoaded', async function () {
                  try {
                    if (typeof window.mermaid === 'undefined') {
                      throw new Error('js/mermaid.min.js failed to load');
                    }
                    if (typeof DiagramHandler === 'undefined') {
                      throw new Error('js/diagram-handler.js failed to load');
                    }
                    await DiagramHandler.initializeMermaid();
                  } catch (error) {
                    window.__miaoyanBlockRenderError = String(error);
                  } finally {
                    window.__miaoyanBlockRenderDone = true;
                  }
                });
              </script>
            </body>
            </html>
            """
        guard let pageURL = try? writePage(page, in: workspace) else { return nil }

        let webView = Self.makeWebView()
        webView.loadFileURL(pageURL, allowingReadAccessTo: workspace.root)
        guard await waitForPageReady(webView, timeout: timeout) else { return nil }
        guard await pageError(webView) == nil else { return nil }

        let extraction =
            """
            (function () {
              var code = document.querySelector('code.language-mermaid');
              if (!code) return JSON.stringify({error: 'no diagram node'});
              if (code.getAttribute('data-mermaid-rendered') !== 'true') {
                return JSON.stringify({error: 'mermaid render failed: ' + code.getAttribute('data-mermaid-rendered')});
              }
              var svg = code.querySelector('svg');
              if (!svg) return JSON.stringify({error: 'no svg node'});
              var rect = svg.getBoundingClientRect();
              return JSON.stringify({svg: svg.outerHTML, width: rect.width, height: rect.height});
            })()
            """
        guard let raw = try? await webView.evaluateJavaScript(extraction),
            let json = raw as? String,
            let parsed = Self.decodeRenderJSON(json),
            let svg = parsed["svg"] as? String
        else { return nil }
        let width = (parsed["width"] as? Double) ?? 0
        let height = (parsed["height"] as? Double) ?? 0
        guard width > 0, height > 0 else { return nil }
        return MarkdownBlockArtifact(
            payload: .svg(svg), naturalSize: NSSize(width: width, height: height))
    }

    // MARK: - math → katex 静态 HTML

    private func renderMath(
        _ request: MarkdownBlockRenderRequest, timeout: TimeInterval
    ) async -> MarkdownBlockArtifact? {
        guard
            let workspace = try? stageWorkspace(
                files: ["js/katex.min.js", "js/auto-render.min.js", "css/katex.min.css"])
        else { return nil }
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        // 源文本经 JSON 字符串字面量嵌入,转义交给 JSONSerialization。
        let sourceLiteral = Self.jsStringLiteral(request.source) ?? "''"
        let page = """
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <link rel="stylesheet" href="css/katex.min.css">
              <script defer src="js/katex.min.js"></script>
              <script defer src="js/auto-render.min.js"></script>
            </head>
            <body>
              <div id="miaoyan-math-body"></div>
              <script>
                window.__miaoyanBlockRenderDone = false;
                window.__miaoyanBlockRenderError = null;
                document.addEventListener('DOMContentLoaded', function () {
                  try {
                    if (typeof katex === 'undefined') {
                      throw new Error('js/katex.min.js failed to load');
                    }
                    var body = document.getElementById('miaoyan-math-body');
                    body.innerHTML = katex.renderToString(\(sourceLiteral), {
                      displayMode: true,
                      throwOnError: false,
                      trust: false
                    });
                  } catch (error) {
                    window.__miaoyanBlockRenderError = String(error);
                  } finally {
                    window.__miaoyanBlockRenderDone = true;
                  }
                });
              </script>
            </body>
            </html>
            """
        guard let pageURL = try? writePage(page, in: workspace) else { return nil }

        let webView = Self.makeWebView()
        webView.loadFileURL(pageURL, allowingReadAccessTo: workspace.root)
        guard await waitForPageReady(webView, timeout: timeout) else { return nil }
        guard await pageError(webView) == nil else { return nil }

        let extraction =
            """
            (function () {
              var body = document.getElementById('miaoyan-math-body');
              if (!body) return JSON.stringify({error: 'no math body'});
              var rect = body.getBoundingClientRect();
              return JSON.stringify({html: body.innerHTML, width: rect.width, height: rect.height});
            })()
            """
        guard let raw = try? await webView.evaluateJavaScript(extraction),
            let json = raw as? String,
            let parsed = Self.decodeRenderJSON(json),
            let html = parsed["html"] as? String,
            !html.isEmpty
        else { return nil }
        let width = (parsed["width"] as? Double) ?? 0
        let height = (parsed["height"] as? Double) ?? 0
        return MarkdownBlockArtifact(
            payload: .html(html), naturalSize: NSSize(width: width, height: height))
    }

    // MARK: - 工作区与页面基建

    private struct Workspace {
        let root: URL
    }

    /// 把 bundle 里的 renderer 资源拷进本地临时目录(避开外置卷
    /// file-url 沙箱限制),返回可写目录。
    private func stageWorkspace(files: [String]) throws -> Workspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiaoYanBlockRender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundleRoot = try downViewBundleRoot()
        for relative in files {
            let source = bundleRoot.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw NSError(
                    domain: "MarkdownBlockRenderHost", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "DownView.bundle/\(relative) missing"])
            }
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return Workspace(root: root)
    }

    private func downViewBundleRoot() throws -> URL {
        guard let url = Bundle.main.url(forResource: "DownView", withExtension: "bundle") else {
            throw NSError(
                domain: "MarkdownBlockRenderHost", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "DownView.bundle not in test host"])
        }
        return url
    }

    private func writePage(_ page: String, in workspace: Workspace) throws -> URL {
        let url = workspace.root.appendingPathComponent("block.html")
        try page.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        return WKWebView(
            frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
    }

    /// 轮询页面 done 标志;超时返回 false(调用方 → nil 产物)。
    private func waitForPageReady(_ webView: WKWebView, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if webView.url != nil,
                let raw = try? await webView.evaluateJavaScript(
                    "document.readyState === 'complete' && window.__miaoyanBlockRenderDone === true"),
                (raw as? Bool) == true
            {
                return true
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return false
    }

    /// 页面驱动脚本记录的 setup/渲染错误;nil = 干净。
    private func pageError(_ webView: WKWebView) async -> String? {
        guard
            let raw = try? await webView.evaluateJavaScript(
                "window.__miaoyanBlockRenderError"),
            let error = raw as? String
        else { return nil }
        return error.isEmpty ? nil : error
    }

    private static func decodeRenderJSON(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            dictionary["error"] == nil
        else { return nil }
        return dictionary
    }

    private static func escapedHTMLText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// JSON 字符串字面量(含引号),供 JS 侧直接求值。
    /// JSON 字符串字面量(含引号),供 JS 侧直接求值。
    private static func jsStringLiteral(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]) else {
            return nil
        }
        guard let arrayText = String(bytes: data, encoding: .utf8) else {  // ["..."]
            return nil
        }
        guard arrayText.hasPrefix("["), arrayText.hasSuffix("]") else { return nil }
        return String(arrayText.dropFirst().dropLast())  // "..."
    }

    /// html 块产物:原样内容去掉 script 块(SPEC:raw HTML 不执行编辑侧
    /// 脚本),包成静态页;不跑 WebKit。
    private static func staticHTMLPage(body: String) -> String {
        let stripped = stripScriptTags(body)
        return """
            <!doctype html>
            <html><head><meta charset="utf-8"></head>
            <body>\(stripped)</body></html>
            """
    }

    private static func stripScriptTags(_ text: String) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: "<script\\b[^>]*>[\\s\\S]*?</script\\s*>", options: [.caseInsensitive])
        else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: "")
    }

    // MARK: - SVG → NSImage(富编辑 display 附件用)

    /// 把 SVG 产物转为 NSImage(供 RichMarkdownTextView 挂 NSTextAttachment)。
    /// 经离屏 WKWebView 加载 SVG 后 takeSnapshot;失败返回 nil(调用方回退
    /// 源码显示,符合 INV-4)。
    func svgToImage(_ svg: String, naturalSize: NSSize, timeout: TimeInterval = 5) async -> NSImage? {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return nil }
        let webView = Self.makeWebView()
        // frame 对齐 naturalSize:snapshot rect 超出离屏默认 frame
        // (900×700)时落在可视区外,快照产 0×0 空图(高图必踩)。
        webView.frame = CGRect(origin: .zero, size: naturalSize)
        let page = """
            <!doctype html><html><head><meta charset="utf-8"></head>
            <body style="margin:0;background:transparent">\(svg)</body></html>
            """
        guard
            let workspace = try? stageWorkspace(files: []),
            let pageURL = try? writePage(page, in: workspace)
        else { return nil }
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        webView.loadFileURL(pageURL, allowingReadAccessTo: workspace.root)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if webView.isLoading == false, webView.url != nil { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: naturalSize)
        guard let image = try? await webView.takeSnapshot(configuration: config) else { return nil }
        return image
    }
}
