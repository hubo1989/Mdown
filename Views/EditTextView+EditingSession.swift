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

    // MARK: - T09 文件事件 / 版本恢复（SPEC §7.3）
    /// watcher 的外部文件变化处理（NE-19）。
    /// - 返回 true：本地无改动，已按磁盘真值重载 buffer；
    /// - 返回 false：本地有 dirty/组合输入，保留双方——外部版本记录在会话
    ///   里等用户显式选择，buffer 与基线都不动。调用方负责 toast 与冲突
    ///   备份。
    @discardableResult
    func applyExternalFileChange(_ externalContent: String, owner: Note) -> Bool {
        guard let session = editingSession, session.owns(url: owner.url) else {
            // 无会话（buffer 属于别的 note，见 storageNote 文档）：不动本
            // buffer，交由调用方按 note.content 路径处理。
            return false
        }
        // dirty 判定以会话/Note 的实际提交状态为准，不看 table selection
        // （#543）：preview 家族模式下 EditTextView.note 会偏离 buffer owner。
        let hasLocalChanges = owner.needsSave || session.storageIsStale
        guard
            session.reloadFromDisk(
                externalContent: externalContent, hasLocalChanges: hasLocalChanges)
        else {
            return false
        }
        publishStorageWithoutRebasingSession(
            NSMutableAttributedString(string: externalContent), owner: owner)
        return true
    }

    /// 用户显式接受 watcher 保留的外部版本（local recovery trigger，不是
    /// 保存成功）：会话与 buffer 一同切到磁盘真值，本地草稿不自动保存。
    @discardableResult
    func adoptPendingExternalVersion(owner: Note) -> Bool {
        guard let session = editingSession, session.owns(url: owner.url),
            session.adoptPendingExternal()
        else {
            return false
        }
        publishStorageWithoutRebasingSession(
            NSMutableAttributedString(string: session.snapshot.markdown), owner: owner)
        return true
    }

    /// 版本恢复：显式 source replacement（SPEC §7.3）。调用方已按 history
    /// policy 存下恢复前内容，这里只做会话 + buffer 的原子切换。
    @discardableResult
    func applyRestoredVersion(_ markdown: String, owner: Note) -> Bool {
        guard let session = editingSession, session.owns(url: owner.url),
            session.replaceWithRestoredVersion(markdown: markdown)
        else {
            return false
        }
        // 必须在重新发布 buffer 之前取：publishStorageWithoutRebasingSession 会把
        // storageGeneration 对齐回新代际，之后再问就永远是「不陈旧」。
        let staleUndoHistory = !session.undoHistoryTargetsCurrentBaseline
        publishStorageWithoutRebasingSession(
            NSMutableAttributedString(string: markdown), owner: owner)
        // 恢复是显式 source replacement：恢复前的 undo 动作指向的文本已不
        // 属于新基线，Cmd-Z 不得把它带回编辑器（reloadNote 的同类防护，
        // 见 FileSystemEventManager.reloadNote）。
        if staleUndoHistory {
            owner.undoManager.removeAllActions()
        }
        return true
    }

    /// rename / move 后同步会话的 canonical URL（NE-20）。调用方必须在
    /// `note.move(to:)` / `note.overwrite(url:)` **成功之后**调用——失败时
    /// URL 不变，session 也不该动。代际提升令所有按旧 URL 捕获的任务与
    /// buffer 身份失效；正文不变（rename 不改内容），因此不需要重新发布。
    @discardableResult
    func syncSessionAfterRename(of note: Note) -> Bool {
        guard let session = editingSession, !session.isRetiredForSave else { return false }
        guard session.canonicalURL != note.url else {
            // URL 未变（同路径重复调用）：保持现状，不无谓推进代际。
            return true
        }
        session.rename(to: note.url)
        // buffer 的正文仍属这个会话，但发布身份已落后一代：重新对齐，否则
        // storageIsStale 会挡住改名后第一次正常保存。
        editingSession?.markStoragePublished()
        updateStorageRevision(editingSession?.revision ?? 0)
        return true
    }

    /// 异步任务（上传/附件处理）完成时的身份核对（NE-22）。`captured` 是任务
    /// 启动时记录的会话快照；会话已推进代际、URL 已变、或已退役时一律拒绝。
    /// 无会话时退回 true，保持 legacy 调用点既有行为。
    func editingSessionAccepts(resultFor captured: MarkdownEditingSession.JobContext) -> Bool {
        guard let session = editingSession else { return true }
        return session.accepts(resultFor: captured)
    }

    /// 异步任务启动时捕获当前会话身份。无会话（legacy 路径）返回 nil，调用方
    /// 按「无防护」处理，不改变既有行为。
    func captureEditingJobContext() -> MarkdownEditingSession.JobContext? {
        editingSession?.currentJobContext
    }

    /// 把 textStorage 的当前字节整篇搬运进 note.content。owner 守卫（#543）
    /// 与会话身份/revision 防护都在这里：跨 note、失效 buffer、退役 note 的
    /// 整篇写回一律拒绝。
    func saveTextStorageContent(to note: Note) {
        guard let storage = textStorage else { return }
        // Refuse cross-note writes: when the buffer belongs to a different
        // note than the requested target (preview-family modes after a list
        // switch, see `storageNote` doc), copying it over would replace the
        // target note's entire content with another file's text (#543).
        guard let owner = storageNote, owner.isEqualURL(url: note.url) else {
            let mismatch = NSError(
                domain: "com.tw93.miaoyan.race",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "textStorage owner (\(storageNote?.url.lastPathComponent ?? "nil")) != save target (\(note.url.lastPathComponent))"
                ])
            AppDelegate.trackError(mismatch, context: "EditTextView.saveTextStorageContent.ownerGuard")
            return
        }
        // T05: 失效 buffer / 退役 note 的整篇写回拒绝（identity/revision
        // 防护，见下方 editingSessionAllowsSave）。
        guard editingSessionAllowsSave(to: note) else { return }
        let string = storage.attributedSubstring(from: NSRange(0..<storage.length))
        let cleaned = NSMutableAttributedString(attributedString: string)
            .unLoadImages()
            .unLoadCheckboxes()
        note.content = cleaned
    }

    /// 保存前的会话防护。返回 false 表示必须拒绝整篇写回：
    /// - 绑定 note 已退役（Trash/删除）时会话一并退役（磁盘侧已有
    ///   Note 层 isRetired guard，这里把源码会话口径对齐）；
    /// - 会话已推进（watcher 重载/显式替换/后续命令入口）而 buffer 停在
    ///   旧 revision 时，整篇写回会用旧内容覆盖新内容（旧 v1 覆盖 v2）。
    ///   正常输入路径双方同处基线 revision，不受影响；无会话防护（0）时
    ///   退回 owner guard 既有行为。
    func editingSessionAllowsSave(to note: Note) -> Bool {
        guard let session = editingSession else {
            return true
        }
        if note.isRetiredForEditing {
            session.retire()
        }
        // 会话已退役（绑定 note 被 Trash/删除）：`owns(url:)` 此时为 false，
        // 但拒绝理由必须是「已退役」而不是「没有会话」——否则 buffer 的整篇
        // 写回会落进一个已删除的 Note 实例（SPEC §7.3：Trash/删除后 session
        // 不再写）。
        if session.isRetiredForSave {
            let retired = NSError(
                domain: "com.tw93.miaoyan.race",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "session retired for \(note.url.lastPathComponent); refusing whole-save"
                ])
            AppDelegate.trackError(retired, context: "EditTextView.saveTextStorageContent.retiredSessionGuard")
            return false
        }
        guard session.owns(url: note.url) else {
            return true
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

// MARK: - T14 查找路由（NE-23：命令只作用活动会话面）

extension EditTextView {
    /// native rich 是活动正文面时，查找归活动会话面所有——本 view（隐藏的
    /// source 编辑器）不得再创建自己的查找条，⌘F/⌘G 由菜单 textFinder →
    /// rich host 处理。
    func richHostOwnsFind() -> Bool {
        guard
            let vc = window?.contentViewController as? ViewController
                ?? AppContext.shared.viewController,
            vc.sessionLayoutMode == .wysiwyg,
            let host = vc.activeWysiwygBackend as? NativeRichEditorHostView,
            !host.isHidden
        else { return false }
        return true
    }
}
