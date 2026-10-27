import WebKit
import XCTest

@available(macOS 12.0, *)
final class MermaidExportTests: XCTestCase {
    private var tempDirectory: URL!
    private var downViewBundleURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiaoYan Mermaid Export Tests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let bundle = try XCTUnwrap(
            Bundle.main.url(forResource: "DownView", withExtension: "bundle"),
            "DownView.bundle must be present in the test host app")
        // WebContent 不一定能为构建产物所在卷签发 file-url sandbox 扩展
        // (SYMROOT 指向外置卷时脚本加载整体失败)。把页面与脚本一起放到
        // 本地临时目录,以相对路径引用,只把 read access 交给该目录。
        downViewBundleURL = bundle
        let jsDestination = tempDirectory.appendingPathComponent("js", isDirectory: true)
        try FileManager.default.createDirectory(at: jsDestination, withIntermediateDirectories: true)
        let bundleJS = bundle.appendingPathComponent("js", isDirectory: true)
        for name in ["mermaid.min.js", "theme-config.js", "theme-manager.js", "diagram-handler.js"] {
            let source = bundleJS.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw NSError(
                    domain: "MermaidExportTests", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "DownView.bundle/js/\(name) missing"])
            }
            try FileManager.default.copyItem(
                at: source, to: jsDestination.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    @MainActor
    func testRenderedMermaidSurvivesExportReloadWithoutOrphanError() async throws {
        let webView = makeWebView()
        let sourceURL = try writePage(
            named: "source",
            mermaid: """
                flowchart LR
                A["Normal diagram A"] --> B["Normal diagram B"]
                """)

        webView.loadFileURL(sourceURL, allowingReadAccessTo: tempDirectory)
        try await waitForMermaid(in: webView, expectedURL: sourceURL, expectedPage: "source")

        let initialState = try await readState(from: webView)
        XCTAssertEqual(initialState.rendered, "true")
        XCTAssertEqual(initialState.diagramSVGCount, 1)
        XCTAssertEqual(initialState.orphanErrorContainerCount, 0)

        let rawRenderedHTML = try await webView.evaluateJavaScript("document.documentElement.outerHTML")
        let renderedHTML = try XCTUnwrap(rawRenderedHTML as? String)
        let reloadHTML = renderedHTML.replacingOccurrences(
            of: "data-miaoyan-test-page=\"source\"",
            with: "data-miaoyan-test-page=\"export-reload\"")
        XCTAssertNotEqual(reloadHTML, renderedHTML)
        let reloadURL = tempDirectory.appendingPathComponent("export-reload.html")
        try reloadHTML.write(to: reloadURL, atomically: true, encoding: .utf8)

        webView.loadFileURL(reloadURL, allowingReadAccessTo: tempDirectory)
        try await waitForMermaid(
            in: webView,
            expectedURL: reloadURL,
            expectedPage: "export-reload")

        let reloadedState = try await readState(from: webView)
        XCTAssertEqual(reloadedState.rendered, "true")
        XCTAssertEqual(reloadedState.diagramSVGCount, 1)
        XCTAssertEqual(reloadedState.orphanErrorContainerCount, 0)
        XCTAssertEqual(reloadedState.errorNodeCount, 0)
    }

    @MainActor
    func testInvalidMermaidFallsBackWithoutOrphanError() async throws {
        let webView = makeWebView()
        let sourceURL = try writePage(
            named: "invalid-source",
            mermaid: "flowchart ??? definitely invalid")

        webView.loadFileURL(sourceURL, allowingReadAccessTo: tempDirectory)
        try await waitForMermaid(
            in: webView,
            expectedURL: sourceURL,
            expectedPage: "invalid-source")

        let state = try await readState(from: webView)
        XCTAssertEqual(state.rendered, "failed")
        XCTAssertTrue(state.hasSourceFallback)
        XCTAssertEqual(state.diagramSVGCount, 0)
        XCTAssertEqual(state.orphanErrorContainerCount, 0)
        XCTAssertEqual(state.errorNodeCount, 0)
    }

    @MainActor
    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        return WKWebView(
            frame: CGRect(x: 0, y: 0, width: 900, height: 700),
            configuration: configuration)
    }

    private func writePage(named name: String, mermaid source: String) throws -> URL {
        let escapedSource =
            source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let page = """
            <!doctype html>
            <html data-miaoyan-test-page="\(name)">
            <head>
              <meta charset="utf-8">
              <script defer src="js/mermaid.min.js"></script>
              <script defer src="js/theme-config.js"></script>
              <script defer src="js/theme-manager.js"></script>
              <script defer src="js/diagram-handler.js"></script>
            </head>
            <body>
              <div id="write"><pre><code class="language-mermaid">\(escapedSource)</code></pre></div>
              <script>
                window.__miaoyanMermaidTestDone = false;
                window.__miaoyanMermaidTestError = null;
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
                    window.__miaoyanMermaidTestError = String(error);
                  } finally {
                    window.__miaoyanMermaidTestDone = true;
                  }
                });
              </script>
            </body>
            </html>
            """
        let url = tempDirectory.appendingPathComponent("\(name).html")
        try page.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor
    private func waitForMermaid(
        in webView: WKWebView,
        expectedURL: URL,
        expectedPage: String
    ) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if webView.url?.path == expectedURL.path,
                let raw = try? await webView.evaluateJavaScript(
                    """
                    document.readyState === 'complete' &&
                      document.documentElement.dataset.miaoyanTestPage === '\(expectedPage)' &&
                      window.__miaoyanMermaidTestDone === true
                      ? (window.__miaoyanMermaidTestError || 'ok') : null
                    """),
                let status = raw as? String
            {
                if status == "ok" { return }
                throw NSError(
                    domain: "MermaidExportTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Mermaid setup failed for \(expectedPage): \(status)"])
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw NSError(
            domain: "MermaidExportTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Mermaid rendering (page did not reach done flag)"])
    }

    @MainActor
    private func readState(from webView: WKWebView) async throws -> MermaidDOMState {
        let raw = try await webView.evaluateJavaScript(
            """
            ({
              rendered: document.querySelector('code.language-mermaid')?.getAttribute('data-mermaid-rendered') || null,
              diagramSVGCount: document.querySelectorAll('code.language-mermaid svg').length,
              orphanErrorContainerCount: document.querySelectorAll('body > div[id^="dmermaid-"]').length,
              errorNodeCount: document.querySelectorAll('svg .error-icon, svg .error-text').length,
              hasSourceFallback: document.querySelector('pre')?.classList.contains('mermaid-source-fallback') || false
            })
            """)
        let dictionary = try XCTUnwrap(raw as? [String: Any])
        return MermaidDOMState(
            rendered: dictionary["rendered"] as? String,
            diagramSVGCount: try XCTUnwrap(dictionary["diagramSVGCount"] as? Int),
            orphanErrorContainerCount: try XCTUnwrap(dictionary["orphanErrorContainerCount"] as? Int),
            errorNodeCount: try XCTUnwrap(dictionary["errorNodeCount"] as? Int),
            hasSourceFallback: try XCTUnwrap(dictionary["hasSourceFallback"] as? Bool)
        )
    }
}

@available(macOS 12.0, *)
private struct MermaidDOMState {
    let rendered: String?
    let diagramSVGCount: Int
    let orphanErrorContainerCount: Int
    let errorNodeCount: Int
    let hasSourceFallback: Bool
}
