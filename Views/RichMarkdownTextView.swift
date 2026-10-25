import AppKit

private func ascii16(_ c: Character) -> unichar {
    unichar(c.unicodeScalars.first!.value)
}

/// T04 / G0 可行性原型：TextKit 1 上的 rich Markdown 编辑面。
/// 纯内存 session（source + revision + selection），不读 Note/Storage；
/// T05 通过 G0 后收敛到正式 MarkdownEditingSession。
///
/// 工作方式：
/// - 显示 = 各块投影的 display 拼接（块间 "\n"），hidden marker 无字形；
/// - 用户编辑发生在 display 上；textDidChange 后把 display 增量差异经
///   投影段映射为 source patch（MarkdownPatchApplier 原子应用），source
///   是权威；映射不安全（落在 marker 段）时按段边界安全展开；
/// - composition（IME markedText）期间**不重建投影**（不打断
///   markedTextRange），source 实时跟随 display；提交后一次重建；
/// - 每次编辑后立即重建投影坐标（display 未变时 textStorage 替换被
///   跳过，无闪烁），rendered 定位始终新鲜；
/// - Enter/Tab/Backspace 在 list 内走结构 patch；点击/移动 caret 不触发
///   任何 source 化。
@MainActor
public final class RichMarkdownTextView: NSTextView, NSTextViewDelegate {
    /// T10：source 提交观察口。每次 source 变化（typing / composition /
    /// 结构命令 / undo / redo / 程序化 setSource）后回调；host（
    /// NativeRichEditorHostView）用它镜像 note.content 并安排 debounce
    /// 保存。程序化装载由 host 的 lastLoaded 守卫丢弃，不产生假编辑。
    public var onSourceCommitted: ((String) -> Void)?

    public private(set) var source: String {
        didSet { onSourceCommitted?(source) }
    }
    public private(set) var revision: UInt64 = 0
    private let parser = LosslessMarkdownParser()
    private let builder = MarkdownProjectionBuilder()
    private(set) var document: LosslessMarkdownParser.Document
    /// (块, 投影, 该投影 display 在全文 display 中的起点)。
    struct RenderedBlock {
        let block: LosslessMarkdownParser.Block
        let projection: MarkdownProjectionBuilder.Projection
        let displayStart: Int
    }
    var rendered: [RenderedBlock] = []
    private var cachedDisplay = ""
    private(set) var history = MarkdownEditorHistory()

    private var composingGuard = false  // 重建刷新 textStorage 的重入保护
    /// T06：marked 期间的临时 textStorage 变化不是持久化 transaction——
    /// source 实时跟随 display（保证预览/映射新鲜），但不登记历史。提交
    /// （unmarkText 紧随的 textDidChange）把整段 marked 内容一次成组记入
    /// history；取消则 source 已在 marked 期间逐步跟随，unmark 时无 diff，
    /// 自然不产生历史。
    private var markedSourceBefore: String?
    private var markedSelectionBefore: MarkdownSelection?
    /// unmarkText 紧随的 textDidChange 是 composition 提交。一次性：
    /// textDidChange 消费后清零。
    private var justUnmarked = false
    /// 最近一次 display→source 同步被拒的原因（nil = 无拒绝）。
    /// 测试/诊断观察口：拒绝本身合法（映射歧义），静默接受 display 才是 bug。
    private(set) var lastSyncRejection: EditRejection?
    /// T12：最近一次触发的输入规则（空段前缀完成）。nil = 未触发。
    /// 测试/诊断观察口——转换本身不改 source（parser 接管），此口用于
    /// 验证组合输入/粘贴/保护块内不触发（NE-13/NE-10）。
    private(set) var lastInputRuleTriggered: InputRuleMatch?
    /// T12：粘贴/拖放期间置位（readSelectionFromPasteboard 覆盖点），
    /// 输入规则不评估——粘贴不是 typing（NE-21）。
    private var isPastingFlag = false
    private var pendingDisplayEdit: (range: NSRange, replacement: String)?
    private var attachmentOwnerURL: URL?
    private var attachmentOwnerIsValid: (() -> Bool)?
    private var attachmentAnchors: [UUID: NSRange] = [:]
    private var completedAttachmentRequests: Set<UUID> = []
    var onAttachmentFinished: ((Result<URL, Error>) -> Void)?
    private(set) var lastAttachmentError: Error?

    // MARK: 渲染块显示(PRD ND-02/03:Typora 式图/码切换)
    // 方法体在 RichMarkdownTextView+RenderedBlocks.swift;状态在此
    // (stored property 不能进 extension)。
    /// 渲染图缓存:key = block source 指纹(kind+source)。内容变即
    /// 换 key,天然触发重渲染。
    var renderedImages: [String: NSImage] = [:]
    /// 展开态(显示源码+图)的块序位集合;未收录 = collapsed(只显示图)。
    /// 刻意按块序位而非内容指纹:单块内容编辑不改变序位,编辑链路的
    /// 展开意图自动延续(图刷新不把正在编辑的源码收走);内容指纹在
    /// 每次击键后都换新,按指纹记录会让编辑中的块瞬间收起。
    var expandedRenderedBlocks: Set<Int> = []
    /// 渲染请求进行中的块指纹(防重复请求)。
    var inFlightRenderBlocks: Set<String> = []
    /// 渲染图供体:nil(默认)走 MarkdownBlockRenderHost 离屏渲染;
    /// 测试注入确定性假图驱动挂载/切换链路,不起 WKWebView。必须在
    /// init 传入:首次投影即会发起渲染请求,后置赋值拦不住首帧。
    var renderedImageProvider: (@MainActor (MarkdownBlockRenderRequest) async -> NSImage?)?

    /// `renderedImageProvider` 是 internal 类型,init 保持 internal;
    /// 生产调用方(同 target)用默认 nil,测试经 @testable 注入。
    init(
        source: String,
        renderedImageProvider: (@MainActor (MarkdownBlockRenderRequest) async -> NSImage?)? = nil
    ) {
        self.source = source
        self.renderedImageProvider = renderedImageProvider
        // document 由 rebuildProjection() 填充；init 只设占位值满足 Swift
        // 全初始化要求，避免 init + rebuildProjection 双重 parse。
        self.document = LosslessMarkdownParser.Document(source: source, blocks: [], lineStartUTF16: [])

        let storage = NSTextStorage()
        let container = NSTextContainer(containerSize: NSSize(width: 100_000, height: 10_000_000))
        container.widthTracksTextView = false
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        super.init(frame: .zero, textContainer: container)
        delegate = self
        allowsUndo = false  // 历史由 MarkdownEditorHistory 拥有（单一语义历史）
        isRichText = false
        usesFontPanel = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        // T19(SPEC §8.3):code/math/URL 不得被 spell 改写;rich 面
        // 整体关 continuous spell(N1 保守,按 range 精确分流留 N2)。
        isContinuousSpellCheckingEnabled = false
        registerForDraggedTypes(readablePasteboardTypes)
        rebuildProjection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - source 装载

    public func setSource(_ newSource: String) {
        invalidateAttachmentRequests()
        pendingDisplayEdit = nil
        source = newSource
        revision += 1
        document = parser.parse(source)
        history = MarkdownEditorHistory()
        rebuildProjection()
    }

    public var displayText: String { cachedDisplay }

    // MARK: - 投影重建

    func rebuildProjection() {
        guard !hasMarkedText() else { return }
        document = parser.parse(source)
        var pieces: [String] = []
        pieces.reserveCapacity(document.blocks.count)
        var renderedNew: [RenderedBlock] = []
        renderedNew.reserveCapacity(document.blocks.count)
        var cursor = 0
        for (blockIndex, block) in document.blocks.enumerated() {
            // 渲染块(mermaid)按展开态投影:
            // - 有渲染图:collapsed 只显示图;expanded 显示源码+图(Typora 式)
            // - 缺图(加载中/渲染失败):保持 expanded 投影——源码段可见
            //   可编辑(INV-4 无效图表合同),U+FFFC 附件段保留:挂载靠
            //   它发起渲染请求,滤掉即首图死锁。无图时 U+FFFC 无字形,
            //   视觉近不可见,点击仍可切换显示态。
            // 展开态按块序位记录:编辑改变指纹但序位不变,展开意图延续。
            let blockFingerprint = Self.renderedBlockFingerprint(block: block, document: document)
            let isRenderable = blockFingerprint != nil
            let hasImage = isRenderable && renderedImages[blockFingerprint!] != nil
            let wantsExpanded =
                (isRenderable && !hasImage)
                || (isRenderable && expandedRenderedBlocks.contains(blockIndex))
            let mode: MarkdownProjectionBuilder.RenderedBlockMode =
                wantsExpanded ? .expanded : .collapsed
            let projection = builder.buildProjection(for: block, in: document, renderedMode: mode)
            renderedNew.append(RenderedBlock(block: block, projection: projection, displayStart: cursor))
            pieces.append(projection.display)
            cursor += projection.display.utf16.count
            // 块显示之间保证一个换行（投影 display 通常已含行尾；空缺时补）
            if let last = pieces.last, last.utf16.last != 10, block != document.blocks.last {
                pieces.append("\n")
                cursor += 1
            }
        }
        rendered = renderedNew
        let newDisplay = pieces.joined()
        cachedDisplay = newDisplay

        guard let storage = textStorage else { return }
        // G0 修复：display 未变时跳过 textStorage 替换（保持 selection + 避免闪烁）
        if storage.string == newDisplay {
            // T19 属性残留修复:display 不变时(如 **wrap/unwrap** 两次)
            // 字体/颜色/段落属性不会被 replaceCharacters 重置,旧 bold/标题
            // 字号会留在同字节文本上——先铺一遍基准属性再上排版。
            let full = NSRange(location: 0, length: storage.length)
            if full.length > 0 {
                storage.addAttribute(.font, value: bodyFont, range: full)
                storage.addAttribute(.foregroundColor, value: contentTextColor, range: full)
                storage.addAttribute(
                    .paragraphStyle, value: makeBaseParagraphStyle(), range: full)
            }
            applyDisplayAttributes()
            return
        }
        composingGuard = true
        storage.beginEditing()
        // G0 性能：先设无属性的纯文本，再统一加字体（避免 NSAttributedString
        // 的属性 run 合并开销；无属性版本创建成本远低于带属性版本）
        storage.replaceCharacters(
            in: NSRange(location: 0, length: storage.length),
            with: NSAttributedString(string: newDisplay)
        )
        let displayLength = (newDisplay as NSString).length
        storage.addAttribute(.font, value: bodyFont, range: NSRange(location: 0, length: displayLength))
        storage.addAttribute(
            .paragraphStyle, value: makeBaseParagraphStyle(),
            range: NSRange(location: 0, length: displayLength))
        applyDisplayAttributes()
        storage.endEditing()
        composingGuard = false
    }

    /// T19 预览对齐:super 画完正文后自绘列表圆点/序号(仅装饰层,
    /// 不改 storage 与映射;空位由 headIndent 让出)。
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawListMarkers(in: dirtyRect)
    }

