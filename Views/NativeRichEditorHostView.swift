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

    /// 装载失败回调（T10 降级路径，NE-36）：磁盘读取失败的笔记由调用方
    /// 仅对当前笔记回 source 显示；全局 layout pref 不动。
    var onNoteLoadFailure: ((Note) -> Void)?

    private var lastLoadedMarkdown: String?
    private var hasUnsavedChanges = false
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
        // RichMarkdownTextView 自带 textContainer（widthTracksTextView=false）
        scrollView.documentView = textView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        textView.onSourceCommitted = { [weak self] source in
            self?.handleSourceCommitted(source)
        }

        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - WysiwygEditingBackend

    public func loadNote(_ note: Note) {
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
        let size = CGFloat(UserDefaultsManagement.fontSize)
        textView.bodyFont =
            NSFont(name: UserDefaultsManagement.fontName, size: size)
            ?? NSFont.systemFont(ofSize: size)
        textView.codeFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        textView.refreshFontAttributes()

        let isDark = AppEnvironment.current.userData.isDark
        // drawBackground=false：背景由 VC 编辑区统一着色，与 EditTextView
        // 行为一致（NE-32 主题切换只换前景/光标）。
        textView.drawsBackground = false
        textView.insertionPointColor = isDark ? .white : .black
        textView.contentTextColor = isDark ? NSColor.white : NSColor.black
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
}
