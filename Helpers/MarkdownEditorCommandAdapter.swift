import Foundation

// MARK: - T14 命令 adapter（SPEC §8.3 / NE-23 / NE-24 / NE-28 / AC-14）
//
// 全部正文内容命令的注册表与路由：toolbar、菜单（First Responder）、
// TextFormatter、快捷模板、preview task intent 一律经本层分发，命令只作用
// 活动会话面（native rich 的权威 source 或 source 布局的编辑器 buffer）。
// 禁止把 rich 的 display 坐标喂给 TextFormatter 的 NSRange 路径，也禁止在
// preview / presentation 下改隐藏 view——解析不了路由就显式拒绝。
//
// 路由判定只看注入的 Environment 值快照（可脱离 ViewController 单测）；
// 调用方（EditorMenuManager / ViewController）负责从会话状态提取快照。

@MainActor
enum MarkdownEditorCommandAdapter {

    /// 内容命令注册表。新增内容命令必须在此列名并实现对应路由
    /// (rich / source),不允许旁路直写存储。T22 后 legacy Vditor 路由随依赖移除。
    enum Command {
        case bold
        case italic
        case underline
        case deleteline
        case inlineCode
        case codeBlock
        case link
        case todo
        case insertShortcutTemplate(String)

        static var allCases: [Command] {
            [
                .bold, .italic, .underline, .deleteline, .inlineCode,
                .codeBlock, .link, .todo,
                .insertShortcutTemplate("time"), .insertShortcutTemplate("table"),
                .insertShortcutTemplate("img"), .insertShortcutTemplate("video"),
                .insertShortcutTemplate("markmap"), .insertShortcutTemplate("mermaid"),
                .insertShortcutTemplate("plantuml"), .insertShortcutTemplate("fold"),
                .insertShortcutTemplate("task"),
            ]
        }
    }

    enum RefusalReason: Equatable {
        /// preview / presentation / PPT 等只读展示模式
        case contentModeForbidden
        /// 没有可定位的活动会话面
        case noActiveSurface
        /// 活动面持有的笔记与选中笔记失配（#543 防护语义）
        case noteIdentityMismatch
    }

    enum RoutingTarget {
        /// native rich 是活动正文面：命令经 rich source patch 应用
        case rich(RichMarkdownTextView)
        /// source 布局：命令经 TextFormatter 在编辑器 buffer 上应用
        /// （同缓冲区坐标，非跨坐标调用）
        case sourceEditor(EditTextView, note: Note)
        case refused(RefusalReason)
    }

    /// 从会话状态提取的路由环境（VC 侧构建，测试侧手工构造）。
    struct Environment {
        enum Surface {
            case nativeRich(NativeRichEditorHostView)
            case sourceEditor(EditTextView, note: Note)
        }

        let surface: Surface
        /// 当前选中的笔记（身份核对基准；nil 表示无选中）。
        let selectedNote: Note?
        /// preview / presentation / PPT 等内容编辑禁止态。
        let contentEditingForbidden: Bool
    }

    /// 路由判定：命令 → 目标。判定规则与具体命令无关（坐标互用防护在
    /// perform 内按目标分流实现）。
    static func resolve(_ command: Command, in env: Environment) -> RoutingTarget {
        if env.contentEditingForbidden {
            return .refused(.contentModeForbidden)
        }
        switch env.surface {
        case .nativeRich(let host):
            guard let selected = env.selectedNote, host.currentNote === selected
            else {
                return .refused(.noteIdentityMismatch)
            }
            return .rich(host.textView)
        case .sourceEditor(let editor, let note):
            guard let selected = env.selectedNote, note === selected else {
                return .refused(.noteIdentityMismatch)
            }
            return .sourceEditor(editor, note: note)
        }
    }

    /// 在路由目标上执行命令。返回 false 表示目标拒绝（拒绝方回退 /
    /// 提示），不静默改写其它面。
    @discardableResult
    static func perform(_ command: Command, on target: RoutingTarget) -> Bool {
        switch target {
        case .rich(let view):
            return performOnRich(command, view: view)
        case .sourceEditor(let editor, let note):
            return performOnSourceEditor(command, editor: editor, note: note)
        case .refused:
            return false
        }
    }

    private static func performOnRich(_ command: Command, view: RichMarkdownTextView) -> Bool {
        switch command {
        case .bold:
            return view.applyInlineFormat(.strong)
        case .italic:
            return view.applyInlineFormat(.emphasis)
        case .deleteline:
            return view.applyInlineFormat(.strikethrough)
        case .inlineCode:
            return view.applyInlineFormat(.code)
        case .underline:
            return view.insertUnderlineCommand()
        case .link:
            return view.insertLinkCommand()
        case .todo:
            return view.toggleTodoCommand()
        case .codeBlock:
            return view.insertCodeBlockCommand()
        case .insertShortcutTemplate(let name):
            return view.insertShortcutTemplate(name)
        }
    }

