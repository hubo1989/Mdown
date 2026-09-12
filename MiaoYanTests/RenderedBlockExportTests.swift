import AppKit
import WebKit
import XCTest

@testable import MiaoYan

@available(macOS 12.0, *)
final class RenderedBlockExportTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderedBlockExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory = tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - SVG Sanitization Tests

    func testSanitizeSvgRemovesScriptsAndEventHandlers() {
        let rawSvg = """
            <svg id="test-svg" width="300" height="200" onclick="alert('xss')" onmouseover="evil()">
              <script>alert('dangerous')</script>
              <g><text>Normal Text</text></g>
            </svg>
            """
        let cleaned = RenderedBlockExportController.sanitizeSvgForIndependentExport(rawSvg)

        XCTAssertFalse(cleaned.contains("<script>"))
        XCTAssertFalse(cleaned.contains("alert('dangerous')"))
        XCTAssertFalse(cleaned.contains("onclick="))
        XCTAssertFalse(cleaned.contains("onmouseover="))
        XCTAssertTrue(cleaned.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        XCTAssertTrue(cleaned.contains("<text>Normal Text</text>"))
    }

    func testSanitizeSvgEnsuresXmlnsAndStyles() {
        let rawSvg = """
            <svg viewBox="0 0 100 100">
              <use xlink:href="#my-marker"/>
              <text>Chinese 测试</text>
            </svg>
            """
        let cleaned = RenderedBlockExportController.sanitizeSvgForIndependentExport(rawSvg)
        XCTAssertTrue(cleaned.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        XCTAssertTrue(cleaned.contains("xmlns:xlink=\"http://www.w3.org/1999/xlink\""))
        XCTAssertTrue(cleaned.contains("Chinese 测试"))
        XCTAssertTrue(cleaned.contains("<style>"))
    }

    // MARK: - Direct SVG File Export Tests

    @MainActor
    func testExportSvgWritesValidFile() throws {
        let identity = RenderedBlockIdentity(noteId: "note-1", previewGeneration: 1, blockId: "mermaid-0", renderRevision: 1)
        let svg = """
            <svg id="d1" width="400" height="250" viewBox="0 0 400 250">
              <rect width="400" height="250" fill="#f0f0f0"/>
              <text x="20" y="50">Hello World 流程图</text>
            </svg>
            """
        let snapshot = RenderedBlockSnapshot(
            identity: identity,
            kind: .mermaid,
            svgContent: svg,
            naturalWidth: 400,
            naturalHeight: 250
        )

        let targetURL = tempDirectory.appendingPathComponent("exported-diagram.svg")
        let size = try RenderedBlockExportController.shared.exportSvg(snapshot: snapshot, to: targetURL)

        XCTAssertEqual(size.width, 400)
        XCTAssertEqual(size.height, 250)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))

        let writtenContent = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertTrue(writtenContent.contains("Hello World 流程图"))
        XCTAssertTrue(writtenContent.contains("xmlns=\"http://www.w3.org/2000/svg\""))
    }

    // MARK: - Isolated Offscreen PNG Export Tests

    @MainActor
    func testExportPngProducesAccurateDimensionsAndScales() async throws {
        let identity = RenderedBlockIdentity(noteId: "note-1", previewGeneration: 1, blockId: "mermaid-1", renderRevision: 1)
        let svg = """
            <svg id="d2" width="200" height="100" viewBox="0 0 200 100">
              <rect width="200" height="100" fill="#00aa55"/>
              <text x="10" y="30" fill="#ffffff" font-size="14">测试文字 200x100</text>
            </svg>
            """
        let padding: CGFloat = 16.0
        let snapshot = RenderedBlockSnapshot(
            identity: identity,
            kind: .mermaid,
            svgContent: svg,
            naturalWidth: 200,
            naturalHeight: 100,
            padding: padding
        )

        let expectedLogicalWidth = 200 + padding * 2  // 232
        let expectedLogicalHeight = 100 + padding * 2  // 132

        // 1. Test 1x Scale
        let targetURL1x = tempDirectory.appendingPathComponent("test-1x.png")
        let dim1x = try await RenderedBlockExportController.shared.exportPng(
            snapshot: snapshot,
            scale: .scale1x,
            background: .light,
            to: targetURL1x
        )
        XCTAssertEqual(dim1x.width, expectedLogicalWidth)
        XCTAssertEqual(dim1x.height, expectedLogicalHeight)

        let imageRep1x = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: targetURL1x)))
        XCTAssertEqual(imageRep1x.pixelsWide, Int(expectedLogicalWidth))
        XCTAssertEqual(imageRep1x.pixelsHigh, Int(expectedLogicalHeight))

        // 2. Test 2x Scale (Default HD)
        let targetURL2x = tempDirectory.appendingPathComponent("test-2x.png")
        let dim2x = try await RenderedBlockExportController.shared.exportPng(
            snapshot: snapshot,
            scale: .scale2x,
            background: .theme,
            to: targetURL2x
        )
        let expectedPixelWidth2x = Int(expectedLogicalWidth * 2.0)
        let expectedPixelHeight2x = Int(expectedLogicalHeight * 2.0)
        XCTAssertEqual(dim2x.width, CGFloat(expectedPixelWidth2x))
        XCTAssertEqual(dim2x.height, CGFloat(expectedPixelHeight2x))

        let imageRep2x = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: targetURL2x)))
        XCTAssertEqual(imageRep2x.pixelsWide, expectedPixelWidth2x)
        XCTAssertEqual(imageRep2x.pixelsHigh, expectedPixelHeight2x)
    }

    @MainActor
    func testExportPngSupportsTransparentBackground() async throws {
        let identity = RenderedBlockIdentity(noteId: "note-1", previewGeneration: 1, blockId: "mermaid-trans", renderRevision: 1)
        let svg = """
            <svg id="d-trans" width="150" height="80" viewBox="0 0 150 80">
              <circle cx="40" cy="40" r="30" fill="#3366cc" />
            </svg>
            """
        let snapshot = RenderedBlockSnapshot(
            identity: identity,
            kind: .mermaid,
            svgContent: svg,
            naturalWidth: 150,
            naturalHeight: 80,
            padding: 8
        )

        let targetURL = tempDirectory.appendingPathComponent("test-transparent.png")
        let dimensions = try await RenderedBlockExportController.shared.exportPng(
            snapshot: snapshot,
            scale: .scale1x,
            background: .transparent,
            to: targetURL
        )
        XCTAssertGreaterThan(dimensions.width, 0)

        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: targetURL)))
        XCTAssertTrue(rep.hasAlpha)
    }

    @MainActor
    func testExportPngRejectsOversizedCanvas() async {
        let identity = RenderedBlockIdentity(noteId: "note-1", previewGeneration: 1, blockId: "mermaid-oversize", renderRevision: 1)
        let snapshot = RenderedBlockSnapshot(
            identity: identity,
            kind: .mermaid,
            svgContent: "<svg></svg>",
            naturalWidth: 20000,
            naturalHeight: 20000
        )
        let targetURL = tempDirectory.appendingPathComponent("oversized.png")

        do {
            _ = try await RenderedBlockExportController.shared.exportPng(
                snapshot: snapshot,
                scale: .scale2x,
                to: targetURL
            )
            XCTFail("Should have thrown an error for oversized canvas")
        } catch {
            // Expected error
            XCTAssertTrue(error.localizedDescription.contains("maximum allowed size"))
        }
    }

    // MARK: - Large Diagram Handling (Viewport Exceeding)

    @MainActor
    func testExportLargeDiagramWithoutClipping() async throws {
        let identity = RenderedBlockIdentity(noteId: "note-1", previewGeneration: 1, blockId: "mermaid-large", renderRevision: 1)
        // 1400px width exceeds standard default window width (900px)
        let svg = """
            <svg id="d-large" width="1400" height="300" viewBox="0 0 1400 300">
              <rect x="0" y="0" width="1400" height="300" fill="#f8f9fa"/>
              <text x="10" y="50">Start of wide diagram</text>
              <text x="1300" y="50">End of wide diagram</text>
            </svg>
            """
        let snapshot = RenderedBlockSnapshot(
            identity: identity,
            kind: .mermaid,
            svgContent: svg,
            naturalWidth: 1400,
            naturalHeight: 300,
            padding: 16
        )

        let targetURL = tempDirectory.appendingPathComponent("wide-diagram.png")
        let dim = try await RenderedBlockExportController.shared.exportPng(
            snapshot: snapshot,
            scale: .scale1x,
            background: .light,
            to: targetURL
        )

        let expectedWidth: CGFloat = 1400 + 32
        let expectedHeight: CGFloat = 300 + 32
        XCTAssertEqual(dim.width, expectedWidth)
        XCTAssertEqual(dim.height, expectedHeight)

        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: targetURL)))
        XCTAssertEqual(rep.pixelsWide, Int(expectedWidth))
        XCTAssertEqual(rep.pixelsHigh, Int(expectedHeight))
    }

    // MARK: - KaTeX & PlantUML Export Tests (D3)

    @MainActor
    func testLoadKatexCssReturnsValidStylesheet() {
        let css = RenderedBlockExportController.loadKatexCss()
        XCTAssertNotNil(css)
        XCTAssertTrue(css?.contains(".katex") == true)
        XCTAssertTrue(css?.contains(".katex-display") == true)
    }

    @MainActor
    func testExportKatexHtmlSnapshotToPng() async throws {
        let identity = RenderedBlockIdentity(noteId: "note-1", previewGeneration: 1, blockId: "katex-0", renderRevision: 1)
        let katexHtml = """
            <span class="katex-display">
              <span class="katex">
                <span class="katex-html" aria-hidden="true">
                  <span class="base">
                    <span class="strut" style="height:0.6833em;"></span>
                    <span class="mord mathnormal">E</span>
                    <span class="mspace" style="margin-right:0.2778em;"></span>
                    <span class="mrel">=</span>
                    <span class="mspace" style="margin-right:0.2778em;"></span>
                  </span>
                  <span class="base">
                    <span class="strut" style="height:0.8641em;"></span>
                    <span class="mord mathnormal">m</span>
                    <span class="mord">
                      <span class="mord mathnormal">c</span>
                      <span class="msupsub">
                        <span class="vlist-t">
                          <span class="vlist-r">
                            <span class="vlist" style="height:0.8641em;">
                              <span style="top:-3.113em;margin-right:0.05em;">
                                <span class="pstrut" style="height:2.7em;"></span>
                                <span class="sizing reset-size6 size3 mtight"><span class="mord mtight">2</span></span>
                              </span>
                            </span>
                          </span>
                        </span>
                      </span>
                    </span>
                  </span>
                </span>
              </span>
            </span>
            """
        let snapshot = RenderedBlockSnapshot(
            identity: identity,
            kind: .katex,
            svgContent: nil,
            htmlContent: katexHtml,
            naturalWidth: 200,
            naturalHeight: 60,
            padding: 16.0
        )

        let targetURL = tempDirectory.appendingPathComponent("katex-formula.png")
        let dimensions = try await RenderedBlockExportController.shared.exportPng(
            snapshot: snapshot,
            scale: .scale2x,
            background: .light,
            to: targetURL
        )

        let expectedPixelWidth = Int((200 + 32) * 2.0)
        let expectedPixelHeight = Int((60 + 32) * 2.0)
        XCTAssertEqual(dimensions.width, CGFloat(expectedPixelWidth))
        XCTAssertEqual(dimensions.height, CGFloat(expectedPixelHeight))

        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: targetURL)))
        XCTAssertEqual(rep.pixelsWide, expectedPixelWidth)
        XCTAssertEqual(rep.pixelsHigh, expectedPixelHeight)
    }

    @MainActor
    func testExportPlantumlHtmlSnapshotToPng() async throws {
        let identity = RenderedBlockIdentity(noteId: "note-1", previewGeneration: 1, blockId: "plantuml-0", renderRevision: 1)
        // Inline tiny SVG as img data URI for self-contained testing
        let svgDataUri = "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='120' height='60'><rect width='120' height='60' fill='orange'/><text x='10' y='35'>PlantUML</text></svg>"
        let plantumlHtml = "<img class=\"plantuml-image\" src=\"\(svgDataUri)\" style=\"max-width: 100%; height: auto;\" />"

        let snapshot = RenderedBlockSnapshot(
            identity: identity,
            kind: .plantuml,
            svgContent: nil,
            htmlContent: plantumlHtml,
            naturalWidth: 120,
            naturalHeight: 60,
            padding: 16.0
        )

        let targetURL = tempDirectory.appendingPathComponent("plantuml-diagram.png")
        let dimensions = try await RenderedBlockExportController.shared.exportPng(
            snapshot: snapshot,
            scale: .scale1x,
            background: .light,
            to: targetURL
        )

        let expectedWidth: CGFloat = 120 + 32
        let expectedHeight: CGFloat = 60 + 32
        XCTAssertEqual(dimensions.width, expectedWidth)
        XCTAssertEqual(dimensions.height, expectedHeight)

        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: targetURL)))
        XCTAssertEqual(rep.pixelsWide, Int(expectedWidth))
        XCTAssertEqual(rep.pixelsHigh, Int(expectedHeight))
    }

    @MainActor
    func testExportSvgWithoutSvgContentFails() {
        let identity = RenderedBlockIdentity(noteId: "note-1", previewGeneration: 1, blockId: "no-svg", renderRevision: 1)
        let snapshot = RenderedBlockSnapshot(
            identity: identity,
            kind: .katex,
            svgContent: nil,
            htmlContent: "<span>No SVG</span>",
            naturalWidth: 100,
            naturalHeight: 50
        )

        let targetURL = tempDirectory.appendingPathComponent("should-fail.svg")
        XCTAssertThrowsError(try RenderedBlockExportController.shared.exportSvg(snapshot: snapshot, to: targetURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("No SVG content available"))
        }
    }
}
