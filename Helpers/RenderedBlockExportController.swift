import AppKit
import Foundation
import WebKit

// MARK: - Core Types for Rendered Block Export

public enum RenderedBlockKind: String, Codable {
    case mermaid
    case plantuml
    case katex
}

public struct RenderedBlockIdentity: Equatable, Hashable, Codable {
    public let noteId: String
    public let previewGeneration: Int
    public let blockId: String
    public let renderRevision: Int

    public init(noteId: String, previewGeneration: Int, blockId: String, renderRevision: Int) {
        self.noteId = noteId
        self.previewGeneration = previewGeneration
        self.blockId = blockId
        self.renderRevision = renderRevision
    }
}

public struct RenderedBlockPreflight: Codable, Equatable {
    public let identity: RenderedBlockIdentity
    public let kind: RenderedBlockKind
    public let isReady: Bool
    public let naturalWidth: CGFloat
    public let naturalHeight: CGFloat
    public let supportsSvg: Bool
    public let supportsPng: Bool

    public init(
        identity: RenderedBlockIdentity,
        kind: RenderedBlockKind,
        isReady: Bool,
        naturalWidth: CGFloat,
        naturalHeight: CGFloat,
        supportsSvg: Bool = true,
        supportsPng: Bool = true
    ) {
        self.identity = identity
        self.kind = kind
        self.isReady = isReady
        self.naturalWidth = naturalWidth
        self.naturalHeight = naturalHeight
        self.supportsSvg = supportsSvg
        self.supportsPng = supportsPng
    }
}

public struct RenderedBlockSnapshot: Codable {
    public let identity: RenderedBlockIdentity
    public let kind: RenderedBlockKind
    public let svgContent: String?
    public let htmlContent: String?
    public let naturalWidth: CGFloat
    public let naturalHeight: CGFloat
    public let padding: CGFloat
    public let isDark: Bool
    public let backgroundColorHex: String?

    public init(
        identity: RenderedBlockIdentity,
        kind: RenderedBlockKind,
        svgContent: String?,
        htmlContent: String? = nil,
        naturalWidth: CGFloat,
        naturalHeight: CGFloat,
        padding: CGFloat = 16.0,
        isDark: Bool = false,
        backgroundColorHex: String? = nil
    ) {
        self.identity = identity
        self.kind = kind
        self.svgContent = svgContent
        self.htmlContent = htmlContent
        self.naturalWidth = naturalWidth
        self.naturalHeight = naturalHeight
        self.padding = padding
        self.isDark = isDark
        self.backgroundColorHex = backgroundColorHex
    }
}

public enum ExportFormat: String, Codable, CaseIterable {
    case png
    case svg
}

public enum ExportScale: Double, Codable, CaseIterable {
    case scale1x = 1.0
    case scale2x = 2.0
    case scale3x = 3.0

    public var title: String {
        switch self {
        case .scale1x: return "1×"
        case .scale2x: return "2×"
        case .scale3x: return "3×"
        }
    }
}

public enum ExportBackground: String, Codable, CaseIterable {
    case theme
    case transparent
    case light
    case dark