    private static func performOnSourceEditor(
        _ command: Command, editor: EditTextView, note: Note
    ) -> Bool {
        let formatter = TextFormatter(textView: editor, note: note)
        switch command {
        case .bold:
            formatter.bold()
        case .italic:
            formatter.italic()
        case .deleteline:
            formatter.deleteline()
        case .inlineCode:
            formatter.backTick()
        case .underline:
            formatter.underline()
        case .link:
            formatter.link()
        case .todo:
            formatter.toggleTodo()
        case .codeBlock:
            formatter.codeBlock()
        case .insertShortcutTemplate(let name):
            let range = editor.selectedRange()
            editor.insertText(
                NSAttributedString(string: "/" + name), replacementRange: range)
        }
        return true
    }
}

// MARK: - preview task intent（NE-28：JS renderer 只发有限 intent）

/// preview checkbox 点击的有限 payload。只接受结构化三元组，不接受任何
/// Markdown 全文或可变 range。
struct PreviewTaskIntentPayload: Equatable {
    let index: Int
    let expectedChecked: Bool
    /// 页面持有的渲染代（原生 stamp 进 window.miaoyanRenderGeneration）。
    /// 缺失 = 无法证明新鲜，应用层直接拒绝。
    let renderGeneration: UInt64?
}

enum PreviewTaskIntentRejection: Equatable, Error {
    case notMainFrame
    case modeForbidden
    case staleRender
    case staleContent
    case indexOutOfRange
    case noEditableSurface
    case noteMismatch
    case readOnly
}

/// 一次已校验的 task 翻转：权威 source 上的精确 span 与期望字节。
struct PreviewTaskTogglePlan: Equatable {
    let sourceRange: NSRange
    let expectedOld: String
    let replacement: String
}

/// preview checkbox 点击的校验与 span 规划。全部在 MainActor 上运行
/// （regex 常量与 parser 均为主线程面）。
@MainActor
enum PreviewTaskIntent {

    /// 渲染源 digest(djb2,稳定与 Swift 版本无关):渲染成功时记录,
    /// intent 到达时对活动面笔记重算比对——渲染后内容漂移即拒绝。
    nonisolated static func sourceDigest(_ source: String) -> UInt64 {
        var hash: UInt64 = 5381
        for scalar in source.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        return hash
    }

    /// 解析 JS 消息体。仅接受 [String: Any] 的 {index:Int≥0, checked:Bool,
    /// generation:Int|nil}。纯解析，nonisolated。
    nonisolated static func parsePayload(_ body: Any) -> PreviewTaskIntentPayload? {
        guard let dict = body as? [String: Any],
            let index = dict["index"] as? Int, index >= 0,
            let checked = dict["checked"] as? Bool
        else { return nil }
        let generation = (dict["generation"] as? NSNumber)?.uint64Value
        return PreviewTaskIntentPayload(
            index: index, expectedChecked: checked, renderGeneration: generation)
    }

    /// 在权威 source 上定位第 index 个 task item 并核对期望 state。
    /// 枚举与 cmark 的 DOM checkbox 序号对齐:只有行首(允许缩进/quote
    /// 前缀)的 list marker task 才计数——用 MarkdownBlockModel.parseLine
    /// 逐行判定,而非全局 regex(行中/内联 HTML 里的 `- [x] ` 字面不渲染
    /// 成 checkbox,计入会漂移甚至被伪造行顶掉真实序号)。保护块
    /// (code/math/HTML/frontmatter/table/heading)整块跳过。
    static func planToggle(
        in source: String, index: Int, expectedChecked: Bool
    ) -> Result<PreviewTaskTogglePlan, PreviewTaskIntentRejection> {
        guard index >= 0 else { return .failure(.indexOutOfRange) }
        let document = LosslessMarkdownParser().parse(source)
        let ns = source as NSString
        var ordinal = 0
        for block in document.blocks {
            switch block.kind {
            case .codeFence, .codeIndented, .htmlBlock, .mathBlock,
                .frontmatter, .table, .heading, .thematicBreak, .blank:
                continue
            case .paragraph, .listItem, .quote:
                break
            }
            var lineLoc = block.rangeUTF16.location
            let blockEnd = NSMaxRange(block.rangeUTF16)
            while lineLoc < blockEnd {
                let lineRange = ns.lineRange(for: NSRange(location: lineLoc, length: 0))
                guard NSMaxRange(lineRange) <= blockEnd else { break }
                if let task = MarkdownBlockModel.parseLine(ns, lineRange: lineRange).task {
                    if ordinal == index {
                        // 括号字面 `[x]`/`[ ]`(dash 与 ordered task 统一)
                        let span = NSRange(location: task.checkOffsetUTF16 - 1, length: 3)
                        guard span.location >= 0, NSMaxRange(span) <= ns.length else {
                            return .failure(.indexOutOfRange)
                        }
                        let current = ns.substring(with: span)
                        guard task.checked == expectedChecked else {
                            return .failure(.staleContent)
                        }
                        return .success(
                            PreviewTaskTogglePlan(
                                sourceRange: span, expectedOld: current,
                                replacement: task.checked ? "[ ]" : "[x]"))
                    }
                    ordinal += 1
                }
                lineLoc = NSMaxRange(lineRange)
            }
        }
        return .failure(.indexOutOfRange)
    }
}

