import AppKit

// MARK: - T10 native rich host（PLAN / SPEC NE-01 / NE-32 / NE-36）
//
// wysiwyg 布局的 native 正文后端：NSScrollView + RichMarkdownTextView 宿主，
// 与 legacy VditorEditView 实现同一 `WysiwygEditingBackend` 协议面，布局层
// （enableWysiwygMode / 采集面 / flush 点）只经 activeWysiwygBackend 触达，
// 不感知具体 backend。
//
// 保存语义与 Vditor 对齐（AC-22：无新保存定时器类型）：
// - source 提交（RichMarkdownTextView.onSourceCommitted）即时镜像进
//   note.content（预览/离开点采集读镜像，不等 debounce）；
// - 0.5s debounce 后落盘，切换笔记 / flushPendingSave / prepareExit 前先落盘
//   旧草稿（NE-36：不丢草稿）；
// - 装载竞态经 loadToken 守护：晚到的异步装载不得写进刚切换的 currentNote。
//
// 投影编辑的逐键 session 事务（EditTransaction 应用进 MarkdownEditingSession）
// 是 T11 职责；T10 阶段 native 面的正文权威是本 host 镜像的 note.content，
// 与 Vditor 现状同级，不经并行通道。
@MainActor
public final class NativeRichEditorHostView: NSView, WysiwygEditingBackend {

    public private(set) var textView: RichMarkdownTextView
    public private(set) weak var currentNote: Note?

    public override var isHidden: Bool {
        didSet {
            if isHidden { textView.invalidateAttachmentRequests() }
        }
    }

    /// 装载失败回调（T10 降级路径，NE-36）：磁盘读取失败的笔记由调用方
    /// 仅对当前笔记回 source 显示；全局 layout pref 不动。
    var onNoteLoadFailure: ((Note) -> Void)?

    private var lastLoadedMarkdown: String?
    private(set) var hasUnsavedChanges = false  // 测试观察口:flush 后应为 false
    private var saveWorkItem: DispatchWorkItem?
    /// 装载身份：每次 loadNote 自增；异步装载完成核对，晚到拒绝。
    private var loadToken: UInt64 = 0
    /// 进 preview / 切模式前保存的 selection 锚点（AC-16 退出回原布局）。
    /// 与笔记身份绑定：切到其它笔记后旧锚点不得恢复到新正文。
    private var selectionAnchor: (owner: ObjectIdentifier, range: NSRange)?

    private let scrollView = NSScrollView()

