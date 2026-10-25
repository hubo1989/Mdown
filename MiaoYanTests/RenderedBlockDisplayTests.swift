import AppKit
import XCTest

@testable import MiaoYan

/// T19 渲染块显示(ND-02/03):mermaid 在富编辑里的图/码切换合同。
///
/// 缺图首帧必须保留 renderedBlock 附件段——挂载依赖该段发起渲染请求,
/// 滤掉该段即首图死锁(图永远不出现,实机根因)。渲染请求的 source 必须是
/// 剥离围栏后的图源码(host 合同,与主预览 cmark 输出一致)。实机点击
/// 交互与真实渲染产物属 smoke 实测项,不在此冒充。
@MainActor
final class RenderedBlockDisplayTests: XCTestCase {

    /// provider 回调记录(类本身 @MainActor,与 provider 同 isolate,
    /// 无需锁)。
    private var capturedSources: [String] = []
    private var requestCount = 0

    private func makeView(
        _ source: String,
        provider: (@MainActor (MarkdownBlockRenderRequest) async -> NSImage?)? = nil
    ) -> RichMarkdownTextView {
        // provider 必须经 init 传入:首次投影即发起渲染请求,后置赋值
        // 拦不住首帧(会真起 WKWebView)。
        let view = RichMarkdownTextView(source: source, renderedImageProvider: provider)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        addTeardownBlock { [weak window] in window?.close() }
        return view
    }

    /// 轮询等待视图状态满足条件(图挂载/投影重建都是异步 Task)。
    private func waitUntil(
        _ condition: () -> Bool, timeout: TimeInterval = 3,
        _ message: @autoclosure () -> String = "", file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail(message(), file: file, line: line)
    }

    func testMermaidKeepsAttachmentSegmentBeforeImageArrives() {
        let view = makeView("```mermaid\ngraph TD\nA-->B\n```\n")
        // 缺图首帧:源码必须可见可编辑(INV-4 无效图表合同),
        // 且 U+FFFC 附件段必须保留(渲染请求的挂载点,滤掉即死锁)。
        XCTAssertTrue(
            view.displayText.contains("graph TD"), "缺图首帧源码应可见: \(view.displayText.debugDescription)")
        XCTAssertTrue(
            view.displayText.contains("\u{FFFC}"), "缺图首帧必须保留附件占位: \(view.displayText.debugDescription)")
    }

    func testRenderRequestStripsFences() {
        let source = "```mermaid\nflowchart LR\nA-->B\n```\n"
        let provider: @MainActor (MarkdownBlockRenderRequest) async -> NSImage? = { [weak self] request in
            self?.capturedSources.append(request.source)
            return nil
        }
        let view = makeView(source, provider: provider)
        waitUntil(
            { !self.capturedSources.isEmpty },
            "缺图首帧应发起渲染请求")

        XCTAssertEqual(capturedSources.count, 1, "同一块缺图期间只发起一次请求")
        XCTAssertEqual(
            capturedSources.first, "flowchart LR\nA-->B\n",
            "请求 source 必须剥离围栏(host 合同,带围栏 mermaid 必然解析失败)")
    }

