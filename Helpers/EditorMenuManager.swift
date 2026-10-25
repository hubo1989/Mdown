import Cocoa

@MainActor
class EditorMenuManager {
    private weak var textView: EditTextView?

    init(textView: EditTextView) {
        self.textView = textView
    }

    private func ensureSourceModeForEditing() {
        guard let vc = ViewController.shared() else { return }
        if vc.sessionLayoutMode == .wysiwyg {
            vc.sessionLayoutMode = .source
            UserDefaultsManagement.editorLayoutMode = .source
            vc.applyEditorModePreferenceChange()
        }
    }

    /// T14：native rich 是否为当前正文活动面（可见、持有选中笔记、
    /// textView 持有焦点）。命令 adapter 的路由前提。
    private func activeRichHost() -> NativeRichEditorHostView? {
        guard let vc = ViewController.shared(),
            let note = EditTextView.note,
            vc.sessionLayoutMode == .wysiwyg,
            let host = vc.activeWysiwygBackend as? NativeRichEditorHostView,
            !host.isHidden,
            host.currentNote === note,
            host.window?.firstResponder === host.textView
        else { return nil }
        return host
    }

    /// T14：native rich 活动时命令经 adapter 走 rich source patch；
    /// legacy Vditor 与 source 布局保留既有路径（force-source + TextFormatter）。
    private func performViaAdapter(
        _ command: MarkdownEditorCommandAdapter.Command
    ) -> Bool {
        guard let host = activeRichHost(), let note = EditTextView.note else { return false }
        let env = MarkdownEditorCommandAdapter.Environment(
            surface: .nativeRich(host),
            selectedNote: note,
            contentEditingForbidden: false
        )
        let target = MarkdownEditorCommandAdapter.resolve(command, in: env)
        return MarkdownEditorCommandAdapter.perform(command, on: target)
    }

    func performFormattingAction(_ action: FormattingAction) {
        guard textView != nil,
            let vc = ViewController.shared(),
            let editArea = vc.editArea,
            let note = EditTextView.note,
            !vc.sessionPreviewMode,
            !vc.sessionPresentationMode,
            !vc.sessionMagicPPTMode
        else { return }

        // T14：native rich 活动面优先——内容命令作用当前会话，不再把
        // 用户踢回 source 模式（NE-24）。
        if performViaAdapter(action.adapterCommand) { return }

        if vc.sessionLayoutMode == .wysiwyg {
            ensureSourceModeForEditing()
        }

        guard editArea.hasFocus() else { return }

        let formatter = TextFormatter(textView: editArea, note: note, shouldScanMarkdown: action.shouldScanMarkdown)

        switch action {
        case .bold:
            formatter.bold()
        case .italic:
            formatter.italic()
        case .link:
            formatter.link()
        case .todo:
            formatter.toggleTodo()
        case .underline:
            formatter.underline()
        case .deleteline:
            formatter.deleteline()
        case .inlineCode:
            formatter.backTick()
        case .codeBlock:
            formatter.codeBlock()
        }
    }

    func insertCodeBlock() {
        if performViaAdapter(.codeBlock) { return }
        ensureSourceModeForEditing()
        guard let textView = textView else { return }

        let currentRange = textView.selectedRange()

        if currentRange.length > 0 {
            let mutable = NSMutableAttributedString(string: "```\n")
            if let substring = textView.attributedSubstring(forProposedRange: currentRange, actualRange: nil) {
                mutable.append(substring)

                if substring.string.last != Character("\n") {
                    mutable.append(NSAttributedString(string: "\n"))
                }
            }

            mutable.append(NSAttributedString(string: "```\n"))

            EditTextView.shouldForceRescan = true
            textView.insertText(mutable, replacementRange: currentRange)
            textView.setSelectedRange(NSRange(location: currentRange.location + 3, length: 0))
            return
        }

        if textView.textStorage?.length == 0 {
            EditTextView.shouldForceRescan = true
        }

        textView.insertText("```\n\n```\n", replacementRange: currentRange)
        textView.setSelectedRange(NSRange(location: currentRange.location + 3, length: 0))
    }

