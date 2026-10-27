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
    private struct RenderedBlock {
        let block: LosslessMarkdownParser.Block
        let projection: MarkdownProjectionBuilder.Projection
        let displayStart: Int
    }
    private var rendered: [RenderedBlock] = []
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

    public init(source: String) {
        self.source = source
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
        rebuildProjection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - source 装载

    public func setSource(_ newSource: String) {
        source = newSource
        revision += 1
        document = parser.parse(source)
        history = MarkdownEditorHistory()
        rebuildProjection()
    }

    public var displayText: String { cachedDisplay }

    // MARK: - 投影重建

    private func rebuildProjection() {
        document = parser.parse(source)
        var pieces: [String] = []
        pieces.reserveCapacity(document.blocks.count)
        var renderedNew: [RenderedBlock] = []
        renderedNew.reserveCapacity(document.blocks.count)
        var cursor = 0
        for block in document.blocks {
            let projection = builder.buildProjection(for: block, in: document)
            renderedNew.append(RenderedBlock(block: block, projection: projection, displayStart: cursor))
            pieces.append(projection.display)
            cursor += projection.display.utf16.count
            // 块显示之间保证一个换行（投影 display 通常已含行尾；空缺时补）
            if let last = pieces.last, !last.hasSuffix("\n"), block != document.blocks.last {
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
        applyDisplayAttributes()
        storage.endEditing()
        composingGuard = false
    }

    /// T10：host 注入的正文/代码字体（NE-32 字体/缩放经设置与 ⌘± 联动）。
    /// 变化后需调用 `refreshFontAttributes()` 重刷属性。
    public var bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    public var codeFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// T10：host 注入的正文前景色（深浅色主题）。
    public var contentTextColor = NSColor.black

    /// G0 原型的最小样式：保护块等宽字体、code span 等宽（视觉验证用）。
    private func applyDisplayAttributes() {
        guard let storage = textStorage else { return }
        let mono = codeFont
        for item in rendered {
            let block = item.block; let projection = item.projection; let start = item.displayStart
            if case .codeFence = block.kind {
                storage.addAttribute(.font, value: mono, range: NSRange(location: start, length: projection.display.utf16.count))
                continue
            }
            for segment in projection.segments where segment.kind == .codeSpan {
                let range = NSRange(location: start + segment.displayRangeUTF16.location, length: segment.displayRangeUTF16.length)
                if range.length > 0 {
                    storage.addAttribute(.font, value: mono, range: range)
                }
            }
        }
    }

    /// T10：字体变化后重刷全文属性（display 已在 storage 中，只重铺字体）。
    public func refreshFontAttributes() {
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.font, value: bodyFont, range: full)
        storage.addAttribute(.foregroundColor, value: contentTextColor, range: full)
        applyDisplayAttributes()
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
            // 若是 composition 提交（justUnmarked），先记录历史再同步 source。
            if justUnmarked, let baseSource = markedSourceBefore,
                let baseSelection = markedSelectionBefore
            {
                let commitPatch = Self.wholeRangePatch(from: baseSource, to: newDisplay)
                let sel = selectedRange()
                history.record(
                    MarkdownEditorHistory.RecordInput(
                        patches: [commitPatch], sourceBefore: baseSource,
                        selectionBefore: baseSelection,
                        selectionAfter: MarkdownSelection(
                            anchorUTF16: sel.location, focusUTF16: NSMaxRange(sel), affinity: .downstream
                        ),
                        origin: .composition, name: "composition"
                    ))
                markedSourceBefore = nil
                markedSelectionBefore = nil
                justUnmarked = false
            }
            syncSourceFromDisplayWithoutHistory(newDisplay: newDisplay)
            cachedDisplay = newDisplay
            return
        }

        let diff = Self.fastDiff(old: cachedDisplay, new: newDisplay)
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
            let projection = item.projection
            let localDisplay = editDisplayStart - item.displayStart
            let sourceStart = projection.sourceOffset(forDisplay: localDisplay) ?? item.block.rangeUTF16.location

            let patch = SourcePatch(
                rangeUTF16: NSRange(location: sourceStart, length: oldText.utf16.count),
                expectedText: oldText,
                replacement: replacement
            )
            // patch 必须完整落在本块内：跨块编辑窗（oldText 含块间换行）
            // 的 display 文本可能与 source 侧后续块内容碰巧重合，仅凭
            // expectedText 匹配不能证明单块映射成立——越界的一律交给
            // 跨块 span 路径验证（marked 期间无 span 路径，回退显示）。
            let withinBlock = sourceStart >= item.block.rangeUTF16.location
                && sourceStart + oldText.utf16.count <= NSMaxRange(item.block.rangeUTF16)
            if withinBlock,
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
                            anchorUTF16: patch.rangeUTF16.location + replacement.utf16.count,
                            focusUTF16: patch.rangeUTF16.location + replacement.utf16.count,
                            affinity: .downstream
                        ),
                        origin: .typing,
                        name: "typing"
                    ))
                source = newSource
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

        if !applied, !oldText.isEmpty,
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
                source = newSource
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
                let display = displayOffset(forSourceOffset: sourceCaretAfter)
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

    /// T06：marked 期间的 source 同步（不登记历史）。映射逻辑与
    /// textDidChange 主路径相同，只是跳过 history.record——SPEC §5.3
    /// 要求临时变化不产生持久化 transaction。
    private func syncSourceFromDisplayWithoutHistory(newDisplay: String) {
        let diff = Self.fastDiff(old: cachedDisplay, new: newDisplay)
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
                source = newSource
                revision += 1
            }
            break
        }
    }

    /// 构造「整段替换」patch：从 base 到 target 的单一 SourcePatch。
    /// 用于 composition 提交把整段 marked 内容一次成组（undo 回 composition
    /// 前需要 base 是 marked 前的 source，而不是最后一次增量前的）。
    private static func wholeRangePatch(from base: String, to target: String) -> SourcePatch {
        SourcePatch(
            rangeUTF16: NSRange(location: 0, length: base.utf16.count),
            expectedText: base,
            replacement: target
        )
    }

    private static func fastDiff(old: String, new: String) -> DiffResult {
        let oldNS = old as NSString
        let newNS = new as NSString
        let minLen = min(oldNS.length, newNS.length)
        var prefix = 0
        while prefix < minLen, oldNS.character(at: prefix) == newNS.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < minLen - prefix,
            oldNS.character(at: oldNS.length - 1 - suffix) == newNS.character(at: newNS.length - 1 - suffix)
        {
            suffix += 1
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
        rebuildProjection()  // 结构命令需要准确的块定位
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
    private func sourceCaret() -> Int {
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
    private func applyStructurePatches(
        _ patches: [SourcePatch], name: String, restoreSourceCaret: Int? = nil
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
                origin: .structure,
                name: name
            ))
        source = newSource
        revision += 1
        rebuildProjection()
        if let caret = restoreSourceCaret {
            // 新空行在 display 上零长度（marker 全隐藏）：caret 自身可能
            // 无 display 映射，回退试下一 unit（行尾换行），再不行 clamp
            // 到 display 末尾（拆分尾空行的落点）。
            let sourceLen = (source as NSString).length
            let display = displayOffset(forSourceOffset: caret)
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

    /// task 勾选翻转：精确替换括号内单字符（NE-07 精确 span toggle）。
    /// preview checkbox intent（T14）复用同一入口，保证同一事务语义。
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

    // MARK: - T11 行内格式命令与链接（source patch，AC-01/NE-05/NE-06/NE-12）

    /// T11：modifier+click 开链接与普通 click 编辑 caret 的区分入口。
    /// target 交给 host 解析（相对路径需 note 上下文）；未注册回调或
    /// 点击处无 link 时走默认 caret 行为。
    public var onOpenLink: ((InlineLinkSpan) -> Void)?

    /// 行内格式 toggle：选中区间 wrap/unwrap delimiter（空选中取光标处
    /// 连续非空白词）。patch 原子应用，未选中范围不动；origin .format。
    @discardableResult
    public func applyInlineFormat(_ kind: MarkdownInlineFormat) -> Bool {
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
        source = newSource
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
    private func sourceRange(forDisplayRange range: NSRange) -> NSRange? {
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
                let value = next.projection.sourceOffset(forDisplay: 0)
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
        guard let match = MarkdownInputRules.matchPrefixInsertion(
            source: source, insertedOffset: insertedOffset,
            protectedRanges: protectedBlockRanges()
        ) else { return }
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
            case .codeFence, .codeIndented, .htmlBlock, .table, .frontmatter:
                return block.rangeUTF16
            default:
                return nil
            }
        }
    }

    /// 粘贴/拖放统一入口：⌘V 与 drop 都经读板路径，在这里置位排除输入
    /// 规则（NE-21 粘贴不触发 typing rule）。
    public override func paste(_ sender: Any?) {
        isPastingFlag = true
        defer { isPastingFlag = false }
        super.paste(sender)
    }

    public override func readSelection(from pboard: NSPasteboard) -> Bool {
        isPastingFlag = true
        defer { isPastingFlag = false }
        return super.readSelection(from: pboard)
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
        source = newSource
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
        super.mouseDown(with: event)
    }

    // MARK: - undo / redo

    /// T06：undo/redo 经 history 返回新 source 与 selection，view 推进
    /// 自己的 revision（每次外观变更都是新 revision，包括 undo）。不允许
    /// 以「回退到旧 revision」冒充——旧 async 任务必须按 revision 失效。
    /// T12：history 的 selection 统一 source 坐标，恢复时经当前投影映射
    /// 回 display（marker 隐藏处两者偏移不同，直接当 display 用会错位）；
    /// 映射失败 clamp 到 display 长度，绝不落到投影外。
    @discardableResult
    public func performUndo() -> Bool {
        rebuildProjection()
        guard let undo = history.undo(currentSource: source) else { return false }
        source = undo.source
        revision += 1
        rebuildProjection()
        restoreSelectionFromSource(undo.selection)
        return true
    }

    @discardableResult
    public func performRedo() -> Bool {
        rebuildProjection()
        guard let redo = history.redo(currentSource: source) else { return false }
        source = redo.source
        revision += 1
        rebuildProjection()
        restoreSelectionFromSource(redo.selection)
        return true
    }

    private func restoreSelectionFromSource(_ selection: MarkdownSelection) {
        let displayLen = (string as NSString).length
        let focus = displayOffset(forSourceOffset: selection.focusUTF16)
            ?? min(selection.focusUTF16, displayLen)
        setSelectedRange(NSRange(location: min(focus, displayLen), length: 0))
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
            markedSourceBefore = nil
            markedSelectionBefore = nil
            justUnmarked = false
            // G0 修复：保存/恢复 selection（setAttributedString 会重置到 0）
            let sel = selectedRange()
            rebuildProjection()
            let maxLen = (string as NSString).length
            let clamped = min(sel.location, max(0, maxLen - sel.length))
            setSelectedRange(NSRange(location: clamped, length: sel.length))
        }
    }
}
