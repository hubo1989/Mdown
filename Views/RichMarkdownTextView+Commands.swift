import AppKit

// MARK: - T14 命令通道(RichMarkdownTextView 扩展;source patch 入口)
//
// 命令 adapter / find / preview intent 的原语。全部经 applyStructurePatches
// 的单事务应用(单条历史、可撤销);失败闭口,不动隐藏面。

extension RichMarkdownTextView {

    // MARK: - T14 命令通道（command adapter / find / preview intent 的 source patch 入口）

    /// display caret / 区间 → source 区间（供命令规划）。跨块或映射歧义
    /// 返回 nil——命令宁可拒绝也不猜坐标（NE-24：不同坐标不互用）。
    func commandSourceSelection() -> NSRange? {
        let sel = selectedRange()
        if sel.length > 0 {
            return sourceRange(forDisplayRange: sel)
        }
        let caret = sourceCaret()
        let ns = source as NSString
        guard caret <= ns.length else { return nil }
        return NSRange(location: caret, length: 0)
    }

    /// 选中内容 → 单块 source 文本；跨块/映射歧义 nil。
    func commandSelectedText() -> String? {
        guard let range = commandSourceSelection() else { return nil }
        let ns = source as NSString
        guard NSMaxRange(range) <= ns.length else { return nil }
        return ns.substring(with: range)
    }

    /// underline 命令：`<u>` 包裹/解除。raw inline HTML 在投影里整段原样
    /// 显示（plainFallback），wrap 后 marker 字面可见，与 source 模式一致。
    @discardableResult
    public func insertUnderlineCommand() -> Bool {
        guard isEditable, !hasMarkedText(), !selectionIsProtectedBlock else { return false }
        rebuildProjection()
        guard let sourceRange = commandSourceSelection(),
            NSMaxRange(sourceRange) <= (source as NSString).length
        else { return false }
        let ns = source as NSString
        let open = "<u>", close = "</u>"
        // unwrap：选中区间两侧紧贴标签，或区间本身含完整标签对
        if sourceRange.length >= (open as NSString).length + (close as NSString).length,
            ns.substring(with: sourceRange).hasPrefix(open),
            ns.substring(with: sourceRange).hasSuffix(close)
        {
            let inner = NSRange(
                location: sourceRange.location + (open as NSString).length,
                length: sourceRange.length - (open as NSString).length - (close as NSString).length)
            let patches = [
                SourcePatch(rangeUTF16: NSRange(location: sourceRange.location, length: (open as NSString).length), expectedText: open, replacement: ""),
                SourcePatch(rangeUTF16: NSRange(location: NSMaxRange(inner), length: (close as NSString).length), expectedText: close, replacement: ""),
            ]
            return applyStructurePatches(
                patches, name: "underline-unwrap", restoreSourceCaret: inner.location, origin: .format)
        }
        if sourceRange.location >= (open as NSString).length,
            NSMaxRange(sourceRange) + (close as NSString).length <= ns.length,
            ns.substring(with: NSRange(location: sourceRange.location - (open as NSString).length, length: (open as NSString).length)) == open,
            ns.substring(with: NSRange(location: NSMaxRange(sourceRange), length: (close as NSString).length)) == close
        {
            let patches = [
                SourcePatch(rangeUTF16: NSRange(location: sourceRange.location - (open as NSString).length, length: (open as NSString).length), expectedText: open, replacement: ""),
                SourcePatch(rangeUTF16: NSRange(location: NSMaxRange(sourceRange), length: (close as NSString).length), expectedText: close, replacement: ""),
            ]
            return applyStructurePatches(
                patches, name: "underline-unwrap", restoreSourceCaret: sourceRange.location - (open as NSString).length, origin: .format)
        }
        guard sourceRange.length > 0 else { return false }
        let selected = ns.substring(with: sourceRange)
        let patch = SourcePatch(
            rangeUTF16: sourceRange, expectedText: selected,
            replacement: open + selected + close)
        return applyStructurePatches(
            [patch], name: "underline-wrap",
            restoreSourceCaret: NSMaxRange(sourceRange) + (open as NSString).length + (close as NSString).length,
            origin: .format)
    }

