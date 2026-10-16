import AppKit

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
    public private(set) var source: String
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
        let defaultFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let displayLength = (newDisplay as NSString).length
        storage.addAttribute(.font, value: defaultFont, range: NSRange(location: 0, length: displayLength))
        applyDisplayAttributes()
        storage.endEditing()
        composingGuard = false
    }

    /// G0 原型的最小样式：保护块等宽字体、code span 等宽（视觉验证用）。
    private func applyDisplayAttributes() {
        guard let storage = textStorage else { return }
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
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

        // 定位编辑窗所属块并映射为 source patch；patch 被拒或编辑落在
        // 块间分隔符（不属于任何投影）时不静默吞掉——source 是权威，
        // cachedDisplay 不得领先 source。
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
            switch MarkdownPatchApplier.applyPatches([patch], to: source) {
            case .success(let newSource):
                let selectionBefore = selectedRange()
                // T06：composition 提交已在上方 marked/justUnmarked 分支
                // 处理（一次成组 + 清基线）。这里只剩普通 typing。
                history.record(
                    MarkdownEditorHistory.RecordInput(
                        patches: [patch], sourceBefore: source,
                        selectionBefore: MarkdownSelection(
                            anchorUTF16: selectionBefore.location,
                            focusUTF16: NSMaxRange(selectionBefore),
                            affinity: .downstream
                        ),
                        selectionAfter: MarkdownSelection(
                            anchorUTF16: selectionBefore.location + replacement.utf16.count,
                            focusUTF16: selectionBefore.location + replacement.utf16.count,
                            affinity: .downstream
                        ),
                        origin: .typing,
                        name: "typing"
                    ))
                source = newSource
                revision += 1
            case .failure(let rejection):
                // 观察口（测试/诊断）：映射歧义或 expectedText 失配时拒绝
                // 写 source；随后统一走回退分支把显示拉回 source。
                lastSyncRejection = rejection
            }
            break
        }

        // composition 期间不重建（保持 markedTextRange）；否则以 source 为准
        // 立即重建投影——成功时简单编辑的 display == string，textStorage 替换
        // 被跳过（无闪烁、无 selection 重置）；失败时显示被显式回退。每次编辑
        // 后立即收敛坐标：延迟到下一次编辑再收敛会让 rendered 的 displayStart/
        // 块长过期，块尾连续输入自第 3 字符起定位错。
        if !hasMarkedText() {
            let restore = selectedRange()
            rebuildProjection()
            let clamped = min(restore.location, max(0, (string as NSString).length - restore.length))
            setSelectedRange(NSRange(location: clamped, length: restore.length))
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

    /// G0 诊断口：caret 的 source 偏移与所在 list item（测试观察用）。
    func debugListItemLocalization() -> (sourceCaret: Int, item: Bool) {
        rebuildProjection()
        return (sourceCaret(), currentListItem() != nil)
    }

    // MARK: - 结构命令（Enter/Tab/Backspace 于 list；G0 三层 list 原型）

    public func text(_: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        rebuildProjection()  // 结构命令需要准确的块定位
        switch commandSelector {
        case #selector(insertNewline(_:)):
            return handleEnterInList()
        case #selector(insertTab(_:)):
            return handleTabInList(indent: true)
        case #selector(insertBacktab(_:)):
            return handleTabInList(indent: false)
        case #selector(deleteBackward(_:)):
            return handleBackspaceAtListItemStart()
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

    /// 当前 caret 所在 list item 的定位。
    private struct ListItemContext {
        let block: LosslessMarkdownParser.Block
        let lineRange: NSRange
        /// marker 总长（缩进 + 符号 + 尾随空格），Backspace/Enter 拆分用。
        let markerLength: Int
        /// marker 符号起始（含缩进），Tab 缩进/退格的插入点。
        let markerOffset: Int
    }

    /// 解析行首 marker：无序 `-`/`*`/`+` 或有序 `数字.`/`数字)` + 尾随空格
    /// （或行尾裸 marker 空项）。marker 符号起点（相对行首）与总长；
    /// 无 marker（含紧贴内容的 "-x"/"1.x"）返回 nil。
    private static func parseListMarker(_ body: some StringProtocol) -> (symbolStart: Int, length: Int)? {
        var idx = body.startIndex
        // 缩进
        while idx < body.endIndex, body[idx] == " " || body[idx] == "\t" {
            idx = body.index(after: idx)
        }
        let symbolStart = body.distance(from: body.startIndex, to: idx)
        guard idx < body.endIndex else { return nil }
        let c = body[idx]
        if c == "-" || c == "*" || c == "+" {
            idx = body.index(after: idx)
            let markerLen = body.distance(from: body.startIndex, to: idx)
            guard idx < body.endIndex else { return (symbolStart, markerLen) }
            let n = body[idx]
            if n == "\n" || n == "\r" { return (symbolStart, markerLen) }
            guard n == " " || n == "\t" else { return nil }
            while idx < body.endIndex, body[idx] == " " || body[idx] == "\t" {
                idx = body.index(after: idx)
            }
            return (symbolStart, body.distance(from: body.startIndex, to: idx))
        }
        // 有序：数字串 + ./) + 空格（或行尾空项）
        var digits = 0
        while idx < body.endIndex, body[idx].isNumber {
            digits += 1
            idx = body.index(after: idx)
        }
        guard digits > 0, idx < body.endIndex, body[idx] == "." || body[idx] == ")" else { return nil }
        idx = body.index(after: idx)
        let markerLen = body.distance(from: body.startIndex, to: idx)
        guard idx < body.endIndex else { return (symbolStart, markerLen) }
        let n = body[idx]
        if n == "\n" || n == "\r" { return (symbolStart, markerLen) }
        guard n == " " || n == "\t" else { return nil }
        while idx < body.endIndex, body[idx] == " " || body[idx] == "\t" {
            idx = body.index(after: idx)
        }
        return (symbolStart, body.distance(from: body.startIndex, to: idx))
    }

    private func currentListItem() -> ListItemContext? {
        let caret = sourceCaret()
        let ns = source as NSString
        for block in document.blocks {
            guard case .listItem = block.kind else { continue }
            let blockStart = block.rangeUTF16.location
            let blockEnd = NSMaxRange(block.rangeUTF16)
            guard caret >= blockStart, caret <= blockEnd else { continue }
            let probe = min(max(caret, blockStart), max(blockStart, blockEnd - 1))
            let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
            let line = ns.substring(with: lineRange)
            // 嵌套项行首有缩进，连同有序 marker 一起解析（与块解析器同规则）
            guard let marker = Self.parseListMarker(line) else { return nil }
            return ListItemContext(
                block: block, lineRange: lineRange,
                markerLength: marker.length, markerOffset: marker.symbolStart
            )
        }
        return nil
    }

    private func applyStructurePatches(
        _ patches: [SourcePatch], name: String, restoreSourceCaret: Int? = nil
    ) {
        let selectionBefore = selectedRange()
        if case .success(let newSource) = MarkdownPatchApplier.applyPatches(patches, to: source) {
            let caretAfter = restoreSourceCaret ?? sourceCaret()
            history.record(
                MarkdownEditorHistory.RecordInput(
                    patches: patches, sourceBefore: source,
                    selectionBefore: MarkdownSelection(
                        anchorUTF16: selectionBefore.location,
                        focusUTF16: NSMaxRange(selectionBefore),
                        affinity: .downstream
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
            if let caret = restoreSourceCaret, let display = displayOffset(forSourceOffset: caret) {
                setSelectedRange(NSRange(location: display, length: 0))
            }
        }
    }

    private func handleEnterInList() -> Bool {
        guard let item = currentListItem() else { return false }
        let lineRange = item.lineRange
        let markerLength = item.markerLength
        let ns = source as NSString
        let line = ns.substring(with: lineRange)
        let content = String(line.dropFirst(markerLength)).trimmingCharacters(in: .whitespacesAndNewlines)

        if content.isEmpty {
            // 空项回车：退出列表（删 marker 行）
            let lineLen = lineRange.length
            applyStructurePatches(
                [
                    SourcePatch(rangeUTF16: NSRange(location: lineRange.location, length: lineLen), expectedText: line, replacement: "")
                ], name: "list-exit", restoreSourceCaret: lineRange.location)
            return true
        }
        // 拆分：在 caret 处插入换行 + 同级 marker，caret 之后的内容归新项
        // （Typora 语义）；caret 恰在内容起点时前项为空项，可再 Enter 退出。
        let marker = String(line.prefix(markerLength))
        let contentStart = lineRange.location + markerLength
        let lineEnd = NSMaxRange(lineRange) - (line.hasSuffix("\n") ? 1 : 0)
        let insertAt = max(contentStart, min(sourceCaret(), lineEnd))
        applyStructurePatches(
            [
                SourcePatch(rangeUTF16: NSRange(location: insertAt, length: 0), expectedText: "", replacement: "\n" + marker)
            ], name: "list-split", restoreSourceCaret: insertAt + 1 + markerLength)
        return true
    }

    private func handleTabInList(indent: Bool) -> Bool {
        guard let item = currentListItem() else { return false }
        let lineRange = item.lineRange
        let markerAt = lineRange.location + item.markerOffset

        if indent {
            applyStructurePatches(
                [
                    SourcePatch(rangeUTF16: NSRange(location: markerAt, length: 0), expectedText: "", replacement: "  ")
                ], name: "list-indent", restoreSourceCaret: markerAt + 2)
        } else if item.markerOffset >= 2 {
            applyStructurePatches(
                [
                    SourcePatch(rangeUTF16: NSRange(location: markerAt - 2, length: 2), expectedText: "  ", replacement: "")
                ], name: "list-outdent", restoreSourceCaret: markerAt - 2)
        }
        return true
    }

    private func handleBackspaceAtListItemStart() -> Bool {
        guard let item = currentListItem() else { return false }
        let lineRange = item.lineRange
        let markerLength = item.markerLength
        let caret = sourceCaret()
        // caret 恰在内容起点（marker 之后）
        guard caret == lineRange.location + markerLength, caret > 0 else { return false }
        let ns = source as NSString
        let marker = ns.substring(with: NSRange(location: lineRange.location, length: markerLength))
        applyStructurePatches(
            [
                SourcePatch(rangeUTF16: NSRange(location: lineRange.location, length: markerLength), expectedText: marker, replacement: "")
            ], name: "list-unmark", restoreSourceCaret: lineRange.location)
        return true
    }

    // MARK: - undo / redo

    /// T06：undo/redo 经 history 返回新 source 与 selection，view 推进
    /// 自己的 revision（每次外观变更都是新 revision，包括 undo）。不允许
    /// 以「回退到旧 revision」冒充——旧 async 任务必须按 revision 失效。
    @discardableResult
    public func performUndo() -> Bool {
        rebuildProjection()
        guard let undo = history.undo(currentSource: source) else { return false }
        source = undo.source
        revision += 1
        rebuildProjection()
        if undo.selection.focusUTF16 <= (string as NSString).length {
            setSelectedRange(NSRange(location: undo.selection.focusUTF16, length: 0))
        }
        return true
    }

    @discardableResult
    public func performRedo() -> Bool {
        rebuildProjection()
        guard let redo = history.redo(currentSource: source) else { return false }
        source = redo.source
        revision += 1
        rebuildProjection()
        if redo.selection.focusUTF16 <= (string as NSString).length {
            setSelectedRange(NSRange(location: redo.selection.focusUTF16, length: 0))
        }
        return true
    }

    // MARK: - composition 观测（G0 探针）

    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // T06：进入 marked 时记录基线（composition 提交的历史 base）。
        // 仅首次进入记录；marked 期间的 update 不覆盖。
        if markedSourceBefore == nil {
            let currentRange = self.selectedRange()
            markedSourceBefore = source
            markedSelectionBefore = MarkdownSelection(
                anchorUTF16: currentRange.location,
                focusUTF16: NSMaxRange(currentRange),
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
