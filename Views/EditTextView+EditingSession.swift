import Cocoa

// MARK: - T05 源码会话接线（EditTextView extension）
//
// publishStorage / saveTextStorageContent 的会话侧逻辑。主文件保留
// #543 的 owner guard 与保存搬运；这里只负责 identity/revision 防护：
// - 发布 = 登记新基线（同 URL 复用会话并提升代际，URL 变化新开会话）；
// - 保存 = 拒绝退役 note 与失效 buffer 的整篇写回。
// T07/T08 接入 commit/TransitionCoordinator 后由协调层收敛调用方。
extension EditTextView {

    /// 发布内容登记为源码会话新基线：同 URL 复用会话、replaceAll 提升
    /// 代际使旧任务/旧 buffer 身份失效；URL 变化新开会话。buffer revision
    /// 与会话 revision 对齐（模板/版本恢复等整篇调用点无需各自维护）。
    func syncEditingSession(with content: NSAttributedString, owner: Note?) {
        guard let owner = owner else {
            updateStorageRevision(0)
            return
        }
        if let session = editingSession, session.owns(url: owner.url) {
            session.replaceAll(markdown: content.string)
        } else {
            installEditingSession(
                MarkdownEditingSession(
                    identity: EditingIdentity(
                        ownerToken: UUID(), canonicalURL: owner.url, generation: 1
                    ),
                    markdown: content.string,
                    selection: MarkdownSelection(
                        anchorUTF16: 0, focusUTF16: 0, affinity: .downstream
                    ),
                    isReadOnly: false
                ))
        }
        editingSession?.markStoragePublished()
        updateStorageRevision(editingSession?.revision ?? 0)
    }

    /// 保存前的会话防护。返回 false 表示必须拒绝整篇写回：
    /// - 绑定 note 已退役（Trash/删除）时会话一并退役（磁盘侧已有
    ///   Note 层 isRetired guard，这里把源码会话口径对齐）；
    /// - 会话已推进（watcher 重载/显式替换/后续命令入口）而 buffer 停在
    ///   旧 revision 时，整篇写回会用旧内容覆盖新内容（旧 v1 覆盖 v2）。
    ///   正常输入路径双方同处基线 revision，不受影响；无会话防护（0）时
    ///   退回 owner guard 既有行为。
    func editingSessionAllowsSave(to note: Note) -> Bool {
        guard let session = editingSession, session.owns(url: note.url) else {
            return true
        }
        if note.isRetiredForEditing {
            session.retire()
        }
        guard !session.storageIsStale else {
            let stale = NSError(
                domain: "com.tw93.miaoyan.race",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "stale buffer (rev \(storageRevision)) for session at rev \(session.revision); refusing whole-save"
                ])
            AppDelegate.trackError(stale, context: "EditTextView.saveTextStorageContent.revisionGuard")
            return false
        }
        return true
    }
}