    /// link 命令：选中内容包成 `[label](` 未配对骨架，caret 落 `(` 之后。
    /// 投影合同里配对 link 的 destination 是隐藏零宽段——display 没有
    /// 表面可落 caret（PR #10 review：caret 只能收敛到 label 边界，输入
    /// 会污染 label，target 无从填写）。未配对结构按合同走 plain
    /// fallback：骨架原文 1:1 可见可编辑，URL 输入/粘贴直接落在 `(` 后；
    /// 输入 `)` 配对完成后投影自动收敛为渲染态。空选中插入 `[](`，
    /// caret 落 `[` 后（先输 label）。
    @discardableResult
    public func insertLinkCommand() -> Bool {
        guard isEditable, !hasMarkedText(), !selectionIsProtectedBlock else { return false }
        rebuildProjection()
        guard let sourceRange = commandSourceSelection(),
            NSMaxRange(sourceRange) <= (source as NSString).length
        else { return false }
        let ns = source as NSString
        let label = ns.substring(with: sourceRange)
        let patch = SourcePatch(
            rangeUTF16: sourceRange, expectedText: label,
            replacement: "[" + label + "](")
        // label 非空：caret 落 `(` 之后（`[`+label+`]`+`(` 共 label 长度 +3），
        // 即 target 输入位；label 为空：caret 落 `[` 后（label 输入位）。
        let caretAfter =
            sourceRange.length > 0
            ? NSMaxRange(sourceRange) + 3
            : sourceRange.location + 1
        return applyStructurePatches([patch], name: "link", restoreSourceCaret: caretAfter, origin: .format)
    }

    /// todo 命令：光标行在 task item 上翻转勾选字符；普通行插入 `- [ ] `
    /// 前缀（与 TextFormatter.toggleTodo 同语义，坐标锚在会话 source）。
    @discardableResult
    public func toggleTodoCommand() -> Bool {
        guard isEditable, !hasMarkedText(), !selectionIsProtectedBlock else { return false }
        rebuildProjection()
        let ns = source as NSString
        let caret = sourceCaret()
        guard caret <= ns.length else { return false }
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let parsed = MarkdownBlockModel.parseLine(ns, lineRange: lineRange)
        if parsed.task != nil, let patch = MarkdownBlockModel.planTaskToggle(line: parsed) {
            return applyStructurePatches([patch], name: "todo-toggle", restoreSourceCaret: caret, origin: .structure)
        }
        let patch = SourcePatch(
            rangeUTF16: NSRange(location: lineRange.location, length: 0),
            expectedText: "", replacement: "- [ ] ")
        return applyStructurePatches([patch], name: "todo-insert", restoreSourceCaret: caret + 6, origin: .structure)
    }

    /// code block 命令：选中内容包进围栏，空选中插入空围栏；caret 落
    /// 开 fence 之后的行首。
    @discardableResult
    public func insertCodeBlockCommand() -> Bool {
        guard isEditable, !hasMarkedText(), !selectionIsProtectedBlock else { return false }
        rebuildProjection()
        let ns = source as NSString
        let sel = selectedRange()
        if sel.length > 0 {
            guard let sourceRange = sourceRange(forDisplayRange: sel),
                NSMaxRange(sourceRange) <= ns.length
            else { return false }
            let content = ns.substring(with: sourceRange)
            let needsNewline = !content.hasSuffix("\n")
            let replacement = "```\n" + content + (needsNewline ? "\n" : "") + "```\n"
            let patch = SourcePatch(
                rangeUTF16: sourceRange, expectedText: content, replacement: replacement)
            return applyStructurePatches([patch], name: "code-block", restoreSourceCaret: sourceRange.location + 4, origin: .format)
        }
        let caret = sourceCaret()
        guard caret <= ns.length else { return false }
        let patch = SourcePatch(
            rangeUTF16: NSRange(location: caret, length: 0),
            expectedText: "", replacement: "```\n\n```\n")
        return applyStructurePatches([patch], name: "code-block", restoreSourceCaret: caret + 4, origin: .format)
    }

    /// 快捷模板：与 source 模式 Tab 展开同语义——直接展开模板内容
    /// （PR #10 review：rich 面没有 `/name`+Tab 的展开路径，字面插入会让
    /// Quick Input 停在字面命令）。选区替换为模板内容；caret 按模板
    /// cursor 标记恢复，`{{select}}` 区间在 display 映射忠实（长度一致）
    /// 时选中，映射不可信（collapsed 渲染块映射到附件占位）时保持
    /// caret，不选中附件占位。未知模板退回字面 `/name` 插入（与 source
    /// 模式 Tab 展开失败同语义）。
    @discardableResult
    // MARK: - Tab Quick Input 菜单 action(WYSIWYG 模式下经 First Responder 命中)

    @IBAction public func insertTimeShortcut(_ sender: Any) { _ = insertShortcutTemplate("time") }

    @IBAction public func insertTableShortcut(_ sender: Any) { _ = insertShortcutTemplate("table") }

    @IBAction public func insertMathShortcut(_ sender: Any) { _ = insertShortcutTemplate("math") }

    @IBAction public func insertMathBlockShortcut(_ sender: Any) {
        _ = insertShortcutTemplate("mathblock")
    }

    @IBAction public func insertImgShortcut(_ sender: Any) { _ = insertShortcutTemplate("img") }

    @IBAction public func insertVideoShortcut(_ sender: Any) { _ = insertShortcutTemplate("video") }