    func testPlantumlFenceSkipsInlineRendering() {
        let provider: @MainActor (MarkdownBlockRenderRequest) async -> NSImage? = { [weak self] _ in
            self?.requestCount += 1
            return nil
        }
        let view = makeView("```plantuml\n@startuml\nA-->B\n@enduml\n```\n", provider: provider)
        // plantuml 走既有导出管线(host.render 返回 nil);富编辑侧没有
        // 在线产物,不得进入占位投影或发起必然失败的请求。
        XCTAssertEqual(
            view.displayText, "```plantuml\n@startuml\nA-->B\n@enduml\n```\n",
            "无在线渲染产物的块应显示纯源码: \(view.displayText.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(requestCount, 0, "plantuml 不得发起在线渲染请求")
    }

    func testMountedImageCollapsesToAttachmentGlyph() {
        let image = NSImage(size: NSSize(width: 40, height: 20))
        let provider: @MainActor (MarkdownBlockRenderRequest) async -> NSImage? = { _ in image }
        let view = makeView("```mermaid\nflowchart LR\nA-->B\n```\n", provider: provider)
        // 文档解析为 [fence, 尾 blank 块],blank 贡献块间补行的 \n。
        waitUntil(
            { view.displayText == "\u{FFFC}\n" },
            "图就绪后 collapsed 态应只显示附件图: \(view.displayText.debugDescription)")
        // 附件属性真的挂上了
        let storage = view.textStorage!
        XCTAssertNotNil(
            storage.attribute(.attachment, at: 0, effectiveRange: nil),
            "U+FFFC 上必须挂 NSTextAttachment")
    }

    func testToggleExpandsSourceAboveMountedImage() throws {
        let image = NSImage(size: NSSize(width: 40, height: 20))
        let provider: @MainActor (MarkdownBlockRenderRequest) async -> NSImage? = { _ in image }
        let view = makeView("```mermaid\nflowchart LR\nA-->B\n```\n", provider: provider)
        waitUntil(
            { view.displayText == "\u{FFFC}\n" },
            "图就绪后 collapsed 态应只显示附件图: \(view.displayText.debugDescription)")

        // 点击附件位 → 展开:上方源码、下方图(Typora 交互)。
        XCTAssertTrue(view.toggleRenderedBlock(at: 0), "附件位置点击应命中切换")
        let expanded = view.displayText
        XCTAssertEqual(
            expanded, "```mermaid\nflowchart LR\nA-->B\n```\n\u{FFFC}\n",
            "展开态应为源码 + 附件图: \(expanded.debugDescription)")
        // 图在源码下方(U+FFFC 是最后一个可见字符)
        XCTAssertTrue(expanded.hasSuffix("\u{FFFC}\n"), "图应在源码下方")

        // 再点收起(附件字符在尾换行前一位)
        let attachmentOffset = (expanded as NSString).length - 2
        XCTAssertTrue(view.toggleRenderedBlock(at: attachmentOffset))
        XCTAssertEqual(view.displayText, "\u{FFFC}\n", "再次点击应收起回只显示图")
    }

    func testEditingExpandedSourceRemountsRefreshedImage() throws {
        let source = "```mermaid\nflowchart LR\nA-->B\n```\n"
        let image = NSImage(size: NSSize(width: 40, height: 20))
        let provider: @MainActor (MarkdownBlockRenderRequest) async -> NSImage? = { [weak self] request in
            self?.capturedSources.append(request.source)
            return image
        }
        let view = makeView(source, provider: provider)
        waitUntil(
            { view.displayText == "\u{FFFC}\n" },
            "图就绪后 collapsed 态应只显示附件图: \(view.displayText.debugDescription)")
        XCTAssertTrue(view.toggleRenderedBlock(at: 0), "展开编辑态")

        // 在展开的源码内插入(用户改图的正常路径)。
        let offset = try XCTUnwrap(
            view.displayOffset(forSourceOffset: (source as NSString).range(of: "flowchart").location))
        view.setSelectedRange(NSRange(location: offset, length: 0))
        view.insertText("C")
        let edited = "```mermaid\nCflowchart LR\nA-->B\n```\n"
        XCTAssertEqual(view.source, edited)

        // 新指纹重渲染:请求携带剥离围栏的新内容,展开态保持源码+图。
        waitUntil(
            { self.capturedSources.count >= 2 },
            "内容变化后应发起新渲染请求")
        XCTAssertEqual(
            capturedSources.last, "Cflowchart LR\nA-->B\n", "新请求应携带剥离围栏后的新内容")
        waitUntil(
            { view.displayText == edited + "\u{FFFC}\n" },
            "重渲染后应保持展开态(源码+图): \(view.displayText.debugDescription)")
    }

    func testStaleResultRetriesAfterUnrelatedEdit() throws {
        let source = "```mermaid\nflowchart LR\nA-->B\n```\ntail\n"
        let image = NSImage(size: NSSize(width: 40, height: 20))
        let provider: @MainActor (MarkdownBlockRenderRequest) async -> NSImage? = { [weak self] _ in
            guard let self else { return nil }
            let count = self.requestCount
            self.requestCount += 1
            if count == 0 {
                // 制造在途窗口:首请求晚归,期间主线程继续编辑
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            return image
        }
        let view = makeView(source, provider: provider)
        waitUntil(
            { self.requestCount >= 1 },
            "首请求应发起")

        // 无关编辑(mermaid 块未变,同指纹):revision +1;编辑触发的
        // rebuild 对本块的请求被 in-flight 标记挡住。
        let tail = try XCTUnwrap(
            view.displayOffset(forSourceOffset: (source as NSString).range(of: "tail").location))
        view.setSelectedRange(NSRange(location: tail, length: 0))
        view.insertText("x")

        // 迟到结果被 revision guard 拒收后必须补发同指纹请求并挂图,
        // 否则图永远停在源码回退(Codex review: RenderedBlocks.swift:87)。
        waitUntil(
            { view.displayText.hasPrefix("\u{FFFC}") },
            "迟到结果丢弃后应补发请求并挂图: \(view.displayText.debugDescription)")
        XCTAssertGreaterThanOrEqual(requestCount, 2, "同指纹应至少发起两次请求")
    }

    /// PR #10 Codex review:主题切换后已渲染图不得停在旧主题。
    ///
    /// 图缓存 key 只含内容指纹,不含主题;host 的 updateAppearance 只
    /// 刷字体/颜色,从不清 renderedImages——深浅切换后已挂的图永久使用
    /// 旧主题栅格。经真实入口(host.updateAppearance + userData.isDark
    /// 翻转)断言:主题真变时缺图块必须补发渲染请求并重新收起。
    @MainActor
    func testThemeFlipThroughHostReRequestsRenderedImage() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiaoYanRenderedBlockThemeTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }

        let noteURL = tempDir.appendingPathComponent("mermaid.md")
        let body = "```mermaid\nflowchart LR\nA-->B\n```\n"
        try? body.write(to: noteURL, atomically: true, encoding: .utf8)
        let project = Project(url: tempDir, label: "test", isRoot: true)
        let note = Note(url: noteURL, with: project)
        note.content = NSMutableAttributedString(string: body)
        note.markContentAsLoaded()

        let host = NativeRichEditorHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        addTeardownBlock { [weak window] in window?.close() }

        // host init 时 source 为空、无渲染块,后置注入 provider 拦得住
        // 首帧(装载发生在 loadNote)。
        let image = NSImage(size: NSSize(width: 40, height: 20))
        host.textView.renderedImageProvider = { [weak self] _ in
            self?.requestCount += 1
            return image
        }
        host.loadNote(note)
        waitUntil(
            { host.textView.displayText == "\u{FFFC}\n" },
            "首图挂载后 collapsed 态应只显示附件图: \(host.textView.displayText.debugDescription)")
        XCTAssertEqual(requestCount, 1, "同内容首图只应请求一次")

        // 主题翻转 + 真实外观入口:缓存必须作废并按新主题重渲。
        let userData = AppEnvironment.current.userData
        let originalIsDark = userData.isDark
        defer { userData.isDark = originalIsDark }
        userData.isDark = !originalIsDark
        host.updateAppearance()

        waitUntil(
            { self.requestCount >= 2 },
            "主题切换后应对缺图块补发渲染请求,而非复用旧主题缓存图")
        waitUntil(
            { host.textView.displayText == "\u{FFFC}\n" },
            "重渲完成后应重新收起为附件图: \(host.textView.displayText.debugDescription)")

        // 同主题重复刷新(字体等外观更新)不得反复作废重渲。
        let countAfterThemeFlip = requestCount
        host.updateAppearance()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(requestCount, countAfterThemeFlip, "主题未变时的外观刷新不应清渲染图缓存")
    }