    public var title: String {
        switch self {
        case .theme: return "Follow Theme"
        case .transparent: return "Transparent"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public struct ExportRequest {
    public let requestId: UUID
    public let snapshot: RenderedBlockSnapshot
    public let destinationURL: URL
    public let format: ExportFormat
    public let scale: ExportScale
    public let background: ExportBackground

    public init(
        requestId: UUID = UUID(),
        snapshot: RenderedBlockSnapshot,
        destinationURL: URL,
        format: ExportFormat = .png,
        scale: ExportScale = .scale2x,
        background: ExportBackground = .theme
    ) {
        self.requestId = requestId
        self.snapshot = snapshot
        self.destinationURL = destinationURL
        self.format = format
        self.scale = scale
        self.background = background
    }
}

public enum ExportResult {
    case saved(destination: URL, dimensions: CGSize)
    case cancelled
    case failed(reason: String)
}

// MARK: - Isolated Exporter

@MainActor
public final class RenderedBlockExportController: NSObject {
    public static let shared = RenderedBlockExportController()

    private var activeHostWindow: NSWindow?
    private var activeHostWebView: WKWebView?
    private var activeNavigationDelegate: ExportNavDelegate?
    private var isExporting = false

    override private init() {
        super.init()
    }

    // MARK: - Sanitize SVG for Independent Display

    public nonisolated static func sanitizeSvgForIndependentExport(_ rawSvg: String, isDark: Bool = false) -> String {
        var svg = rawSvg

        // 1. Remove dangerous active scripts and event handlers (XSS prevention)
        let scriptRegex = try? NSRegularExpression(pattern: "<script[\\s\\S]*?</script>", options: [.caseInsensitive])
        if let scriptRegex = scriptRegex {
            svg = scriptRegex.stringByReplacingMatches(in: svg, options: [], range: NSRange(location: 0, length: svg.utf16.count), withTemplate: "")
        }

        let eventHandlerRegex = try? NSRegularExpression(pattern: "\\son\\w+\\s*=\\s*\"[^\"]*\"|\\son\\w+\\s*=\\s*'[^']*'", options: [.caseInsensitive])
        if let eventHandlerRegex = eventHandlerRegex {
            svg = eventHandlerRegex.stringByReplacingMatches(in: svg, options: [], range: NSRange(location: 0, length: svg.utf16.count), withTemplate: "")
        }

        // 2. Ensure essential xmlns attributes on root <svg>
        if !svg.contains("xmlns=\"http://www.w3.org/2000/svg\"") {
            if let range = svg.range(of: "<svg", options: .caseInsensitive) {
                svg.insert(contentsOf: " xmlns=\"http://www.w3.org/2000/svg\"", at: range.upperBound)
            }
        }
        if svg.contains("xlink:href") && !svg.contains("xmlns:xlink=") {
            if let range = svg.range(of: "<svg", options: .caseInsensitive) {
                svg.insert(contentsOf: " xmlns:xlink=\"http://www.w3.org/1999/xlink\"", at: range.upperBound)
            }
        }

        // 3. Inject base CSS typography rules if not present to ensure independent font rendering
        let fontStyle = """
            <style>
            svg { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
            text { font-family: inherit; }
            </style>
            """
        if !svg.contains(fontStyle), let range = svg.range(of: ">", options: [], range: svg.startIndex..<svg.endIndex) {
            svg.insert(contentsOf: fontStyle, at: range.upperBound)
        }

        return svg
    }

    // MARK: - Direct SVG Export

    public func exportSvg(snapshot: RenderedBlockSnapshot, to destinationURL: URL) throws -> CGSize {
        guard let rawSvg = snapshot.svgContent, !rawSvg.isEmpty else {
            throw NSError(domain: "RenderedBlockExportController", code: 1, userInfo: [NSLocalizedDescriptionKey: "No SVG content available"])
        }

        let cleanedSvg = Self.sanitizeSvgForIndependentExport(rawSvg, isDark: snapshot.isDark)
        guard let data = cleanedSvg.data(using: .utf8) else {
            throw NSError(domain: "RenderedBlockExportController", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode SVG as UTF-8"])
        }

        try data.write(to: destinationURL, options: .atomic)
        return CGSize(width: snapshot.naturalWidth, height: snapshot.naturalHeight)
    }

    // MARK: - Isolated Offscreen PNG Export

    public func exportPng(
        snapshot: RenderedBlockSnapshot,
        scale: ExportScale = .scale2x,
        background: ExportBackground = .theme,
        to destinationURL: URL
    ) async throws -> CGSize {
        guard !isExporting else {
            throw NSError(domain: "RenderedBlockExportController", code: 10, userInfo: [NSLocalizedDescriptionKey: "Another export is in progress"])
        }
        isExporting = true
        defer {
            isExporting = false
            cleanupHost()
        }

        let padding = snapshot.padding
        let width = max(10, snapshot.naturalWidth + padding * 2)
        let height = max(10, snapshot.naturalHeight + padding * 2)

        // Safety limit check: max 25 MP, single side max 16,384 px
        let pixelWidth = width * CGFloat(scale.rawValue)
        let pixelHeight = height * CGFloat(scale.rawValue)
        if pixelWidth > 16384 || pixelHeight > 16384 || (pixelWidth * pixelHeight) > 25_000_000 {
            throw NSError(domain: "RenderedBlockExportController", code: 11, userInfo: [NSLocalizedDescriptionKey: "Export dimensions exceed maximum allowed size"])
        }

        let targetFrame = CGRect(x: 0, y: 0, width: width, height: height)

        // Build offscreen composited window and webview
        let (window, webView) = createOffscreenHost(frame: targetFrame, background: background, isDark: snapshot.isDark)
        self.activeHostWindow = window
        self.activeHostWebView = webView

        let htmlString = generateExportHtml(snapshot: snapshot, background: background, width: width, height: height)

        // Load into webview
        try await loadHtmlInHost(webView: webView, html: htmlString)

        // Snapshot
        let hostScale = window.backingScaleFactor > 0 ? window.backingScaleFactor : (NSScreen.main?.backingScaleFactor ?? 2.0)
        let targetPixelWidth = Int(round(width * CGFloat(scale.rawValue)))
        let targetPixelHeight = Int(round(height * CGFloat(scale.rawValue)))

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = CGRect(x: 0, y: 0, width: width, height: height)
        snapshotConfig.snapshotWidth = NSNumber(value: Double(CGFloat(targetPixelWidth) / hostScale))

        let snapshotImage = try await webView.takeSnapshot(configuration: snapshotConfig)

        guard let tiffData = snapshotImage.tiffRepresentation,
            let rawBitmapRep = NSBitmapImageRep(data: tiffData)
        else {
            throw NSError(domain: "RenderedBlockExportController", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to encode snapshot image to PNG"])
        }

        let finalBitmapRep: NSBitmapImageRep
        if rawBitmapRep.pixelsWide == targetPixelWidth && rawBitmapRep.pixelsHigh == targetPixelHeight {
            finalBitmapRep = rawBitmapRep
        } else if let cgImage = snapshotImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            if let context = CGContext(
                data: nil,
                width: targetPixelWidth,
                height: targetPixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) {
                context.interpolationQuality = .high
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetPixelWidth, height: targetPixelHeight))
                if let resizedCGImage = context.makeImage() {
                    finalBitmapRep = NSBitmapImageRep(cgImage: resizedCGImage)
                } else {
                    finalBitmapRep = rawBitmapRep
                }
            } else {
                finalBitmapRep = rawBitmapRep
            }
        } else {
            finalBitmapRep = rawBitmapRep
        }

        guard let pngData = finalBitmapRep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "RenderedBlockExportController", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to encode snapshot image to PNG"])
        }

        try pngData.write(to: destinationURL, options: .atomic)
        let outputDimensions = CGSize(width: finalBitmapRep.pixelsWide, height: finalBitmapRep.pixelsHigh)
        return outputDimensions
    }

    // MARK: - KaTeX CSS Cache

    private static var _cachedKatexCss: String?
    public static func loadKatexCss() -> String? {
        if let cached = _cachedKatexCss {
            return cached
        }
        let bundle =
            Bundle.main.url(forResource: "DownView", withExtension: "bundle")
            ?? Bundle(for: RenderedBlockExportController.self).url(forResource: "DownView", withExtension: "bundle")
        guard let url = bundle?.appendingPathComponent("css/katex.min.css"),
            let css = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        _cachedKatexCss = css
        return css
    }

    // MARK: - HTML Template Generator

    public func generateExportHtml(
        snapshot: RenderedBlockSnapshot,
        background: ExportBackground,
        width: CGFloat,
        height: CGFloat
    ) -> String {
        let isDark = snapshot.isDark
        let bgStyle: String
        switch background {
        case .transparent:
            bgStyle = "background-color: transparent !important;"
        case .theme:
            bgStyle = isDark ? "background-color: #23282D !important;" : "background-color: #FFFFFF !important;"
        case .light:
            bgStyle = "background-color: #FFFFFF !important;"
        case .dark:
            bgStyle = "background-color: #23282D !important;"
        }

        let textColor = isDark ? "#E7E9EA" : "#262626"
        let content: String
        if let svg = snapshot.svgContent, !svg.isEmpty {
            content = Self.sanitizeSvgForIndependentExport(svg, isDark: isDark)
        } else if let html = snapshot.htmlContent, !html.isEmpty {
            content = html
        } else {
            content = ""
        }

        var extraHead = ""
        if snapshot.kind == .katex {
            if let katexCss = Self.loadKatexCss() {
                extraHead += "  <style>\n\(katexCss)\n  </style>\n"
            }
        }

        return """
            <!DOCTYPE html>
            <html class="\(isDark ? "darkmode" : "")">
            <head>
              <meta charset="utf-8" />
            \(extraHead)  <style>
                :root {
                  --bg-color: \(isDark ? "#23282D" : "#FFFFFF");
                  --text-color: \(textColor);
                }
                html, body {
                  margin: 0;
                  padding: 0;
                  width: \(width)px;
                  height: \(height)px;
                  overflow: hidden;
                  \(bgStyle)
                  color: \(textColor);
                  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                  display: flex;
                  align-items: center;
                  justify-content: center;
                  box-sizing: border-box;
                }
                #container {
                  display: flex;
                  align-items: center;
                  justify-content: center;
                  padding: \(snapshot.padding)px;
                  box-sizing: border-box;
                  width: 100%;
                  height: 100%;
                }
                svg {
                  max-width: 100%;
                  max-height: 100%;
                  display: block;
                }
                .katex-display {
                  margin: 0 !important;
                }
              </style>
            </head>
            <body>
              <div id="container">
                \(content)
              </div>
            </body>
            </html>
            """
    }

    // MARK: - Host Management

    private func createOffscreenHost(
        frame: CGRect,
        background: ExportBackground,
        isDark: Bool
    ) -> (NSWindow, WKWebView) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        configuration.suppressesIncrementalRendering = false
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")

        // Create an offscreen window composited with alphaValue 0
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = webView
        window.orderFrontRegardless()

        return (window, webView)
    }

    private func loadHtmlInHost(webView: WKWebView, html: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let navDelegate = ExportNavDelegate { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
            self.activeNavigationDelegate = navDelegate
            webView.navigationDelegate = navDelegate
            webView.loadHTMLString(html, baseURL: nil)
        }

        // Wait briefly for font rendering to settle
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if let ready = try? await webView.evaluateJavaScript("document.readyState === 'complete' && (document.fonts ? document.fonts.status === 'loaded' : true)") as? Bool, ready {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func cleanupHost() {
        activeHostWebView?.stopLoading()
        activeHostWebView?.navigationDelegate = nil
        activeHostWebView = nil
        activeNavigationDelegate = nil
        activeHostWindow?.orderOut(nil)
        activeHostWindow = nil
    }
}

private final class ExportNavDelegate: NSObject, WKNavigationDelegate {
    private let completion: (Error?) -> Void

    init(completion: @escaping (Error?) -> Void) {
        self.completion = completion
        super.init()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completion(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion(error)
    }
}