    @IBAction public func insertMarkmapShortcut(_ sender: Any) { _ = insertShortcutTemplate("markmap") }

    @IBAction public func insertMermaidShortcut(_ sender: Any) { _ = insertShortcutTemplate("mermaid") }

    @IBAction public func insertPlantumlShortcut(_ sender: Any) { _ = insertShortcutTemplate("plantuml") }

    @IBAction public func insertFoldShortcut(_ sender: Any) { _ = insertShortcutTemplate("fold") }

    @IBAction public func insertTaskShortcut(_ sender: Any) { _ = insertShortcutTemplate("task") }

    public func insertShortcutTemplate(_ name: String) -> Bool {
        guard isEditable, !hasMarkedText(), !selectionIsProtectedBlock else { return false }
        rebuildProjection()
        let ns = source as NSString
        let caret = sourceCaret()
        guard caret <= ns.length else { return false }
        // 跨块选区映射歧义时退化为 caret 插入：显式拒绝会让调用方走
        // legacy 路径把会话踢回 source 布局（NE-24 不得踢回）。
        let range = commandSourceSelection() ?? NSRange(location: caret, length: 0)
        guard NSMaxRange(range) <= ns.length else { return false }
        guard let template = ShortcutTemplateManager.shared.getTemplate(for: name) else {
            let text = "/" + name
            let patch = SourcePatch(
                rangeUTF16: range, expectedText: ns.substring(with: range), replacement: text)
            return applyStructurePatches(
                [patch], name: "shortcut-template",
                restoreSourceCaret: NSMaxRange(range) + (text as NSString).length,
                origin: .structure)
        }
        let patch = SourcePatch(
            rangeUTF16: range, expectedText: ns.substring(with: range),
            replacement: template.content)
        let cursorStart = range.location + template.cursorOffset
        guard
            applyStructurePatches(
                [patch], name: "shortcut-template", restoreSourceCaret: cursorStart, origin: .structure)
        else { return false }
        if template.cursorLength > 0,
            let span = displayRange(
                forSourceRange: NSRange(location: cursorStart, length: template.cursorLength)),
            span.length == template.cursorLength
        {
            setSelectedRange(span)
            scrollRangeToVisible(span)
        }
        return true
    }

