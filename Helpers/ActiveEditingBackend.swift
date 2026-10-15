/// T01 临时 adapter：Cmd+S / windowWillClose / applicationWillTerminate
/// 这三个硬保存点必须从「活动编辑后端」采集 buffer，不能无条件读
/// source 编辑器的 textStorage——wysiwyg 模式下用户输入在 Vditor，
/// textStorage 停留在切换时的旧内容，owner 匹配也照样覆盖
/// `Note.content` 里的新输入（v1 覆盖 v2）。
///
/// 临时标记：T05~T08 由 MarkdownEditingSession / EditingTransitionCoordinator
/// 收敛统一入口后删除本文件，不允许两套保存逻辑长期并存。
@MainActor
enum ActiveEditingBackend {
    /// 硬保存点采集：wysiwyg 活动时 Vditor 是权威（`vditorChange` 已把
    /// 最新内容即时写进 `Note.content`，这里只需把 0.5s debounce 提前
    /// 落盘）；否则从 source 编辑器 buffer 采集（沿用 owner guard）。
    static func captureBuffer(
        for note: Note,
        sourceEditor: EditTextView,
        vditorView: VditorEditView?,
        isWysiwygActive: Bool
    ) {
        if isWysiwygActive {
            vditorView?.flushPendingSave()
        } else {
            sourceEditor.saveTextStorageContent(to: note)
        }
    }

    /// 硬保存点的目标 note：wysiwyg 活动时以 Vditor 的 currentNote 为准。
    static func activeNote(
        sourceNote: Note?,
        vditorView: VditorEditView?,
        isWysiwygActive: Bool
    ) -> Note? {
        if isWysiwygActive, let current = vditorView?.currentNote {
            return current
        }
        return sourceNote
    }
}