    // MARK: - T19 typewriter / focus(NE-32:只改 view state)

    /// typewriter 模式:caret 所在行滚动到视口垂直中心。只动滚动,
    /// 不推进 revision、不入历史、不动 dirty(AC-17)。
    public var isTypewriterMode = false

    /// 滚动目标计算(纯函数,可测):caret 行中心对准视口中心,
    /// clamp 到 [0, contentHeight - viewportHeight];内容不足一屏回 0。
    nonisolated public static func typewriterScrollOffset(
        caretLineCenterY: CGFloat, viewportHeight: CGFloat, contentHeight: CGFloat
    ) -> CGFloat {
        guard viewportHeight > 0, contentHeight > viewportHeight else { return 0 }
        let raw = caretLineCenterY - viewportHeight / 2
        return min(max(raw, 0), contentHeight - viewportHeight)
    }

    /// T19 focus 降噪(NE-32):caret 块之外的块前景降为 40% alpha。
    /// 只动显示属性;不动 revision/历史/dirty。
    public var isFocusDimmingEnabled = false
    private var focusDimmingApplied = false

    /// zoom/mode 切换后保持 caret 在视口中的偏移:scroll = caret 新内容
    /// Y − 旧偏移,clamp ≥0(纯几何,可测)。
    nonisolated public static func anchoredScrollOffset(
        caretContentY: CGFloat, caretOffsetFromViewportTop: CGFloat
    ) -> CGFloat {
        max(0, caretContentY - caretOffsetFromViewportTop)
    }

    /// 按当前 caret 重涂降噪(开关关闭时幂等恢复全彩)。
    /// selection 变化由 textViewDidChangeSelection 钩子触发。
    func updateFocusDimming() {
        guard !hasMarkedText(), let storage = textStorage else { return }
        guard isFocusDimmingEnabled else {
            if focusDimmingApplied {
                focusDimmingApplied = false
                applyDisplayAttributes()
            }
            return
        }
        focusDimmingApplied = true
        let dim = contentTextColor.withAlphaComponent(0.4)
        let full = NSRange(location: 0, length: storage.length)
        if full.length > 0 {
            storage.addAttribute(.foregroundColor, value: dim, range: full)
        }
        applyDisplayAttributes()
    }