    /// 失效方法本身的机制合同:清缓存 → 缺图投影 → 补发请求 → 重新收起。
    /// host 入口的接线由上一用例经 updateAppearance 覆盖;这里直调隔离
    /// 验证 RichMarkdownTextView 侧行为。
    func testInvalidateRenderedBlockImagesReRequestsAndRecollapses() {
        let image = NSImage(size: NSSize(width: 40, height: 20))
        let provider: @MainActor (MarkdownBlockRenderRequest) async -> NSImage? = { [weak self] _ in
            self?.requestCount += 1
            return image
        }
        let view = makeView("```mermaid\nflowchart LR\nA-->B\n```\n", provider: provider)
        waitUntil(
            { view.displayText == "\u{FFFC}\n" },
            "图就绪后 collapsed 态应只显示附件图: \(view.displayText.debugDescription)")
        XCTAssertEqual(requestCount, 1, "同内容首图只应请求一次")

        // 失效瞬间:缓存已清,投影必须立刻回到缺图态(源码 + 附件段),
        // 并同步对缺图块补发渲染请求。
        view.invalidateRenderedBlockImages()
        XCTAssertTrue(
            view.displayText.contains("flowchart LR"),
            "失效后缓存已清,应回缺图 expanded 投影: \(view.displayText.debugDescription)")
        waitUntil(
            { self.requestCount >= 2 },
            "失效后应对缺图块补发渲染请求")
        waitUntil(
            { view.displayText == "\u{FFFC}\n" },
            "重渲完成后应重新收起为附件图: \(view.displayText.debugDescription)")

        // 缓存为空时失效必须是空操作(不重建、不补发):用永不产图的
        // provider 隔离验证——首请求返回 nil 后缓存仍空,再失效不应
        // 触发额外请求。
        var nilProviderRequestCount = 0
        let nilProvider: @MainActor (MarkdownBlockRenderRequest) async -> NSImage? = { _ in
            nilProviderRequestCount += 1
            return nil
        }
        let nilView = makeView("```mermaid\nflowchart TD\nA-->B\n```\n", provider: nilProvider)
        waitUntil(
            { nilProviderRequestCount >= 1 },
            "缺图首帧应发起一次请求")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let countBeforeEmptyInvalidate = nilProviderRequestCount
        nilView.invalidateRenderedBlockImages()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(
            nilProviderRequestCount, countBeforeEmptyInvalidate,
            "缓存已空时失效应为空操作,不得触发重建或补发")
    }