    func insertCodeSpan() {
        if performViaAdapter(.inlineCode) { return }
        ensureSourceModeForEditing()
        guard let textView = textView else { return }

        let currentRange = textView.selectedRange()

        if currentRange.length > 0 {
            let mutable = NSMutableAttributedString(string: "`")
            if let substring = textView.attributedSubstring(forProposedRange: currentRange, actualRange: nil) {
                mutable.append(substring)
            }

            mutable.append(NSAttributedString(string: "`"))

            EditTextView.shouldForceRescan = true
            textView.insertText(mutable, replacementRange: currentRange)
            return
        }

        textView.insertText("``", replacementRange: currentRange)
        textView.setSelectedRange(NSRange(location: currentRange.location + 1, length: 0))
    }

    func insertFileOrImage() {
        // T14：native rich 活动时附件走 rich 的锚定异步写入（T13 通道），
        // 不再强制回 source 模式。
        if let host = activeRichHost() {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.canCreateDirectories = true

            panel.begin { result in
                guard result == NSApplication.ModalResponse.OK else { return }
                for url in panel.urls {
                    _ = host.textView.importAttachment(.file(url))
                }
            }
            return
        }

        ensureSourceModeForEditing()
        guard let note = EditTextView.note else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = true

        panel.begin { result in
            if result == NSApplication.ModalResponse.OK {
                self.handleFileSelection(urls: panel.urls, note: note)
            }
        }
    }

    private func handleFileSelection(urls: [URL], note: Note) {
        guard let textView = textView else { return }

        let clipboardManager = ClipboardManager(textView: textView)
        let last = urls.last

        for url in urls {
            if clipboardManager.saveFile(url: url, in: note) {
                if last != url {
                    textView.insertNewline(nil)
                    if let vc = ViewController.shared() {
                        vc.notesTableView.reloadRow(note: note)
                    }
                }
            }

            if url != urls.last {
                textView.insertNewline(nil)
            }
        }
    }

    func togglePreview() {
        guard let vc = ViewController.shared() else { return }
        vc.togglePreview()
    }

    func formatText() {
        // 不做 ensureSourceModeForEditing 强切:vc.formatText 自身按
        // 布局分流(preview toast / rich 事务 / source 排版),强切会
        // 把 wysiwyg 用户先踢回 source 再格式化隐藏 buffer(并把持久
        // 偏好改写为 source)。非 wysiwyg 时强切本就是 no-op,去掉无
        // 行为变化;与同文件 insertCodeBlock 等的 rich 路由先例对齐
        // (T14 NE-24,PR #10 review F1)。
        guard let vc = ViewController.shared() else { return }
        vc.formatText()
    }

    func cleanTypography() {
        ensureSourceModeForEditing()
        guard let vc = ViewController.shared() else { return }
        vc.cleanTypography(nil)
    }

    func togglePresentation() {
        guard let vc = ViewController.shared() else { return }
        vc.togglePresentation()
    }

    func toggleTOC() {
        guard let vc = ViewController.shared() else { return }
        vc.toggleTOC(self)
    }
}

enum FormattingAction {
    case bold
    case italic
    case link
    case todo
    case underline
    case deleteline
    case inlineCode
    case codeBlock

    var shouldScanMarkdown: Bool {
        switch self {
        case .todo:
            return false
        default:
            return true
        }
    }

    /// T14：adapter 注册表里的同一命令（路由分流共用一套语义）。
    var adapterCommand: MarkdownEditorCommandAdapter.Command {
        switch self {
        case .bold: return .bold
        case .italic: return .italic
        case .link: return .link
        case .todo: return .todo
        case .underline: return .underline
        case .deleteline: return .deleteline
        case .inlineCode: return .inlineCode
        case .codeBlock: return .codeBlock
        }
    }
}