    public override init(frame frameRect: NSRect) {
        textView = RichMarkdownTextView(source: "")
        super.init(frame: frameRect)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        textView.onSourceCommitted = { [weak self] source in
            guard let self else { return }
            self.handleSourceCommitted(source)
            // T14：查找进行中时编辑后重跑（投影重建清掉临时高亮）。
            if self.editorSearchBar != nil, !self.currentSearchQuery.isEmpty {
                self.runSearch(self.currentSearchQuery, jumpToFirstMatch: false)
            }
        }

        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func layout() {
        super.layout()
        let viewport = scrollView.contentSize
        textView.minSize = NSSize(width: 0, height: viewport.height)
        if textView.frame.width != viewport.width || textView.frame.height < viewport.height {
            textView.setFrameSize(NSSize(width: viewport.width, height: max(textView.frame.height, viewport.height)))
        }
    }

    // MARK: - WysiwygEditingBackend

    public func loadNote(_ note: Note) {
        textView.invalidateAttachmentRequests()
        // 旧笔记的未保存草稿先落盘（与 Vditor loadNote 一致：纯浏览切换
        // 不得写盘，有编辑才写）。
        if let outgoing = currentNote, hasUnsavedChanges {
            saveWorkItem?.cancel()
            saveWorkItem = nil
            persistNote(outgoing)
        } else {
            saveWorkItem?.cancel()
            saveWorkItem = nil
        }
        hasUnsavedChanges = false

        currentNote = note
        // 立即作废旧装载身份：晚到的异步装载不得写进新 currentNote。
        loadToken += 1

        let isTrashNote = note.project.isTrash
        textView.isEditable = !isTrashNote
        textView.isSelectable = true

        if note.isContentLoaded {
            applyNote(note)
        } else {
            let token = loadToken
            Task { @MainActor [weak self] in
                await note.ensureContentLoadedAsync()
                guard let self = self, self.currentNote === note else { return }
                if note.isContentLoaded {
                    self.applyContentLoaded(note, token: token)
                } else {
                    // 磁盘读取失败：只对当前笔记回 source（NE-36），调用方
                    // 决定显示面，不改全局 pref。
                    self.onNoteLoadFailure?(note)
                }
            }
        }
    }

    public func flushPendingSave(completion: (() -> Void)? = nil) {
        saveWorkItem?.cancel()
        saveWorkItem = nil

        guard hasUnsavedChanges, let note = currentNote else {
            completion?()
            return
        }
        persistNote(note)
        completion?()
    }

    public func focus() {
        window?.makeFirstResponder(textView)
    }

    public func updateAppearance() {
        applyAppearance()
    }

    // MARK: - 装载

    /// 装载正文进投影。程序化 setSource 触发的 onSourceCommitted 由
    /// lastLoadedMarkdown 守卫丢弃，不产生假编辑。
    private func applyNote(_ note: Note) {
        let markdown = note.content.string
        lastLoadedMarkdown = markdown
        textView.setSource(markdown)
        let token = loadToken
        let url = note.url
        let generation = note.editGeneration
        textView.configureAttachmentOwner(url: url) { [weak self, weak note] in
            guard let self, let note else { return false }
            return self.currentNote === note && self.loadToken == token && !self.isHidden
                && !note.isRetiredForEditing && !note.project.isTrash
                && note.url == url && note.editGeneration == generation
                && FileManager.default.fileExists(atPath: url.path)
        }
        textView.onAttachmentFinished = { [weak self] result in
            if case .failure = result {
                self?.getViewController()?.toast(message: I18n.str("Attachment could not be inserted. Please try again."), style: .info)
            }
        }
        restoreSelectionAnchor()
    }

    /// 装载身份核对入口（Task 回调与测试注入共用）。
    private func applyContentLoaded(_ note: Note, token: UInt64) {
        guard token == loadToken, currentNote === note else { return }
        applyNote(note)
    }

    private func handleSourceCommitted(_ source: String) {
        guard let note = currentNote, source != lastLoadedMarkdown else { return }
        lastLoadedMarkdown = source
        // 即时镜像：预览与离开点采集读 note.content，不得落后于输入。
        note.content = NSMutableAttributedString(string: source)
        hasUnsavedChanges = true

        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak note] in
            guard let self = self, let note = note else { return }
            self.persistNote(note)
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func persistNote(_ note: Note) {
        guard hasUnsavedChanges else { return }
        hasUnsavedChanges = false
        // 自己的写不得触发 watcher reload 循环（与 Vditor persistNote 一致）。
        getViewController()?.blockFSUpdates()
        note.save(content: note.content)
    }

    private func getViewController() -> ViewController? {
        if let vc = window?.contentViewController as? ViewController {
            return vc
        }
        return AppContext.shared.viewController
    }

    // MARK: - 外观（NE-32：字体/主题）

    private func applyAppearance() {
        // T19 预览对齐:WYSIWYG 使用预览的字体/字号(HtmlManager
        // previewStyle 注入 --text-font/--code-text-font 的同一来源),
        // 视觉与预览模式一致;编辑器字体仅作回退。
        let size = CGFloat(UserDefaultsManagement.previewFontSize)
        textView.bodyFont =
            NSFont(name: UserDefaultsManagement.previewFontName, size: size)
            ?? NSFont(name: UserDefaultsManagement.fontName, size: size)
            ?? NSFont.systemFont(ofSize: size)
        textView.codeFont =
            NSFont(name: UserDefaultsManagement.codeFontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)

        let isDark = AppEnvironment.current.userData.isDark
        // drawBackground=false：背景由 VC 编辑区统一着色，与 EditTextView
        // 行为一致（NE-32 主题切换只换前景/光标）。
        textView.drawsBackground = false
        // T19 顺序修复:先设颜色再刷新,refreshFontAttributes 用
        // contentTextColor 铺底,旧顺序(刷新在后)会先画默认黑再覆盖。
        // 文字色取预览的 --text-color(#262626/#E7E9EA),与预览模式一致。
        textView.contentTextColor = textView.previewTextColour
        textView.insertionPointColor = isDark ? .white : .black
        textView.refreshFontAttributes()
    }

    // MARK: - selection 锚点（AC-16：退出回原状态）

    /// 进 preview / presentation / PPT / 切布局前保存当前 selection。
    func saveSelectionAnchor() {
        guard let note = currentNote else { return }
        selectionAnchor = (ObjectIdentifier(note), textView.selectedRange())
    }

    /// 恢复保存的 selection（装载新投影后调用；同一笔记才恢复，否则回
    /// 文档头并清锚点）。
    func restoreSelectionAnchor() {
        guard let storage = textView.textStorage else { return }
        let length = storage.length
        if let anchor = selectionAnchor, let note = currentNote,
            anchor.owner == ObjectIdentifier(note)
        {
            let location = min(max(anchor.range.location, 0), length)
            let len = min(anchor.range.length, max(0, length - location))
            textView.setSelectedRange(NSRange(location: location, length: len))
            return
        }
        selectionAnchor = nil
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func clearSelectionAnchor() {
        selectionAnchor = nil
    }

    // MARK: - 测试注入面（竞态无法从真实 Task 精确编排）

    var currentLoadTokenForTesting: UInt64 { loadToken }

    func applyContentLoadedForTesting(_ note: Note, token: UInt64) {
        applyContentLoaded(note, token: token)
    }

    // MARK: - T14 查找/替换（NE-23：匹配锚在会话 source，一次可撤销事务）

    private var editorSearchBar: PreviewSearchBar?
    private var editorSearchBarConstraints: [NSLayoutConstraint] = []
    private(set) var currentSearchQuery = ""
    private var searchSourceRanges: [NSRange] = []
    private var searchCurrentIndex = 0

    var isSearchBarVisible: Bool { editorSearchBar != nil }

    func showSearchBar(prefilledText: String? = nil, mode: PreviewSearchBar.Mode = .find) {
        if editorSearchBar == nil {
            let bar = PreviewSearchBar(frame: .zero)
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.configureAppearance(baseColor: Theme.backgroundColor)
            bar.onSearch = { [weak self] text in
                self?.runSearch(text, jumpToFirstMatch: true)
            }
            bar.onNext = { [weak self] in self?.findNext() }
            bar.onPrevious = { [weak self] in self?.findPrevious() }
            bar.onReplace = { [weak self] replaceText in
                self?.replaceNext(with: replaceText)
            }
            bar.onReplaceAll = { [weak self] replaceText in
                self?.replaceAll(with: replaceText)
            }
            bar.onClose = { [weak self] in self?.hideSearchBar() }
            addSubview(bar, positioned: .above, relativeTo: scrollView)
            let heightConstraint = bar.heightAnchor.constraint(
                greaterThanOrEqualToConstant: (mode == .replace) ? 76 : 40)
            editorSearchBarConstraints = [
                bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
                bar.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
                heightConstraint,
            ]
            NSLayoutConstraint.activate(editorSearchBarConstraints)
            editorSearchBar = bar
        } else {
            editorSearchBarConstraints.last?.constant = (mode == .replace) ? 76 : 40
        }
        editorSearchBar?.setMode(mode)

        let seed = prefilledText ?? selectionSearchSeed()
        if let seed, !seed.isEmpty {
            editorSearchBar?.setSearchText(seed)
            runSearch(seed, jumpToFirstMatch: true)
        } else {
            editorSearchBar?.setSearchText("")
            runSearch("", jumpToFirstMatch: true)
        }
        layoutSubtreeIfNeeded()
        editorSearchBar?.focusSearchField()
    }

    func hideSearchBar(restoreFocus: Bool = true) {
        let hadBar = editorSearchBar != nil || !searchSourceRanges.isEmpty
        clearSearchHighlights()
        searchSourceRanges.removeAll()
        searchCurrentIndex = 0
        currentSearchQuery = ""
        editorSearchBar?.removeFromSuperview()
        editorSearchBar = nil
        NSLayoutConstraint.deactivate(editorSearchBarConstraints)
        editorSearchBarConstraints.removeAll()
        if hadBar, restoreFocus {
            window?.makeFirstResponder(textView)
        }
    }

    func findNext() {
        guard !searchSourceRanges.isEmpty else { return }
        searchCurrentIndex = (searchCurrentIndex + 1) % searchSourceRanges.count
        focusSearchResult(at: searchCurrentIndex)
        editorSearchBar?.updateMatchInfo(current: searchCurrentIndex + 1, total: searchSourceRanges.count)
    }

    func findPrevious() {
        guard !searchSourceRanges.isEmpty else { return }
        searchCurrentIndex =
            (searchCurrentIndex - 1 + searchSourceRanges.count) % searchSourceRanges.count
        focusSearchResult(at: searchCurrentIndex)
        editorSearchBar?.updateMatchInfo(current: searchCurrentIndex + 1, total: searchSourceRanges.count)
    }

    func useSelectionForFind() {
        guard let seed = selectionSearchSeed(), !seed.isEmpty else { return }
        if !isSearchBarVisible {
            showSearchBar(prefilledText: seed)
            return
        }
        editorSearchBar?.setSearchText(seed)
        runSearch(seed, jumpToFirstMatch: true)
    }

    func replaceNext(with replaceText: String) {
        guard !searchSourceRanges.isEmpty, !currentSearchQuery.isEmpty else { return }
        if textView.replaceNextMatch(query: currentSearchQuery, replacement: replaceText) > 0 {
            runSearch(currentSearchQuery, jumpToFirstMatch: false)
        }
    }

    func replaceAll(with replaceText: String) {
        guard !currentSearchQuery.isEmpty else { return }
        textView.replaceAllMatches(query: currentSearchQuery, replacement: replaceText)
        runSearch(currentSearchQuery, jumpToFirstMatch: false)
    }

    private func runSearch(_ query: String, jumpToFirstMatch: Bool) {
        currentSearchQuery = query
        clearSearchHighlights()
        guard !query.isEmpty else {
            searchSourceRanges = []
            searchCurrentIndex = 0
            editorSearchBar?.updateMatchInfo(current: 0, total: 0)
            return
        }
        searchSourceRanges = textView.sourceMatches(for: query)
        applySearchHighlights()
        guard !searchSourceRanges.isEmpty else {
            searchCurrentIndex = 0
            editorSearchBar?.updateMatchInfo(current: 0, total: 0)
            return
        }
        if jumpToFirstMatch || !searchSourceRanges.indices.contains(searchCurrentIndex) {
            searchCurrentIndex = 0
        }
        focusSearchResult(at: searchCurrentIndex)
        editorSearchBar?.updateMatchInfo(
            current: searchCurrentIndex + 1, total: searchSourceRanges.count)
    }

    private func focusSearchResult(at index: Int) {
        guard searchSourceRanges.indices.contains(index) else { return }
        textView.reveal(sourceRange: searchSourceRanges[index])
    }

    private func selectionSearchSeed() -> String? {
        guard let range = textView.commandSourceSelection(), range.length > 0 else { return nil }
        let ns = textView.source as NSString
        return ns.substring(with: range)
    }

    private func applySearchHighlights() {
        guard let layoutManager = textView.layoutManager else { return }
        let highlightColor = Theme.selectionBackgroundColor.withAlphaComponent(0.35)
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        guard full.length > 0 else { return }
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        for range in searchSourceRanges {
            if let display = textView.displayRange(forSourceRange: range), display.length > 0 {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: highlightColor, forCharacterRange: display)
            }
        }
    }

    private func clearSearchHighlights() {
        guard let layoutManager = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        guard full.length > 0 else { return }
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
    }
}