    /// 渲染请求必须携带当前明暗态(PR #10 主题 finding 完整链路:
    /// host 页面按 isDarkTheme 注入 darkmode class,否则 mermaid
    /// 恒渲浅色图,主题切换重渲也产不出深色)。
    func testRenderRequestCarriesCurrentAppearance() {
        let userData = AppEnvironment.current.userData
        let original = userData.isDark
        defer { userData.isDark = original }
        var capturedDark: [Bool] = []
        let provider: @MainActor (MarkdownBlockRenderRequest) async -> NSImage? = { [weak self] request in
            self?.capturedSources.append(request.source)
            capturedDark.append(request.isDarkTheme)
            return nil
        }

        userData.isDark = true
        _ = makeView("```mermaid\nflowchart LR\nA-->B\n```\n", provider: provider)
        waitUntil(
            { !capturedDark.isEmpty },
            "首请求应发起")
        XCTAssertEqual(capturedDark, [true], "深色态请求必须携带 isDarkTheme=true")

        // 翻转明暗后,新视图的首请求应携带新值(invalidate 在缓存
        // 为空时按合同幂等跳过,不走它;每个视图首请求都读当前态)。
        userData.isDark = false
        _ = makeView("```mermaid\nflowchart TD\nC-->D\n```\n", provider: provider)
        waitUntil(
            { capturedDark.count >= 2 },
            "第二个视图应发起请求")
        XCTAssertEqual(capturedDark.last, false, "浅色态请求必须携带 isDarkTheme=false")
    }
}