/// intent 应用：先原生校验（frame / 模式 / 代 / 身份 / 只读 / 内容新鲜），
/// 再经活动会话面以 source patch 翻转。任何防线不过即拒绝，零写入。
@MainActor
enum PreviewTaskIntentApplier {

    struct Context {
        enum Surface {
            case rich(NativeRichEditorHostView)
            case sourceEditor(EditTextView, Note)
        }

        var surface: Surface?
        /// preview 当前显示的笔记（来自原生 displayedNote，不信 JS）。
        var displayedNote: Note
        /// 本次渲染完成时记录的笔记与渲染源 digest(SPEC §9 displayed
        /// identity/revision 校验):intent 到达时两者任一落后即拒绝。
        var renderedNote: Note
        var renderedSourceDigest: UInt64
        /// preview 当前的渲染代。
        var currentRenderGeneration: UInt64
        /// presentation / PPT 下 checkbox 只是展示，禁改。
        var interactivePreviewAllowed: Bool
        /// WKFrameInfo.isMainFrame；子 frame 一律拒绝。
        var isMainFrame: Bool
    }

    /// 返回 nil = 应用成功；否则给出拒绝原因（调用方据此提示并刷新
    /// preview 以回滚 JS 侧的乐观翻转）。
    @discardableResult
    static func apply(
        _ payload: PreviewTaskIntentPayload, in context: Context
    ) -> PreviewTaskIntentRejection? {
        guard context.isMainFrame else { return .notMainFrame }
        guard context.interactivePreviewAllowed else { return .modeForbidden }
        guard let generation = payload.renderGeneration,
            generation == context.currentRenderGeneration
        else { return .staleRender }
        // 渲染快照身份:渲染对象不是当前笔记(切换中/过期显示)拒绝;
        // 渲染后内容漂移(用户继续输入)拒绝——digest 对渲染源口径
        // (getPrettifiedContent)重算,与渲染时记录值比对。
        guard context.renderedNote === context.displayedNote else { return .staleRender }
        let currentDigest = PreviewTaskIntent.sourceDigest(
            context.displayedNote.getPrettifiedContent())
        guard currentDigest == context.renderedSourceDigest else { return .staleRender }
        guard let surface = context.surface else { return .noEditableSurface }
        guard !context.displayedNote.project.isTrash else { return .readOnly }

        switch surface {
        case .rich(let host):
            guard host.currentNote === context.displayedNote else { return .noteMismatch }
            let source = host.textView.source
            switch PreviewTaskIntent.planToggle(in: source, index: payload.index, expectedChecked: payload.expectedChecked) {
            case .failure(let reason):
                return reason
            case .success(let plan):
                let applied = host.textView.applyTaskTogglePatch(
                    sourceRange: plan.sourceRange,
                    expectedOld: plan.expectedOld,
                    replacement: plan.replacement)
                return applied ? nil : .staleContent
            }
        case .sourceEditor(let editor, let owner):
            guard owner === context.displayedNote else { return .noteMismatch }
            guard let storage = editor.textStorage else { return .noEditableSurface }
            let buffer = storage.string
            switch PreviewTaskIntent.planToggle(in: buffer, index: payload.index, expectedChecked: payload.expectedChecked) {
            case .failure(let reason):
                return reason
            case .success(let plan):
                // 经 NSTextView 编辑路径（shouldChangeText/didChangeText），
                // 与键入同语义地进 session/保存协调，不绕过 buffer 直写 Note。
                guard NSMaxRange(plan.sourceRange) <= storage.length,
                    storage.attributedSubstring(from: plan.sourceRange).string == plan.expectedOld
                else { return .staleContent }
                editor.insertText(
                    NSAttributedString(
                        string: plan.replacement,
                        attributes: storage.attributes(at: plan.sourceRange.location, effectiveRange: nil)),
                    replacementRange: plan.sourceRange)
                return nil
            }
        }
    }
}

extension MarkdownEditorCommandAdapter {
    /// 快捷模板的 rich 活动面前提（EditTextView.insertShortcutText 用）。
    /// 命中时直接插入 `/shortcut` 并返回 true；不命中由调用方走 legacy 路径。
    @discardableResult
    static func richShortcutInsertTarget(for editor: EditTextView, shortcut: String) -> Bool {
        guard
            let vc = editor.window?.contentViewController as? ViewController
                ?? AppContext.shared.viewController,
            vc.sessionLayoutMode == .wysiwyg,
            let host = vc.activeWysiwygBackend as? NativeRichEditorHostView,
            !host.isHidden,
            host.currentNote === EditTextView.note,
            host.window?.firstResponder === host.textView
        else { return false }
        return host.textView.insertShortcutTemplate(shortcut)
    }
}
