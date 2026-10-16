import Cocoa

// MARK: - T06 单一语义历史接线（EditTextView extension）
//
// 保证 NSTextView 内置 undo 与 MarkdownEditorHistory 不重复登记：
// - 编辑器面允许 view 自动 undo（allowsUndo = true），经
//   windowWillReturnUndoManager 路由到当前 note 的 UndoManager；
// - parse/theme/render 等程序化刷新必须经 withoutUndoRegistration 包裹，
//   防止把 view 刷新误登记为编辑；
// - MarkdownEditorHistory 的语义记录由 RichMarkdownTextView 等投影层
//   负责，与这里的 view 自动 undo 并存但作用于不同层次（source patch
//   vs textStorage 字符）；T10 统一宿主后由协调层收敛。
extension EditTextView {

    /// 程序化刷新（parse/theme/render/外部重载）期间禁止 undo 登记。
    /// 只包裹「当前 runloop 同步完成」的代码块；异步回调需自行包一层。
    func withoutUndoRegistration(_ block: () -> Void) {
        guard let undoManager = undoManager else {
            block()
            return
        }
        undoManager.disableUndoRegistration()
        block()
        undoManager.enableUndoRegistration()
    }

    /// 结束当前 typing group，下一次输入开始新 undo 单位。
    /// 在 selection change、结构命令、模式切换前调用。
    func breakTypingUndoGroup() {
        breakUndoCoalescing()
    }

    // MARK: - Text Replacement Helper
    func replaceText(_ text: String, in range: NSRange) {
        guard let textStorage = textStorage else { return }

        // Preserve text attributes when replacing
        let attributes = typingAttributes
        let attributedText = NSAttributedString(string: text, attributes: attributes)

        textStorage.replaceCharacters(in: range, with: attributedText)

        // Trigger layout update and change notification
        if let tc = textContainer {
            layoutManager?.ensureLayout(for: tc)
        }
        didChangeText()
    }
}