    /// caret 行滚动居中(typewriter);非该模式时 no-op。
    func scrollCaretToCenterIfNeeded() {
        guard isTypewriterMode, let scrollView = enclosingScrollView else { return }
        let caret = selectedRange()
        guard caret.location <= (string as NSString).length else { return }
        guard let layoutManager, let textContainer else { return }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: caret.location)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return }
        let lineRect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphIndex, effectiveRange: nil)
        let clip = scrollView.contentView.bounds
        let docRect = layoutManager.usedRect(for: textContainer)
        let target = Self.typewriterScrollOffset(
            caretLineCenterY: lineRect.midY,
            viewportHeight: clip.height,
            contentHeight: docRect.height)
        if abs(scrollView.contentView.bounds.origin.y - target) > 0.5 {
            scrollView.contentView.scroll(to: NSPoint(x: clip.minX, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
    /// T10：host 注入的正文/代码字体（NE-32 字体/缩放经设置与 ⌘± 联动）。
    /// 变化后需调用 `refreshFontAttributes()` 重刷属性。
    public var bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    public var codeFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// T10：host 注入的正文前景色（深浅色主题）。
    public var contentTextColor = NSColor.black

    /// T19 视觉排版:标题分级、行内样式(粗/斜/删/链接)、代码底色。
    /// 仅动显示属性;活跃块(或未开降噪)才上彩色装饰,非活跃块平色。
    private var headingFont: NSFont {
        scaledHeadingFont(level: 1)
    }

    func scaledHeadingFont(level: Int) -> NSFont {
        let size = bodyFont.pointSize * Self.previewHeadingScales[min(max(level - 1, 0), 5)]
        return NSFontManager.shared.convert(
            bodyFont, toSize: size) ?? bodyFont.withSize(size)
    }

    func displayRange(of item: RenderedBlock, _ segment: MarkdownProjectionBuilder.Segment) -> NSRange {
        NSRange(
            location: item.displayStart + segment.displayRangeUTF16.location,
            length: segment.displayRangeUTF16.length)
    }

    /// G0 原型的最小样式：保护块等宽字体、code span 等宽（视觉验证用）。
    private func applyDisplayAttributes() {
        guard let storage = textStorage else { return }
        let mono = codeFont
        // T19:caret 所在块(降噪启用时);nil = 不降噪,全部块全彩。
        let caretBlock: LosslessMarkdownParser.Block? = {
            guard isFocusDimmingEnabled else { return nil }
            let caret = sourceCaret()
            return document.blocks.first {
                caret >= $0.rangeUTF16.location && caret <= NSMaxRange($0.rangeUTF16)
            }
        }()
        for item in rendered {
            let block = item.block; let projection = item.projection; let start = item.displayStart
            let isActive = caretBlock == nil || block == caretBlock
            let fg = isActive ? contentTextColor : contentTextColor.withAlphaComponent(0.4)
            if case .codeFence = block.kind {
                let blockLen = projection.display.utf16.count
                let blockRange = NSRange(location: start, length: blockLen)
                storage.addAttribute(.font, value: mono, range: blockRange)
                storage.addAttribute(.foregroundColor, value: fg, range: blockRange)
                storage.addAttribute(.backgroundColor, value: codeBackgroundColor, range: blockRange)
                // T15:token 上色(fence 投影 1:1);超限/未知语言 → 基础样式。
                // T19:降噪块不涂 token(平色),避免活跃色残留。
                let maxLen = NotesTextProcessor.shouldUseSimplifiedHighlighting ? 500 : 3000
                if isActive, blockLen <= maxLen, !NotesTextProcessor.shouldSkipCodeHighlighting,
                    case .codeFence(let info) = block.kind,
                    let tokens = NativeCodeHighlighter.highlight(
                        code: projection.display, language: info.isEmpty ? nil : info)
                {
                    let palette = CodeBlockHighlighter.tokenPalette(
                        isDark: AppEnvironment.current.userData.isDark)
                    for tk in tokens {
                        guard let color = palette[tk.kind],
                            tk.range.location + tk.range.length <= blockLen
                        else { continue }
                        storage.addAttribute(
                            .foregroundColor, value: color,
                            range: NSRange(
                                location: start + tk.range.location, length: tk.range.length))
                    }
                }
                continue
            }
            // 普通块:显式前景(降噪/全彩一致化;行内 code span 只换字体)
            let blockRange = NSRange(location: start, length: projection.display.utf16.count)
            if blockRange.length > 0 {
                storage.addAttribute(.foregroundColor, value: fg, range: blockRange)
            }
            // T19 视觉:块级排版
            switch block.kind {
            case .heading(let level):
                let heading = scaledHeadingFont(level: level)
                let boldHeading = NSFontManager.shared.convert(heading, toHaveTrait: .boldFontMask) ?? heading
                if blockRange.length > 0 {
                    storage.addAttribute(.font, value: boldHeading, range: blockRange)
                    storage.addAttribute(
                        .paragraphStyle, value: makeHeadingParagraphStyle(level: level),
                        range: blockRange)
                }
            case .quote:
                let quoteColor = previewQuoteColour
                if isActive, blockRange.length > 0 {
                    storage.addAttribute(.foregroundColor, value: quoteColor, range: blockRange)
                }
            case .frontmatter, .htmlBlock, .mathBlock, .thematicBreak, .blank:
                let dim = contentTextColor.withAlphaComponent(0.45)
                if isActive, blockRange.length > 0 {
                    storage.addAttribute(.foregroundColor, value: dim, range: blockRange)
                }
            case .listItem:
                break  // marker 缩进在循环后统一应用(见下),避免 O(n²)
            default:
                break
            }
            // T19 视觉:行内排版(code fence 已在上方 continue)
            for segment in projection.segments {
                let range = displayRange(of: item, segment)
                guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
                applyInlineTypography(segment, range: range, isActive: isActive, mono: mono, storage: storage)
            }
        }
        // T19 预览对齐:列表悬挂缩进统一一次应用(所有 list 块)。
        applyListParagraphIndents(storage: storage)
        // 渲染块附件(mermaid 的 NSImage)挂在 U+FFFC 上;图未就绪则
        // 触发异步渲染,完成回调再重建(源码回退由缺图投影承担)。
        // 方法体在 RichMarkdownTextView+RenderedBlocks.swift。
        mountRenderedBlockAttachments(storage: storage)
    }

    /// T19 视觉:单个行内段的排版属性(codeSpan/粗/斜/删/链接)。
    private func applyInlineTypography(
        _ segment: MarkdownProjectionBuilder.Segment,
        range: NSRange,
        isActive: Bool,
        mono: NSFont,
        storage: NSTextStorage
    ) {
        switch segment.kind {
        case .codeSpan:
            storage.addAttribute(.font, value: mono, range: range)
            storage.addAttribute(.backgroundColor, value: codeBackgroundColor, range: range)
        case .strongBody:
            let bold = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask) ?? bodyFont
            storage.addAttribute(.font, value: bold, range: range)
        case .emphasisBody:
            let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask) ?? bodyFont
            storage.addAttribute(.font, value: italic, range: range)
        case .strikethroughBody:
            storage.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue, range: range)
        case .linkLabel:
            if isActive {
                storage.addAttribute(.foregroundColor, value: previewLinkColour, range: range)
                storage.addAttribute(
                    .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        default:
            break
        }
    }

    /// 代码底色(预览对齐:index.html --code-bg 的精确十六进制)。
    private var codeBackgroundColor: NSColor {
        previewCodeBackground
    }

    public func refreshFontAttributes() {
        guard !hasMarkedText() else { return }
        guard let storage = textStorage else { return }
        // T19:zoom/mode 切换保持 caret 视觉锚(NE-32)。
        let anchor = caretScrollAnchor()
        let full = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.font, value: bodyFont, range: full)
        storage.addAttribute(.foregroundColor, value: contentTextColor, range: full)
        applyDisplayAttributes()
        restoreCaretScrollAnchor(anchor)
    }

    /// caret 在视口中的位置快照(内容 Y + 距视口顶偏移)。
    private func caretScrollAnchor() -> (y: CGFloat, offset: CGFloat)? {
        guard let scrollView = enclosingScrollView, let layoutManager else { return nil }
        let caret = selectedRange()
        guard caret.location <= (string as NSString).length else { return nil }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: caret.location)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        layoutManager.ensureLayout(for: textContainer ?? NSTextContainer())
        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        return (lineRect.midY, lineRect.midY - scrollView.contentView.bounds.origin.y)
    }

    /// 字体变化后把 caret 顶回原视口偏移(内容不足时 clamp 到 0)。
    private func restoreCaretScrollAnchor(_ anchor: (y: CGFloat, offset: CGFloat)?) {
        guard let anchor, let scrollView = enclosingScrollView,
            let layoutManager
        else { return }
        let caret = selectedRange()
        guard caret.location <= (string as NSString).length else { return }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: caret.location)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return }
        if let container = textContainer { layoutManager.ensureLayout(for: container) }
        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let target = Self.anchoredScrollOffset(
            caretContentY: lineRect.midY, caretOffsetFromViewportTop: anchor.offset)
        scrollView.contentView.scroll(
            to: NSPoint(x: scrollView.contentView.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - display → source 同步（textDidChange 驱动）

    public func textDidChange(_ notification: Notification) {
        guard !composingGuard else { return }
        let newDisplay = string
        guard newDisplay != cachedDisplay else { return }

        // T06：marked 期间的临时变化只同步 source，不登记历史（SPEC §5.3：
        // 临时 textStorage 变化不是多个持久化 transaction）。source 跟随
        // 保证预览/映射新鲜；历史由提交时一次成组。
        // 判断条件：hasMarkedText() 当前为 true（marked 期间的增量），或
        // justUnmarked == true（insertText 已标记这是 composition 提交），或
        // markedSourceBefore != nil（marked 会话中，包括取消路径的
        // setMarkedText("")——那时 hasMarkedText() 已 false 但基线还在）。
        if hasMarkedText() || justUnmarked || markedSourceBefore != nil {
            syncSourceFromDisplayWithoutHistory(newDisplay: newDisplay)
            cachedDisplay = newDisplay
            if justUnmarked {
                finishCompositionHistory()
                rebuildProjection()
            }
            return
        }

        let diff = displayEditDiff(newDisplay: newDisplay)
        let prefix = diff.prefix
        let replacement = diff.replacement
        let oldText = diff.oldText

        // 定位编辑窗所属块并映射为 source patch；编辑窗跨块（oldText 含
        // 块间换行）或单块映射失配时，先验证完整映射再做一次跨块替换事务
        // （SPEC §4.3「跨块选区替换：验证完整映射后一次事务」）；不可安全
        // 映射时不静默吞掉——source 是权威，cachedDisplay 不得领先 source。
        var applied = false
        let editDisplayStart = prefix
        for item in rendered
        where editDisplayStart >= item.displayStart
            && editDisplayStart <= item.displayStart + item.projection.display.utf16.count
        {
            if let patch = singleBlockPatch(
                item, displayRange: NSRange(location: editDisplayStart, length: oldText.utf16.count), replacement: replacement),
                case .success(let newSource) = MarkdownPatchApplier.applyPatches([patch], to: source)
            {
                // T06：composition 提交已在上方 marked/justUnmarked 分支
                // 处理（一次成组 + 清基线）。这里只剩普通 typing。
                // T12：selectionBefore 统一 source 坐标——编辑前 caret 即
                // 插入点，undo 恢复时经投影映射回 display。
                history.record(
                    MarkdownEditorHistory.RecordInput(
                        patches: [patch], sourceBefore: source,
                        selectionBefore: MarkdownSelection(
                            anchorUTF16: patch.rangeUTF16.location,
                            focusUTF16: patch.rangeUTF16.location,
                            affinity: .downstream
                        ),
                        selectionAfter: MarkdownSelection(
                            anchorUTF16: patch.rangeUTF16.location + patch.replacement.utf16.count,
                            focusUTF16: patch.rangeUTF16.location + patch.replacement.utf16.count,
                            affinity: .downstream
                        ),
                        origin: .typing,
                        name: "typing"
                    ))
                publishSource(newSource, patches: [patch])
                revision += 1
                applied = true
                // T12 输入规则（§4.3 空段前缀）：单空格纯插入完成段首结构
                // 前缀时重组 undo 单元（一键 undo 回字面）。组合输入已在上
                // 方 marked 分支 return；粘贴经 isPastingFlag 排除；保护块
                // （code/math/table/html/frontmatter）由 protectedRanges 排除。
                if patch.rangeUTF16.length == 0 && replacement == " " && !isPastingFlag {
                    evaluateInputRule(insertedOffset: patch.rangeUTF16.location)
                }
            }
            break
        }

        let crossCellTableEdit: Bool = {
            guard !oldText.isEmpty else { return false }
            return rendered.contains { item in
                guard case .table = item.block.kind else { return false }
                let editStart = prefix
                return editStart >= item.displayStart
                    && editStart <= item.displayStart + item.projection.display.utf16.count
            }
        }()
        if !applied, !oldText.isEmpty, !crossCellTableEdit,
            let span = sourceRangeSpanningBlocks(
                forDisplayRange: NSRange(location: prefix, length: oldText.utf16.count))
        {
            // 跨块替换：expectedText 是 source 侧实际字节（display 的
            // oldText 与 source 区间文本因 marker 隐藏而不同）。
            let spanText = (source as NSString).substring(with: span)
            let patch = SourcePatch(rangeUTF16: span, expectedText: spanText, replacement: replacement)
            if case .success(let newSource) = MarkdownPatchApplier.applyPatches([patch], to: source) {
                history.record(
                    MarkdownEditorHistory.RecordInput(
                        patches: [patch], sourceBefore: source,
                        selectionBefore: MarkdownSelection(
                            anchorUTF16: span.location, focusUTF16: span.location, affinity: .downstream
                        ),
                        selectionAfter: MarkdownSelection(
                            anchorUTF16: span.location + replacement.utf16.count,
                            focusUTF16: span.location + replacement.utf16.count,
                            affinity: .downstream
                        ),
                        origin: .typing,
                        name: "typing-replace"
                    ))
                publishSource(newSource, patches: [patch])
                revision += 1
                applied = true
            }
        }

        if !applied {
            // 观察口（测试/诊断）：单块与跨块映射均失败时拒绝写 source；
            // 随后统一走回退分支把显示拉回 source。
            lastSyncRejection = .expectedTextMismatch
        }

        // composition 期间不重建（保持 markedTextRange）；否则以 source 为准
        // 立即重建投影——成功时简单编辑的 display == string，textStorage 替换
        // 被跳过（无闪烁、无 selection 重置）；失败时显示被显式回退。每次编辑
        // 后立即收敛坐标：延迟到下一次编辑再收敛会让 rendered 的 displayStart/
        // 块长过期，块尾连续输入自第 3 字符起定位错。
        // T12：caret 恢复走 source 坐标经投影映射——输入规则触发结构转换
        // （如 "-" → 列表 marker 隐藏）时 display 长度变化，旧 display 偏移
        // 直接 clamp 会把 caret 甩到块末，下一次输入落错行。
        if !hasMarkedText() {
            let restore = selectedRange()
            rebuildProjection()
            if applied,
                let lastPatch = history.undoStack.last?.patches.last
            {
                let sourceCaretAfter = lastPatch.rangeUTF16.location + lastPatch.replacement.utf16.count
                let display =
                    displayOffset(forSourceOffset: sourceCaretAfter)
                    ?? min(restore.location, max(0, (string as NSString).length - restore.length))
                setSelectedRange(NSRange(location: min(display, (string as NSString).length), length: 0))
            } else {
                let clamped = min(restore.location, max(0, (string as NSString).length - restore.length))
                setSelectedRange(NSRange(location: clamped, length: restore.length))
            }
        } else {
            cachedDisplay = newDisplay
        }
    }

    /// NSString 快速 diff 结果：公共前缀/后缀长度与新旧编辑窗文本。
    /// 避免 Array(String.utf16) 的 O(n) 拷贝（G0 性能修复）。
    private struct DiffResult {
        let prefix: Int
        let replacement: String
        let oldText: String
    }

    private func singleBlockPatch(_ item: RenderedBlock, displayRange: NSRange, replacement: String) -> SourcePatch? {
        let local = NSRange(location: displayRange.location - item.displayStart, length: displayRange.length)
        guard local.location >= 0, NSMaxRange(local) <= item.projection.display.utf16.count else { return nil }
        for segment in item.projection.segments {
            let range = segment.displayRangeUTF16
            if range.length == 0, range.location > local.location, range.location < NSMaxRange(local) { return nil }
            if segment.kind == .attachmentPlaceholder, local.length > 0, NSIntersectionRange(range, local).length > 0,
                local.location > range.location || NSMaxRange(local) < NSMaxRange(range)
            {
                return nil
            }
        }
        let start = item.projection.sourceOffset(forDisplay: local.location) ?? item.block.rangeUTF16.location
        let end = local.length == 0 ? start : item.projection.sourceOffset(forDisplay: NSMaxRange(local))
        guard let end, start <= end, start >= item.block.rangeUTF16.location, end <= NSMaxRange(item.block.rangeUTF16) else { return nil }
        let range = NSRange(location: start, length: end - start)
        var effectiveReplacement = replacement
        // T16:table 块按 cell 语义收口(投影 1:1,raw `|` 落 source 会拆表)。
        // cell 内:未转义管道写入为 \|;跨 cell/管道界:拒绝(结构修改只走
        // 模型命令),display 随 rebuild 回退。
        if case .table = item.block.kind {
            let model = MarkdownTableModel.parse(source: source, blockRange: item.block.rangeUTF16)
            let inCell = model.rows.contains { row in
                row.cells.contains { cell in
                    start >= cell.rangeUTF16.location && end <= NSMaxRange(cell.rangeUTF16)
                }
            }
            guard inCell else { return nil }
            effectiveReplacement = Self.escapingUnescapedPipes(replacement)
        }
        return SourcePatch(rangeUTF16: range, expectedText: (source as NSString).substring(with: range), replacement: effectiveReplacement)
    }

    /// 只转义未被转义的管道(反斜杠奇偶判定:`\\|` 双反斜杠后管道仍需转义)。
    static func escapingUnescapedPipes(_ text: String) -> String {
        var out = ""
        var backslashRun = 0
        for ch in text {
            if ch == "\\" {
                backslashRun += 1
                out.append(ch)
                continue
            }
            if ch == "|" {
                if backslashRun % 2 == 0 { out.append("\\") }
                out.append("|")
                backslashRun = 0
                continue
            }
            backslashRun = 0
            out.append(ch)
        }
        return out
    }

    /// T06：marked 期间的 source 同步（不登记历史）。映射逻辑与
    /// textDidChange 主路径相同，只是跳过 history.record——SPEC §5.3
    /// 要求临时变化不产生持久化 transaction。
    private func syncSourceFromDisplayWithoutHistory(newDisplay: String) {
        let diff = displayEditDiff(newDisplay: newDisplay)
        let prefix = diff.prefix
        let replacement = diff.replacement
        let oldText = diff.oldText

        let editDisplayStart = prefix
        for item in rendered
        where editDisplayStart >= item.displayStart
            && editDisplayStart <= item.displayStart + item.projection.display.utf16.count
        {
            let projection = item.projection
            let localDisplay = editDisplayStart - item.displayStart
            let sourceStart = projection.sourceOffset(forDisplay: localDisplay) ?? item.block.rangeUTF16.location

            let patch = SourcePatch(
                rangeUTF16: NSRange(location: sourceStart, length: oldText.utf16.count),
                expectedText: oldText,
                replacement: replacement
            )
            // marked 期间投影保持进入组合时的版本，块长不会随候选增长。
            // 不能拿冻结的块尾验证当前候选范围；实际旧文本由 patch 校验。
            if case .success(let newSource) = MarkdownPatchApplier.applyPatches([patch], to: source) {
                publishSource(newSource, patches: [patch])
                revision += 1
            }
            break
        }
    }

    private func finishCompositionHistory() {
        guard let baseline = markedSourceBefore, let selection = markedSelectionBefore else { return }
        if baseline != source {
            let diff = Self.fastDiff(old: baseline, new: source)
            let caret = diff.prefix + diff.replacement.utf16.count
            history.record(
                MarkdownEditorHistory.RecordInput(
                    patches: [SourcePatch(rangeUTF16: NSRange(location: diff.prefix, length: diff.oldText.utf16.count), expectedText: diff.oldText, replacement: diff.replacement)],
                    sourceBefore: baseline, selectionBefore: selection,
                    selectionAfter: MarkdownSelection(anchorUTF16: caret, focusUTF16: caret, affinity: .downstream),
                    origin: .composition, name: "composition"))
        }
        markedSourceBefore = nil
        markedSelectionBefore = nil
        justUnmarked = false
    }

    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let accepted = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if accepted, !composingGuard, let replacementString {
            pendingDisplayEdit = (affectedCharRange, replacementString)
        }
        return accepted
    }

    private func displayEditDiff(newDisplay: String) -> DiffResult {
        defer { pendingDisplayEdit = nil }
        if let edit = pendingDisplayEdit, edit.range.location >= 0,
            NSMaxRange(edit.range) <= (cachedDisplay as NSString).length,
            (cachedDisplay as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == newDisplay
        {
            return DiffResult(prefix: edit.range.location, replacement: edit.replacement, oldText: (cachedDisplay as NSString).substring(with: edit.range))
        }
        return Self.fastDiff(old: cachedDisplay, new: newDisplay)
    }

    private static func fastDiff(old: String, new: String) -> DiffResult {
        let oldNS = old as NSString
        let newNS = new as NSString
        let minLen = min(oldNS.length, newNS.length)
        var prefix = 0
        while prefix < minLen, oldNS.character(at: prefix) == newNS.character(at: prefix) {
            prefix += 1
        }
        while prefix > 0, !MarkdownSourceMap(source: old).isGraphemeBoundary(prefix) || !MarkdownSourceMap(source: new).isGraphemeBoundary(prefix) {
            prefix -= 1
        }
        var suffix = 0
        while suffix < minLen - prefix,
            oldNS.character(at: oldNS.length - 1 - suffix) == newNS.character(at: newNS.length - 1 - suffix)
        {
            suffix += 1
        }
        while suffix > 0,
            !MarkdownSourceMap(source: old).isGraphemeBoundary(oldNS.length - suffix)
                || !MarkdownSourceMap(source: new).isGraphemeBoundary(newNS.length - suffix)
        {
            suffix -= 1
        }
        let oldStart = prefix
        let oldEnd = oldNS.length - suffix
        let newEnd = newNS.length - suffix
        let oldText = oldStart < oldEnd ? oldNS.substring(with: NSRange(location: oldStart, length: oldEnd - oldStart)) : ""
        let replacement = prefix < newEnd ? newNS.substring(with: NSRange(location: prefix, length: newEnd - prefix)) : ""
        return DiffResult(prefix: prefix, replacement: replacement, oldText: oldText)
    }

    /// 全文 source 偏移 → display 偏移（经所在块投影）。
    /// 投影段的 sourceRange 本就是文档绝对坐标，直接查询；
    /// 先减块起点反而查不到段（非首块全部落空回退到块首）。
    public func displayOffset(forSourceOffset offset: Int) -> Int? {
        rebuildProjection()
        for item in rendered {
            let block = item.block; let projection = item.projection; let displayStart = item.displayStart
            if offset >= block.rangeUTF16.location, offset <= NSMaxRange(block.rangeUTF16) {
                return displayStart + (projection.displayOffset(forSource: offset) ?? 0)
            }
        }
        return nil
    }

    /// G0 诊断口：caret 的 source 偏移与所在结构行（测试观察用）。
    func debugListItemLocalization() -> (sourceCaret: Int, item: Bool) {
        rebuildProjection()
        return (sourceCaret(), currentStructuralLine()?.kind != .none)
    }

    // MARK: - 结构命令（Enter/Tab/Backspace/Delete；T12 MarkdownBlockModel 规划）

    public func text(_: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !hasMarkedText() else { return false }
        rebuildProjection()  // 结构命令需要准确的块定位
        // T16:caret 在 table 块内时,Tab/Shift+Tab/Enter 走表格导航与
        // 结构事务(单 TextKit 投影,不建独立 grid)。
        if let handled = handleTableCommand(commandSelector) {
            return handled
        }
        switch commandSelector {
        case #selector(insertNewline(_:)):
            return handleStructuralEnter()
        case #selector(insertTab(_:)):
            return handleStructuralTab(indent: true)
        case #selector(insertBacktab(_:)):
            return handleStructuralTab(indent: false)
        case #selector(deleteBackward(_:)):
            return handleStructuralBackspace()
        case #selector(deleteForward(_:)):
            return handleStructuralDeleteForward()
        default:
            return false
        }
    }

    /// display caret → source 偏移（经所在块投影映射；块外保守返回原值）。
    func sourceCaret() -> Int {
        let displayCaret = selectedRange().location
        for item in rendered {
            let block = item.block; let projection = item.projection; let displayStart = item.displayStart
            let blockDisplayLen = projection.display.utf16.count
            if displayCaret >= displayStart, displayCaret <= displayStart + blockDisplayLen {
                let local = displayCaret - displayStart
                return projection.sourceOffset(forDisplay: local) ?? block.rangeUTF16.location
            }
        }
        return displayCaret
    }

    /// caret 所在的容器行（list item / quote 内的当前行）结构模型。
    /// 非 list/quote 块或 caret 不在块内返回 nil。
    private func currentStructuralLine() -> MarkdownBlockLine? {
        let caret = sourceCaret()
        let ns = source as NSString
        for block in document.blocks {
            let isContainer: Bool
            switch block.kind {
            case .listItem, .quote: isContainer = true
            default: isContainer = false
            }
            guard isContainer,
                caret >= block.rangeUTF16.location, caret <= NSMaxRange(block.rangeUTF16)
            else { continue }
            let probe = min(max(caret, block.rangeUTF16.location), max(block.rangeUTF16.location, NSMaxRange(block.rangeUTF16) - 1))
            let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
            return MarkdownBlockModel.parseLine(ns, lineRange: lineRange)
        }
        return nil
    }

    /// 应用结构 patch 并登记历史。返回 false 表示 patch 被拒（坐标/期望
    /// 文本失配）——调用方据此返回未处理，交给 AppKit 默认行为，不吞键。
    @discardableResult
    func applyStructurePatches(
        _ patches: [SourcePatch], name: String, restoreSourceCaret: Int? = nil,
        origin: EditOrigin = .structure
    ) -> Bool {
        guard !patches.isEmpty else { return true }
        let selectionBefore = sourceCaret()
        guard case .success(let newSource) = MarkdownPatchApplier.applyPatches(patches, to: source) else {
            return false
        }
        let caretAfter = restoreSourceCaret ?? sourceCaret()
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: patches, sourceBefore: source,
                selectionBefore: MarkdownSelection(
                    anchorUTF16: selectionBefore,
                    focusUTF16: selectionBefore, affinity: .downstream
                ),
                selectionAfter: MarkdownSelection(
                    anchorUTF16: caretAfter, focusUTF16: caretAfter, affinity: .downstream
                ),
                origin: origin,
                name: name
            ))
        publishSource(newSource, patches: patches)
        revision += 1
        rebuildProjection()
        if let caret = restoreSourceCaret {
            // 新空行在 display 上零长度（marker 全隐藏）：caret 自身可能
            // 无 display 映射，回退试下一 unit（行尾换行），再不行 clamp
            // 到 display 末尾（拆分尾空行的落点）。
            let sourceLen = (source as NSString).length
            let display =
                displayOffset(forSourceOffset: caret)
                ?? displayOffset(forSourceOffset: min(caret + 1, sourceLen))
                ?? (string as NSString).length
            setSelectedRange(NSRange(location: min(display, (string as NSString).length), length: 0))
        }
        return true
    }

    private func handleStructuralEnter() -> Bool {
        guard let line = currentStructuralLine(),
            let plan = MarkdownBlockModel.planEnter(line: line, source: source as NSString, caret: sourceCaret())
        else { return false }
        return applyStructurePatches(plan.patches, name: plan.name, restoreSourceCaret: plan.caretAfterUTF16)
    }

    private func handleStructuralTab(indent: Bool) -> Bool {
        guard let line = currentStructuralLine(),
            let plan = MarkdownBlockModel.planTab(line: line, source: source as NSString, caret: sourceCaret(), indent: indent)
        else { return false }
        // 最外层 Shift+Tab：吞掉按键但无操作（不删内容、不插 tab）
        if plan.patches.isEmpty { return true }
        return applyStructurePatches(plan.patches, name: plan.name, restoreSourceCaret: plan.caretAfterUTF16)
    }

    private func handleStructuralBackspace() -> Bool {
        guard let line = currentStructuralLine(),
            let plan = MarkdownBlockModel.planBackspace(line: line, source: source as NSString, caret: sourceCaret())
        else { return false }
        return applyStructurePatches(plan.patches, name: plan.name, restoreSourceCaret: plan.caretAfterUTF16)
    }

    private func handleStructuralDeleteForward() -> Bool {
        guard let line = currentStructuralLine(),
            let plan = MarkdownBlockModel.planDeleteForward(line: line, source: source as NSString, caret: sourceCaret())
        else { return false }
        return applyStructurePatches(plan.patches, name: plan.name, restoreSourceCaret: plan.caretAfterUTF16)
    }

    // MARK: - T16 表格命令(table 块内 Tab/Enter;G0 单投影决定)

    /// caret 所在的 table 块模型;非 table 块返回 nil。
    func tableModelAtCaret() -> MarkdownTableModel? {
        let caret = sourceCaret()
        for item in rendered {
            guard case .table = item.block.kind,
                caret >= item.block.rangeUTF16.location,
                caret <= NSMaxRange(item.block.rangeUTF16)
            else { continue }
            return MarkdownTableModel.parse(source: source, blockRange: item.block.rangeUTF16)
        }
        return nil
    }

    /// caret 的 (行, 列);不在任何 cell 区间(如管道/分隔行)返回 nil。
    func tablePosition(
        _ model: MarkdownTableModel, caret: Int
    ) -> (row: Int, column: Int)? {
        for (r, row) in model.rows.enumerated() where !row.isDelimiter {
            for (c, cell) in row.cells.enumerated()
            where caret >= cell.rangeUTF16.location && caret <= NSMaxRange(cell.rangeUTF16) {
                return (r, c)
            }
        }
        return nil
    }

    /// 把 source 偏移按 table 块 1:1 投影设为 caret。
    private func setTableCaret(_ sourceOffset: Int) {
        if let display = displayOffset(forSourceOffset: sourceOffset) {
            setSelectedRange(NSRange(location: display, length: 0))
        }
    }

    /// 表格命令;返回 nil = 不在表格内(回落既有结构处理)。
    private func handleTableCommand(_ selector: Selector) -> Bool? {
        guard let model = tableModelAtCaret() else { return nil }
        let caret = sourceCaret()
        guard let pos = tablePosition(model, caret: caret) else { return true }
        let editableRows = model.rows.indices.filter { !model.rows[$0].isDelimiter }

        switch selector {
        case #selector(insertTab(_:)):
            let next = nextCell(pos, rows: editableRows, model: model, forward: true)
            if let next { setTableCaret(cellStart(model, next)) }
            return true
        case #selector(insertBacktab(_:)):
            let prev = nextCell(pos, rows: editableRows, model: model, forward: false)
            if let prev { setTableCaret(cellStart(model, prev)) }
            return true
        case #selector(insertNewline(_:)):
            // 末行:Enter = 追加行(一次结构事务,可撤销)
            if pos.row == editableRows.last {
                guard let plan = model.appendRow(columnCount: model.columnCount) else {
                    return true
                }
                applyStructurePatches(
                    plan.patches, name: "table-add-row",
                    restoreSourceCaret: plan.caretAfterUTF16, origin: .structure)
                return true
            }
            // 非末行:跳到正下方同列(列不存在则行首格)
            let below = editableRows.first { $0 > pos.row } ?? pos.row
            var target = pos
            if below != pos.row {
                target = (below, min(pos.column, model.rows[below].cells.count - 1))
            }
            setTableCaret(cellStart(model, target))
            return true
        default:
            return nil  // 其他命令交给既有处理(如 Backspace)
        }
    }

    /// 前一格/后一格(只在可编辑行内)。
    private func nextCell(
        _ pos: (row: Int, column: Int),
        rows editableRows: [Int],
        model: MarkdownTableModel,
        forward: Bool
    ) -> (row: Int, column: Int)? {
        var r = pos.row
        var c = pos.column + (forward ? 1 : -1)
        while editableRows.contains(r) {
            let count = model.rows[r].cells.count
            if c >= 0, c < count { return (r, c) }
            // 反向取「小于当前行的最后一行」(紧邻上一行):editableRows
            // 升序,first(< r) 会跳过头行以外的中间数据行。
            let adjacent: Int?
            if forward {
                adjacent = editableRows.first(where: { $0 > r })
            } else {
                adjacent = editableRows.last(where: { $0 < r })
            }
            if let nr = adjacent {
                r = nr
                c = forward ? 0 : model.rows[r].cells.count - 1
            } else {
                return nil  // 首/末格:原地
            }
        }
        return nil
    }

    private func cellStart(_ model: MarkdownTableModel, _ pos: (row: Int, column: Int)) -> Int {
        guard model.rows.indices.contains(pos.row),
            model.rows[pos.row].cells.indices.contains(pos.column)
        else { return sourceCaret() }
        return model.rows[pos.row].cells[pos.column].rangeUTF16.location
    }

    /// task 勾选翻转：精确替换括号内单字符（NE-07 精确 span toggle）。
    /// preview checkbox intent（T14）复用同语义的 span 入口。
    @discardableResult
    public func toggleTaskAtSelection() -> Bool {
        rebuildProjection()
        guard let line = currentStructuralLine(),
            let patch = MarkdownBlockModel.planTaskToggle(line: line)
        else { return false }
        // 勾选字符等长替换：display 不变，selection 原地保持
        applyStructurePatches([patch], name: "task-toggle", restoreSourceCaret: sourceCaret())
        return true
    }

    // MARK: - T15 块级命令(语言更换 / ⌘Enter 退出块;source 事务)

    /// ⌘Return 在代码块内 = 退出块(T15);块外交还默认行为。
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 /* Return */ {
            rebuildProjection()
            if codeFenceBlockAtCaret() != nil {
                return exitCodeBlockAtCaret()
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// caret 所在的 codeFence 块;不在 fence 内返回 nil。
    private func codeFenceBlockAtCaret() -> LosslessMarkdownParser.Block? {
        let caret = sourceCaret()
        for block in document.blocks {
            guard case .codeFence = block.kind,
                caret >= block.rangeUTF16.location,
                caret <= NSMaxRange(block.rangeUTF16)
            else { continue }
            return block
        }
        return nil
    }

    /// 语言更换(界定符面板命令的 source 事务入口):只替换开围栏后的
    /// info 串,内容与围栏定界符不动。fence 外返回 false。
    @discardableResult
    public func setCodeFenceLanguage(_ language: String) -> Bool {
        guard isEditable, !hasMarkedText() else { return false }
        rebuildProjection()
        guard let block = codeFenceBlockAtCaret() else { return false }
        let ns = source as NSString
        let blockStart = block.rangeUTF16.location
        // 开围栏行:定界符 run(```或~~~)+ 可选空格 + info 串
        let lineEnd: Int = {
            var i = blockStart
            while i < NSMaxRange(block.rangeUTF16), ns.character(at: i) != 0x0A, ns.character(at: i) != 0x0D {
                i += 1
            }
            return i
        }()
        let fenceChar = ns.character(at: blockStart)
        guard fenceChar == 0x60 || fenceChar == 0x7E else { return false }  // ` 或 ~
        var run = 0
        while blockStart + run < lineEnd, ns.character(at: blockStart + run) == fenceChar { run += 1 }
        guard run >= 3 else { return false }
        var infoStart = blockStart + run
        while infoStart < lineEnd, ns.character(at: infoStart) == 0x20 { infoStart += 1 }
        let infoRange = NSRange(location: infoStart, length: lineEnd - infoStart)
        let patch = SourcePatch(
            rangeUTF16: infoRange,
            expectedText: ns.substring(with: infoRange),
            replacement: language)
        return applyStructurePatches([patch], name: "code-fence-language", origin: .structure)
    }

    /// ⌘Enter 退出代码块:在块末插空段落并把 caret 放进去(封闭与未封闭
    /// 围栏同语义)。fence 外返回 false。
    @discardableResult
    public func exitCodeBlockAtCaret() -> Bool {
        guard isEditable, !hasMarkedText() else { return false }
        rebuildProjection()
        guard let block = codeFenceBlockAtCaret() else { return false }
        let ns = source as NSString
        let atEOF = NSMaxRange(block.rangeUTF16) >= ns.length
        let insertAt = NSMaxRange(block.rangeUTF16)
        let patch = SourcePatch(
            rangeUTF16: NSRange(location: insertAt, length: 0),
            expectedText: "",
            replacement: atEOF ? "\n\n" : "\n")
        // caret 落在新空行(insertAt + 1;EOF 变体落在最后空行)
        let caret = atEOF ? insertAt + 2 : insertAt + 1
        return applyStructurePatches(
            [patch], name: "exit-code-block", restoreSourceCaret: caret, origin: .structure)
    }

    // MARK: - T11 行内格式命令与链接（source patch，AC-01/NE-05/NE-06/NE-12）

    /// T11：modifier+click 开链接与普通 click 编辑 caret 的区分入口。
    /// target 交给 host 解析（相对路径需 note 上下文）；未注册回调或
    /// 点击处无 link 时走默认 caret 行为。
    public var onOpenLink: ((InlineLinkSpan) -> Void)?

    /// 行内格式 toggle：选中区间 wrap/unwrap delimiter（空选中取光标处
    /// 连续非空白词）。patch 原子应用，未选中范围不动；origin .format。
    @discardableResult
    public func applyInlineFormat(_ kind: MarkdownInlineFormat) -> Bool {
        guard isEditable, !hasMarkedText(), !selectionIsProtectedBlock else { return false }
        rebuildProjection()
        let sel = selectedRange()
        let ns = string as NSString
        let displayRange: NSRange
        if sel.length == 0 {
            displayRange = Self.wordRange(at: sel.location, in: ns)
            guard displayRange.length > 0 else { return false }
        } else {
            displayRange = sel
        }
        guard let sourceRange = sourceRange(forDisplayRange: displayRange) else {
            return false  // 跨块/映射歧义：不猜，显式拒绝
        }
        let sourceNS = source as NSString
        guard NSMaxRange(sourceRange) <= sourceNS.length else { return false }
        let unwrap = InlineFormatPlanner.shouldUnwrap(kind, source: sourceNS, selected: sourceRange)
        // code wrap：紧邻 backtick 时插入会制造歧义 run（``x`` → ```x```），
        // 显式拒绝而不是破坏既有 span。
        if kind == .code && !unwrap {
            if sourceRange.location >= 1,
                sourceNS.character(at: sourceRange.location - 1) == ascii16("`")
            {
                return false
            }
            if NSMaxRange(sourceRange) < sourceNS.length,
                sourceNS.character(at: NSMaxRange(sourceRange)) == ascii16("`")
            {
                return false
            }
        }
        let planned = InlineFormatPlanner.patches(kind, selected: sourceRange, source: sourceNS, unwrap: unwrap)

        guard case .success(let newSource) = MarkdownPatchApplier.applyPatches(planned.patches, to: source) else {
            return false
        }
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: planned.patches, sourceBefore: source,
                selectionBefore: MarkdownSelection(
                    anchorUTF16: sourceRange.location,
                    focusUTF16: NSMaxRange(sourceRange), affinity: .downstream
                ),
                selectionAfter: MarkdownSelection(
                    anchorUTF16: planned.selectionAfter.location,
                    focusUTF16: NSMaxRange(planned.selectionAfter), affinity: .downstream
                ),
                origin: .format, name: "format-\(kind.rawValue)"
            ))
        publishSource(newSource, patches: planned.patches)
        revision += 1
        rebuildProjection()
        // selectionAfter 是 source 坐标，映射回 display（unwrap 后区间已在界内）
        let anchor =
            displayOffset(forSourceOffset: planned.selectionAfter.location)
            ?? planned.selectionAfter.location
        let focus =
            displayOffset(forSourceOffset: NSMaxRange(planned.selectionAfter))
            ?? NSMaxRange(planned.selectionAfter)
        setSelectedRange(NSRange(location: min(anchor, focus), length: abs(focus - anchor)))
        return true
    }

    /// 光标处连续非空白 run（CJK 连续文字自然成词），供空选中的格式 toggle。
    private static func wordRange(at location: Int, in ns: NSString) -> NSRange {
        guard location <= ns.length else { return NSRange(location: 0, length: 0) }
        func isWord(_ c: unichar) -> Bool {
            c != ascii16(" ") && c != ascii16("\t") && c != 0x0A && c != 0x0D
        }
        var start = min(location, ns.length)
        while start > 0, isWord(ns.character(at: start - 1)) {
            start -= 1
        }
        var end = min(location, ns.length)
        while end < ns.length, isWord(ns.character(at: end)) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// display 选中区间 → source 区间（须落在单块内；跨块/边界歧义 nil）。
    func sourceRange(forDisplayRange range: NSRange) -> NSRange? {
        for item in rendered {
            let blockDisplay = item.projection.display.utf16.count
            guard range.location >= item.displayStart,
                NSMaxRange(range) <= item.displayStart + blockDisplay
            else { continue }
            let start = item.projection.sourceOffset(forDisplay: range.location - item.displayStart)
            let end = item.projection.sourceOffset(forDisplay: NSMaxRange(range) - item.displayStart)
            if let s = start, let e = end {
                return NSRange(location: min(s, e), length: abs(e - s))
            }
            return nil
        }
        return nil
    }

    /// display 区间 → 跨块 source 区间（跨块替换用）。两端点须落在不同
    /// 投影块——单块选区含隐藏 inline marker（如闭 backtick 前）不走 span
    /// 路径，安全拒绝。端点在块间缝上时：起点归前块末尾（含其尾换行），
    /// 终点吸收下一块的隐藏 marker——跨块替换按 Typora 语义消解结构，
    /// 不得把不可见 marker 泄漏成可见字面。任一端点无映射返回 nil。
    private func sourceRangeSpanningBlocks(forDisplayRange range: NSRange) -> NSRange? {
        guard range.length > 0,
            let start = spanningSourceEdge(range.location, atStart: true),
            let end = spanningSourceEdge(NSMaxRange(range), atStart: false),
            start.itemIndex != end.itemIndex,
            end.value >= start.value
        else { return nil }
        return NSRange(location: start.value, length: end.value - start.value)
    }

    private func spanningSourceEdge(_ offset: Int, atStart: Bool) -> (itemIndex: Int, value: Int)? {
        for (index, item) in rendered.enumerated() {
            let blockLen = item.projection.display.utf16.count
            guard offset >= item.displayStart, offset <= item.displayStart + blockLen else { continue }
            let local = offset - item.displayStart
            if atStart, local == 0 {
                // 块首（含首块 display 0）：取块 source 起点，marker 落入
                // 替换区间——跨块选择替换按 Typora 语义消解结构
                return (index, item.block.rangeUTF16.location)
            }
            if !atStart, local == blockLen, index + 1 < rendered.count,
                rendered[index + 1].displayStart == offset
            {
                // 终点落在块缝：下一块起点的隐藏 marker 一并进入替换区间，
                // 不得泄漏成可见字面
                let next = rendered[index + 1]
                let value =
                    next.projection.sourceOffset(forDisplay: 0)
                    ?? next.block.rangeUTF16.location
                return (index + 1, value)
            }
            if let mapped = item.projection.sourceOffset(forDisplay: local) {
                return (index, mapped)
            }
            // 块内投影缝隙（防御）：clamp 到块 source 端
            return (
                index,
                atStart ? NSMaxRange(item.block.rangeUTF16) : item.block.rangeUTF16.location
            )
        }
        return nil
    }

    // MARK: - T12 输入规则（§4.3 空段前缀；转换由 parser 接管，这里只
    // 重组 undo 单元并留下观察口）

    private func evaluateInputRule(insertedOffset: Int) {
        guard
            let match = MarkdownInputRules.matchPrefixInsertion(
                source: source, insertedOffset: insertedOffset,
                protectedRanges: protectedBlockRanges()
            )
        else { return }
        lastInputRuleTriggered = match
        // 一键 undo 回完整字面前缀：把构成前缀的连续纯插入 typing 合并
        // 为单条（跨时间窗的显式重组；链不完整则保持既有粒度，不吞字）。
        _ = history.collapseTypingPrefix(
            prefixRange: match.prefixRangeUTF16,
            selectionAfter: MarkdownSelection(
                anchorUTF16: NSMaxRange(match.prefixRangeUTF16),
                focusUTF16: NSMaxRange(match.prefixRangeUTF16),
                affinity: .downstream
            ),
            name: "input-rule-\(match.kind.rawValue)"
        )
    }

    /// 保护块 range（输入规则不触发的区域：code/indented code/html/
    /// table/frontmatter——NE-10 按 literal 处理）。
    private func protectedBlockRanges() -> [NSRange] {
        document.blocks.compactMap { block in
            switch block.kind {
            case .codeFence, .codeIndented, .htmlBlock, .mathBlock, .table, .frontmatter:
                return block.rangeUTF16
            default:
                return nil
            }
        }
    }

    /// 粘贴/拖放统一入口：⌘V 与 drop 都经读板路径，在这里置位排除输入
    /// 规则（NE-21 粘贴不触发 typing rule）。
    public override func paste(_ sender: Any?) {
        _ = readSelection(from: .general)
    }

    public override func readSelection(from pboard: NSPasteboard) -> Bool {
        guard isEditable, !hasMarkedText() else { return false }
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            guard urls.count == 1, let url = urls.first else { return false }
            return importAttachment(.file(url)) != nil
        }
        if let bytes = pboard.data(forType: .png) ?? pboard.data(forType: .tiff) {
            return importAttachment(.image(bytes)) != nil
        }
        return paste(from: pboard, mode: .automatic)
    }

    public override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        readSelection(from: pboard)
    }

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [MarkdownClipboardAdapter.markdownType, .fileURL, .png, .tiff, .html, .string]
    }

    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string, MarkdownClipboardAdapter.markdownType]
    }

    public override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return false }
        if type == .string { return pboard.setString((string as NSString).substring(with: range), forType: type) }
        guard type == MarkdownClipboardAdapter.markdownType, let selected = clipboardSourceRange() else { return false }
        return pboard.setString((source as NSString).substring(with: selected), forType: type)
    }

    @objc func copyVisibleText(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        NSPasteboard.general.clearContents()
        _ = writeSelection(to: .general, type: .string)
    }

    @objc func copyMarkdown(_ sender: Any?) {
        guard let range = clipboardSourceRange() else { return }
        NSPasteboard.general.clearContents()
        let markdown = (source as NSString).substring(with: range)
        NSPasteboard.general.setString(markdown, forType: .string)
        NSPasteboard.general.setString(markdown, forType: MarkdownClipboardAdapter.markdownType)
    }

    @objc func pasteMarkdown(_ sender: Any?) {
        _ = paste(from: .general, mode: .markdown)
    }

    public override func pasteAsPlainText(_ sender: Any?) {
        _ = paste(from: .general, mode: .plain)
    }

    @discardableResult
    func paste(from board: NSPasteboard, mode: MarkdownClipboardAdapter.PasteMode) -> Bool {
        guard isEditable, !hasMarkedText() else { return false }
        rebuildProjection()
        guard let range = editingSourceRange(),
            let text = MarkdownClipboardAdapter.text(from: board, mode: mode, literal: selectionIsLiteral)
        else { return false }
        isPastingFlag = true
        defer { isPastingFlag = false }
        return replaceSource(range, with: text, origin: .paste, name: "paste")
    }

    private var selectionIsLiteral: Bool {
        if selectionIsProtectedBlock { return true }
        let caret = sourceCaret()
        for item in rendered {
            for segment in item.projection.segments where segment.kind == .codeSpan {
                if caret >= segment.sourceRangeUTF16.location && caret <= NSMaxRange(segment.sourceRangeUTF16) { return true }
            }
        }
        return false
    }

    var selectionIsProtectedBlock: Bool {
        let caret = sourceCaret()
        for block in document.blocks where caret >= block.rangeUTF16.location && caret < NSMaxRange(block.rangeUTF16) {
            switch block.kind {
            case .codeFence, .codeIndented, .htmlBlock, .mathBlock, .frontmatter: return true
            default: break
            }
        }
        return false
    }

    private func editingSourceRange() -> NSRange? {
        let range = selectedRange()
        guard range.location != NSNotFound, NSMaxRange(range) <= (string as NSString).length else { return nil }
        if range.location == 0, range.length == (string as NSString).length {
            return NSRange(location: 0, length: source.utf16.count)
        }
        if range.length == 0 { return NSRange(location: sourceCaret(), length: 0) }
        return sourceRangeSpanningBlocks(forDisplayRange: range) ?? sourceRange(forDisplayRange: range)
    }

    private func clipboardSourceRange() -> NSRange? {
        guard selectedRange().length > 0, var range = editingSourceRange() else { return nil }
        let selection = selectedRange()
        for item in rendered {
            for segment in item.projection.segments where segment.displayRangeUTF16.length == 0 {
                let position = item.displayStart + segment.displayRangeUTF16.location
                if (position == selection.location && segment.isOpening)
                    || (position == NSMaxRange(selection) && !segment.isOpening)
                {
                    range = NSUnionRange(range, segment.sourceRangeUTF16)
                }
            }
        }
        return range
    }

    @discardableResult
    private func replaceSource(_ range: NSRange, with replacement: String, origin: EditOrigin, name: String) -> Bool {
        guard isEditable, !hasMarkedText(), range.location >= 0, range.length >= 0,
            NSMaxRange(range) <= (source as NSString).length
        else { return false }
        let patch = SourcePatch(rangeUTF16: range, expectedText: (source as NSString).substring(with: range), replacement: replacement)
        guard case .success(let updated) = MarkdownPatchApplier.applyPatches([patch], to: source) else { return false }
        if source == updated { return true }
        let caret = range.location + replacement.utf16.count
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch], sourceBefore: source,
                selectionBefore: MarkdownSelection(anchorUTF16: range.location, focusUTF16: NSMaxRange(range), affinity: .downstream),
                selectionAfter: MarkdownSelection(anchorUTF16: caret, focusUTF16: caret, affinity: .downstream), origin: origin, name: name))
        publishSource(updated, patches: [patch])
        revision += 1
        rebuildProjection()
        restoreSelectionFromSource(MarkdownSelection(anchorUTF16: caret, focusUTF16: caret, affinity: .downstream))
        return true
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        menu.addItem(.separator())
        let actions: [(String, Selector)] = [
            ("Copy Visible Text", #selector(copyVisibleText(_:))), ("Copy Markdown", #selector(copyMarkdown(_:))),
            ("Paste Plain Text", #selector(pasteAsPlainText(_:))), ("Paste Markdown", #selector(pasteMarkdown(_:))),
        ]
        for (title, action) in actions {
            let item = NSMenuItem(title: I18n.str(title), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if linkAtSelection()?.isImage == true {
            let item = NSMenuItem(title: I18n.str("Edit Image"), action: #selector(editImage(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        appendTableMenuItems(to: menu, for: event)
        appendCodeFenceMenuItems(to: menu)
        return menu
    }

    /// T15:caret 在 codeFence 内时追加语言子菜单(界定符面板的菜单入口,
    /// source 事务)。
    func appendCodeFenceMenuItems(to menu: NSMenu) {
        rebuildProjection()
        guard codeFenceBlockAtCaret() != nil else { return }
        menu.addItem(.separator())
        let language = NSMenuItem(title: I18n.str("Change Language"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for lang in [
            "swift", "python", "javascript", "typescript", "json", "html",
            "css", "shell", "sql", "yaml", "c", "cpp", "objc",
        ] {
            let item = NSMenuItem(
                title: lang, action: #selector(codeFenceLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang
            languageMenu.addItem(item)
        }
        language.submenu = languageMenu
        menu.addItem(language)
        let exit = NSMenuItem(
            title: I18n.str("Exit Code Block"), action: #selector(codeFenceExit(_:)),
            keyEquivalent: "")
        exit.target = self
        menu.addItem(exit)
    }

    @objc func codeFenceLanguage(_ sender: NSMenuItem) {
        guard let lang = sender.representedObject as? String else { return }
        setCodeFenceLanguage(lang)
    }

    @objc func codeFenceExit(_ sender: Any?) {
        exitCodeBlockAtCaret()
    }

    /// T16:右键落格时把 caret 移到点击处并追加行列命令项(Typora 语义)。
    func configureAttachmentOwner(url: URL, isValid: @escaping () -> Bool) {
        invalidateAttachmentRequests()
        attachmentOwnerURL = url
        attachmentOwnerIsValid = isValid
    }

    func invalidateAttachmentRequests() {
        attachmentAnchors.removeAll()
    }

    func beginAttachmentRequest() -> UUID? {
        guard isEditable, !hasMarkedText(), !selectionIsLiteral,
            attachmentOwnerIsValid?() == true, let range = editingSourceRange()
        else { return nil }
        let requestID = UUID()
        attachmentAnchors[requestID] = range
        return requestID
    }

    @discardableResult
    func completeAttachmentRequest(_ requestID: UUID, written: MarkdownAttachmentWriter.Written) -> Bool {
        guard !completedAttachmentRequests.contains(requestID) else { return false }
        guard let range = attachmentAnchors.removeValue(forKey: requestID),
            attachmentOwnerIsValid?() == true, !hasMarkedText()
        else {
            MarkdownAttachmentWriter.discard(written)
            return false
        }
        guard replaceSource(range, with: written.markdown, origin: .attachment, name: "attachment") else {
            MarkdownAttachmentWriter.discard(written)
            return false
        }
        completedAttachmentRequests.insert(requestID)
        return true
    }

    @discardableResult
    func importAttachment(_ input: MarkdownAttachmentWriter.Input) -> Task<Void, Never>? {
        guard let noteURL = attachmentOwnerURL, let requestID = beginAttachmentRequest() else { return nil }
        return Task { @MainActor [weak self] in
            let result = await Task.detached {
                Result { try MarkdownAttachmentWriter.write(input, noteURL: noteURL) }
            }.value
            guard let self else {
                if case .success(let written) = result { MarkdownAttachmentWriter.discard(written) }
                return
            }
            switch result {
            case .success(let written):
                if self.completeAttachmentRequest(requestID, written: written) {
                    self.lastAttachmentError = nil
                    self.onAttachmentFinished?(.success(written.url))
                } else {
                    self.lastAttachmentError = EditRejection.staleRevision
                    self.onAttachmentFinished?(.failure(EditRejection.staleRevision))
                    AppDelegate.trackError(EditRejection.staleRevision, context: "RichMarkdownTextView.attachmentAnchor")
                }
            case .failure(let error):
                self.attachmentAnchors.removeValue(forKey: requestID)
                self.lastAttachmentError = error
                self.onAttachmentFinished?(.failure(error))
                AppDelegate.trackError(error, context: "RichMarkdownTextView.importAttachment")
            }
        }
    }

    private func publishSource(_ updated: String, patches: [SourcePatch]) {
        for patch in patches.sorted(by: { $0.rangeUTF16.location > $1.rangeUTF16.location }) {
            let change = patch.rangeUTF16
            let delta = patch.replacement.utf16.count - change.length
            for (requestID, anchor) in attachmentAnchors {
                if anchor.length == 0, change.length > 0, NSMaxRange(change) == anchor.location {
                    attachmentAnchors.removeValue(forKey: requestID)
                } else if NSMaxRange(change) <= anchor.location {
                    attachmentAnchors[requestID] = NSRange(location: anchor.location + delta, length: anchor.length)
                } else if change.location < NSMaxRange(anchor) || (anchor.length == 0 && change.location <= anchor.location) {
                    attachmentAnchors.removeValue(forKey: requestID)
                }
            }
        }
        source = updated
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptedDragOperation(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptedDragOperation(sender)
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptedDragOperation(sender) == .copy
    }

    private func acceptedDragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable, !hasMarkedText(), sender.draggingSourceOperationMask.contains(.copy),
            sender.draggingPasteboard.availableType(from: readablePasteboardTypes) != nil
        else { return [] }
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            guard urls.count == 1, attachmentOwnerIsValid?() == true else { return [] }
        }
        return .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptedDragOperation(sender) == .copy else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let offset = characterIndexForInsertion(at: point)
        setSelectedRange(NSRange(location: offset, length: 0))
        return readSelection(from: sender.draggingPasteboard)
    }

    @discardableResult
    func updateImage(alt: String, target: String, title: String?) -> Bool {
        guard !selectionIsLiteral, let span = linkAtSelection(), span.isImage,
            MarkdownLinkSafety.isEditableTarget(target), !alt.contains("\n"), !alt.contains("\r"),
            !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            title?.contains("\n") != true, title?.contains("\r") != true
        else { return false }
        let label = alt.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let destination = target.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "\"", with: "%22")
        let suffix = title.map { " \"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" } ?? ""
        return replaceSource(span.fullRangeUTF16, with: "![\(label)](\(destination)\(suffix))", origin: .format, name: "image-metadata")
    }

    @objc private func editImage(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let span = linkAtSelection(), span.isImage else { return }
        let capturedRevision = revision
        let alert = NSAlert()
        alert.messageText = I18n.str("Edit Image")
        alert.addButton(withTitle: I18n.str("Save"))
        alert.addButton(withTitle: I18n.str("Cancel"))
        let fields = [
            NSTextField(string: InlineLinkScanner.unescape(span.label)),
            NSTextField(string: InlineLinkScanner.unescape(span.target)), NSTextField(string: span.title ?? ""),
        ]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for (field, title) in zip(fields, ["Alternative Text", "Image URL", "Image Title"]) {
            stack.addArrangedSubview(NSTextField(labelWithString: I18n.str(title)))
            field.setAccessibilityLabel(I18n.str(title))
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
            stack.addArrangedSubview(field)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 164)
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard revision == capturedRevision else { NSSound.beep(); return }
        if !updateImage(alt: fields[0].stringValue, target: fields[1].stringValue, title: fields[2].stringValue.isEmpty ? nil : fields[2].stringValue) {
            NSSound.beep()
        }
    }

    /// selection/caret 命中的 inline link（label 或 target 均算命中）。
    public func linkAtSelection() -> InlineLinkSpan? {
        rebuildProjection()
        let caret = sourceCaret()
        return InlineLinkScanner.scan(source).first { span in
            caret >= span.fullRangeUTF16.location && caret <= NSMaxRange(span.fullRangeUTF16)
        }
    }

    /// 编辑 link target（label 与 target 独立：改 target 不动 label 字节）。
    /// 安全 scheme 白名单校验；拒绝时不动 source 并返回 false。
    @discardableResult
    public func updateLinkTarget(_ newTarget: String) -> Bool {
        guard isEditable, !hasMarkedText(), !selectionIsLiteral else { return false }
        rebuildProjection()
        guard let span = linkAtSelection(), !span.isImage else { return false }
        guard MarkdownLinkSafety.isEditableTarget(newTarget), newTarget != span.target else {
            return false
        }
        let patch = SourcePatch(
            rangeUTF16: span.targetRangeUTF16, expectedText: span.target, replacement: newTarget
        )
        guard case .success(let newSource) = MarkdownPatchApplier.applyPatches([patch], to: source) else {
            return false
        }
        let caretBefore = sourceCaret()
        let caretAfter = span.targetRangeUTF16.location + (newTarget as NSString).length
        history.record(
            MarkdownEditorHistory.RecordInput(
                patches: [patch], sourceBefore: source,
                selectionBefore: MarkdownSelection(
                    anchorUTF16: caretBefore, focusUTF16: caretBefore, affinity: .downstream
                ),
                selectionAfter: MarkdownSelection(
                    anchorUTF16: caretAfter, focusUTF16: caretAfter, affinity: .downstream
                ),
                origin: .format, name: "link-target"
            ))
        publishSource(newSource, patches: [patch])
        revision += 1
        rebuildProjection()
        if let display = displayOffset(forSourceOffset: caretAfter) {
            setSelectedRange(NSRange(location: display, length: 0))
        }
        return true
    }

    /// modifier → link open 意图：仅 ⌘ 且命中非 image inline link 返回
    /// span。判定独立成纯方法：mouseDown 的 super 转发路径不能在测试
    /// 环境驱动（无真实事件源会同步等待窗口服务）。
    public func openLinkIntent(modifierFlags: NSEvent.ModifierFlags) -> InlineLinkSpan? {
        guard modifierFlags.contains(.command) else { return nil }
        guard let span = linkAtSelection(), !span.isImage else { return nil }
        return span
    }

    /// T11：⌘+click 开链接；普通 click 只移动 caret（默认行为，不 resourceify）。
    public override func mouseDown(with event: NSEvent) {
        if let span = openLinkIntent(modifierFlags: event.modifierFlags) {
            onOpenLink?(span)
            return
        }
        // 渲染块附件点击:切换 collapsed⇄expanded(只改显示,不动 source)。
        if let layoutManager, let textContainer {
            let point = convert(event.locationInWindow, from: nil)
            let glyphIndex = layoutManager.glyphIndex(
                for: point, in: textContainer, fractionOfDistanceThroughGlyph: nil)
            if glyphIndex != NSNotFound {
                let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
                if charIndex < textStorage?.length ?? 0,
                    textStorage?.attribute(.attachment, at: charIndex, effectiveRange: nil) != nil,
                    toggleRenderedBlock(at: charIndex)
                {
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: - undo / redo

    @objc(undo:) public func undoAction(_ sender: Any?) {
        _ = performUndo()
    }

    @objc(redo:) public func redoAction(_ sender: Any?) {
        _ = performRedo()
    }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case NSSelectorFromString("undo:"):
            return isEditable && !hasMarkedText() && history.canUndo
        case NSSelectorFromString("redo:"):
            return isEditable && !hasMarkedText() && history.canRedo
        case #selector(copyVisibleText(_:)), #selector(copyMarkdown(_:)):
            return selectedRange().length > 0
        case #selector(pasteMarkdown(_:)), #selector(pasteAsPlainText(_:)):
            return isEditable && !hasMarkedText() && NSPasteboard.general.availableType(from: [.string, MarkdownClipboardAdapter.markdownType]) != nil
        case #selector(editImage(_:)):
            return isEditable && !hasMarkedText() && linkAtSelection()?.isImage == true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    public override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == NSSelectorFromString("undo:") || menuItem.action == NSSelectorFromString("redo:") {
            return validateUserInterfaceItem(menuItem)
        }
        return super.validateMenuItem(menuItem)
    }

    /// T19:caret 移动(点击/方向键)后重涂降噪——本视图是自身 delegate。
    public func textViewDidChangeSelection(_ notification: Notification) {
        updateFocusDimming()
    }

    /// T06：undo/redo 经 history 返回新 source 与 selection，view 推进
    /// 自己的 revision（每次外观变更都是新 revision，包括 undo）。不允许
    /// 以「回退到旧 revision」冒充——旧 async 任务必须按 revision 失效。
    /// T12：history 的 selection 统一 source 坐标，恢复时经当前投影映射
    /// 回 display（marker 隐藏处两者偏移不同，直接当 display 用会错位）；
    /// 映射失败 clamp 到 display 长度，绝不落到投影外。
    @discardableResult
    public func performUndo() -> Bool {
        guard isEditable, !hasMarkedText() else { return false }
        rebuildProjection()
        guard let undo = history.undo(currentSource: source) else { return false }
        invalidateAttachmentRequests()
        source = undo.source
        revision += 1
        rebuildProjection()
        restoreSelectionFromSource(undo.selection)
        return true
    }

    @discardableResult
    public func performRedo() -> Bool {
        guard isEditable, !hasMarkedText() else { return false }
        rebuildProjection()
        guard let redo = history.redo(currentSource: source) else { return false }
        invalidateAttachmentRequests()
        source = redo.source
        revision += 1
        rebuildProjection()
        restoreSelectionFromSource(redo.selection)
        return true
    }

    private func restoreSelectionFromSource(_ selection: MarkdownSelection) {
        let displayLen = (string as NSString).length
        let focus =
            displayOffset(forSourceOffset: selection.focusUTF16)
            ?? min(selection.focusUTF16, displayLen)
        setSelectedRange(NSRange(location: min(focus, displayLen), length: 0))
        scrollCaretToCenterIfNeeded()
    }

    // MARK: - composition 观测（G0 探针）

    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // T06：进入 marked 时记录基线（composition 提交的历史 base）。
        // 仅首次进入记录；marked 期间的 update 不覆盖。
        if markedSourceBefore == nil {
            let currentCaret = sourceCaret()
            markedSourceBefore = source
            markedSelectionBefore = MarkdownSelection(
                anchorUTF16: currentCaret,
                focusUTF16: currentCaret,
                affinity: .downstream
            )
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        didChangeText()  // input 协议路径不自动通知 delegate（无 keyDown 上下文时）
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        // T06：composition 提交前的标记。NSTextView 的 IME 路径是
        // setMarkedText → ... → insertText(committed) → unmarkText。
        // insertText 触发 didChangeText → textDidChange 时 markedTextRange
        // 已被清空（insertText 先清 marked 再插入），所以必须在 insertText
        // 前标记，让随后的 textDidChange 知道这是 composition 提交。
        if markedSourceBefore != nil {
            justUnmarked = true
        }
        super.insertText(string, replacementRange: replacementRange)
        didChangeText()
    }

    public override func unmarkText() {
        super.unmarkText()
        // T06：justUnmarked 可能已在 insertText 前置位（composition 提交路径）。
        // 若 cachedDisplay == string，说明 marked 期间 source 已通过
        // syncSourceFromDisplayWithoutHistory 完全跟随，或取消后无净变化。
        let hasCommittedContent = cachedDisplay != string
        if hasCommittedContent && !justUnmarked {
            // 非 insertText 路径的提交（如外部直接 unmarkText）：标记。
            justUnmarked = true
        }
        if hasCommittedContent {
            textDidChange(Notification(name: NSText.didChangeNotification, object: self))
        } else {
            // 取消或无净变化：清掉基线，不留下一次提交的假 composition。
            finishCompositionHistory()
            // G0 修复：保存/恢复 selection（setAttributedString 会重置到 0）
            let sel = selectedRange()
            rebuildProjection()
            let maxLen = (string as NSString).length
            let clamped = min(sel.location, max(0, maxLen - sel.length))
            setSelectedRange(NSRange(location: clamped, length: sel.length))
        }
    }
}