    /// Tab 展开斜杠命令(源码面 `EditTextView.handleShortcutExpansion`
    /// 的 rich 对应,PR #10 follow-up):光标前同一行内的 `/word`
    /// (word 全字母/数字)在 ShortcutTemplateManager 有模板时替换为
    /// 模板展开(替换 + cursor 恢复 + `{{select}}` 选中,与
    /// insertShortcutTemplate 同语义)。无命令/未知模板返回 false,
    /// 调用方回落既有 Tab 行为。
    func expandSlashShortcutAtCaret() -> Bool {
        guard isEditable, !hasMarkedText(), !selectionIsProtectedBlock else { return false }
        rebuildProjection()
        let ns = source as NSString
        let caret = sourceCaret()
        guard caret <= ns.length else { return false }
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        guard caret >= lineRange.location,
            caret - lineRange.location > 0
        else { return false }
        let before = ns.substring(
            with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        // 与源码面 extractShortcut 同判定:尾段不以 / 结尾、非空、全字母数字
        guard before.hasSuffix("/") == false,
            let word = before.components(separatedBy: "/").last,
            !word.isEmpty,
            word.allSatisfy({ $0.isLetter || $0.isNumber }),
            let template = ShortcutTemplateManager.shared.getTemplate(for: word)
        else { return false }
        let wordStart = caret - word.utf16.count - 1
        guard wordStart >= lineRange.location else { return false }
        let patch = SourcePatch(
            rangeUTF16: NSRange(location: wordStart, length: word.utf16.count + 1),
            expectedText: "/" + word,
            replacement: template.content)
        let cursorStart = wordStart + template.cursorOffset
        guard
            applyStructurePatches(
                [patch], name: "shortcut-expand-tab",
                restoreSourceCaret: cursorStart, origin: .structure)
        else { return false }
        if template.cursorLength > 0,
            let span = displayRange(
                forSourceRange: NSRange(location: cursorStart, length: template.cursorLength)),
            span.length == template.cursorLength
        {
            setSelectedRange(span)
            scrollRangeToVisible(span)
        }
        return true
    }

    /// find：匹配全部锚在权威 source（含 frontmatter/ref 等不可见范围，
    /// NE-23）。大小写/变音不敏感，与 source 模式搜索一致。
    public func sourceMatches(for query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = source as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.length > 0 {
            let found = ns.range(
                of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
            if found.location == NSNotFound { break }
            ranges.append(found)
            let next = found.location + max(found.length, 1)
            if next >= ns.length { break }
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        return ranges
    }

    /// source 区间 → display 区间（同块端点经投影映射；负值/未映射按
    /// 无位置处理）。跨块区间返回 nil——跨块高亮不显示，替换不受影响。
    public func displayRange(forSourceRange range: NSRange) -> NSRange? {
        rebuildProjection()
        for item in rendered {
            guard range.location >= item.block.rangeUTF16.location,
                NSMaxRange(range) <= NSMaxRange(item.block.rangeUTF16)
            else { continue }
            func mapped(_ offset: Int) -> Int? {
                guard let value = item.projection.displayOffset(forSource: offset), value >= 0 else {
                    return nil
                }
                return item.displayStart + value
            }
            switch (mapped(range.location), mapped(NSMaxRange(range))) {
            case let (start?, end?):
                return NSRange(location: min(start, end), length: abs(end - start))
            case let (start?, nil):
                return NSRange(location: start, length: 0)
            case let (nil, end?):
                return NSRange(location: max(end - 1, item.displayStart), length: 0)
            case (nil, nil):
                continue
            }
        }
        return nil
    }

    /// 跳转并选中一个 source 匹配（display 映射失败时退化为纯选中）。
    @discardableResult
    public func reveal(sourceRange: NSRange) -> Bool {
        let display =
            displayRange(forSourceRange: sourceRange)
            ?? NSRange(location: min(selectedRange().location, (string as NSString).length), length: 0)
        setSelectedRange(display)
        scrollRangeToVisible(display)
        return true
    }

    /// replace-next：替换 caret 起第一个匹配（无则回绕到首个），单 patch
    /// 单条历史。
    @discardableResult
    public func replaceNextMatch(query: String, replacement: String) -> Int {
        guard isEditable, !hasMarkedText(), !query.isEmpty else { return 0 }
        rebuildProjection()
        let matches = sourceMatches(for: query)
        guard !matches.isEmpty else { return 0 }
        let caret = sourceCaret()
        let target = matches.first(where: { $0.location >= caret }) ?? matches[0]
        let ns = source as NSString
        let patch = SourcePatch(
            rangeUTF16: target, expectedText: ns.substring(with: target), replacement: replacement)
        guard
            applyStructurePatches(
                [patch], name: "find-replace",
                restoreSourceCaret: target.location + (replacement as NSString).length,
                origin: .format)
        else { return 0 }
        return 1
    }

    /// replace-all：全部匹配一次原子事务（一条历史、一次 revision 推进，
    /// NE-23"一次可撤销事务"）。大小写不敏感匹配按实际命中字节构造
    /// expectedText，不改写任何非匹配范围。
    @discardableResult
    public func replaceAllMatches(query: String, replacement: String) -> Int {
        guard isEditable, !hasMarkedText(), !query.isEmpty else { return 0 }
        rebuildProjection()
        let matches = sourceMatches(for: query)
        guard !matches.isEmpty else { return 0 }
        let ns = source as NSString
        let patches = matches.map {
            SourcePatch(rangeUTF16: $0, expectedText: ns.substring(with: $0), replacement: replacement)
        }
        let caretBefore = sourceCaret()
        guard
            applyStructurePatches(
                patches, name: "find-replace-all",
                restoreSourceCaret: caretBefore, origin: .format)
        else { return 0 }
        return matches.count
    }

    /// 整篇替换（format 通道）：单条历史、单步撤销；caret 按传入 source
    /// 偏移恢复（未传保持当前 caret 的 source 位置，越界 clamp）。
    @discardableResult
    public func applyWholeSourceReplacement(
        _ newSource: String, name: String, caretSourceOffset: Int? = nil
    ) -> Bool {
        guard isEditable, !hasMarkedText(), newSource != source else { return false }
        let ns = source as NSString
        let patch = SourcePatch(
            rangeUTF16: NSRange(location: 0, length: ns.length),
            expectedText: source, replacement: newSource)
        let caretBefore = min(caretSourceOffset ?? sourceCaret(), newSource.utf16.count)
        return applyStructurePatches(
            [patch], name: name, restoreSourceCaret: caretBefore, origin: .format)
    }

    /// preview checkbox intent：精确 span 翻转（期望字节失配拒绝 = stale
    /// render 防护）。caret 原位保持——preview 交互不得移动编辑光标。
    @discardableResult
    public func applyTaskTogglePatch(
        sourceRange: NSRange, expectedOld: String, replacement: String
    ) -> Bool {
        guard isEditable else { return false }
        rebuildProjection()
        let ns = source as NSString
        guard NSMaxRange(sourceRange) <= ns.length,
            ns.substring(with: sourceRange) == expectedOld
        else { return false }
        let patch = SourcePatch(
            rangeUTF16: sourceRange, expectedText: expectedOld, replacement: replacement)
        return applyStructurePatches(
            [patch], name: "task-toggle-preview", restoreSourceCaret: sourceCaret(),
            origin: .previewIntent)
    }

}
