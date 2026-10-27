import Cocoa

// MARK: - T08 离开前 TransitionCoordinator（SPEC §7.1 / NE-13 / NE-18）
//
// 所有「离开当前编辑上下文」的硬保存点（Cmd+S、切笔记、关窗、退出、
// duplicate、进 preview、失焦）的唯一入口。职责：
// 1. finish-composition：离开点先把活动后端的 IME 组合输入提交进 buffer
//    （NE-13），否则捕获到的是不含组合文本的 hidden buffer；
// 2. capture：只从活动后端（Vditor / source 编辑器）采集 buffer，绝不读
//    被切换后停留旧内容的 textStorage；
// 3. flush + 可取消前置：写失败/冲突时给 Retry / Save Copy / Discard /
//    Cancel 并等待用户结果；Cancel 使离开被阻止（选择不切、关窗返回
//    false、quit 返回 terminateCancel）。willClose/willTerminate 只做
//    静默兜底 flush，不在此提示。
//
// Discard 只丢弃当前会话未落盘的草稿（generation+1 使在途写完成作废），
// 不删磁盘文件；Save Copy 经系统 NSSavePanel 确认成功才放行离开，原笔记
// 保持原状。不新增跨重启恢复库。

/// 用户在失败告警上的四种选择（AC-09）。
enum EditingTransitionChoice {
    case retry
    case saveCopy
    case discard
    case cancel
}

/// 静默统一入口的结果。
enum EditingFlushOutcome {
    /// 活动笔记无待写内容（或已退役）。
    case idle
    /// 活动草稿已同步写盘。
    case saved
    /// 组合输入仍在进行且无法提交；离开点必须留在原上下文（NE-13）。
    case blocked
    /// 写失败/被取代；笔记保持 dirty 可重试。
    case failed(Note)
}

/// 退出网关 UI 抽象：生产实现走 NSAlert/NSSavePanel，测试注入脚本。
@MainActor
protocol EditingTransitionPresenting: AnyObject {
    /// 展示保存失败告警并等待（阻塞）用户选择。
    func presentSaveFailure(noteName: String) -> EditingTransitionChoice
    /// 系统 Save Copy 面板；用户取消返回 nil。
    func presentSaveCopyPanel(noteName: String) -> URL?
}

/// 活动编辑上下文的采集面。ViewController 是唯一生产实现；测试提供桩。
@MainActor
protocol EditingTransitionContext: AnyObject {
    /// 活动后端正在编辑的笔记（wysiwyg 时 Vditor 的 currentNote）。
    var activeEditingNote: Note? { get }
    /// 源码编辑器的 IME 组合输入是否可安全提交（unmarkText 成功）。
    /// wysiwyg 后端组合输入由 Vditor 逐键提交，恒为 true。
    func finishSourceComposition() -> Bool
    /// 把活动后端已确认的 buffer 推进 note.content。内部自带 owner 守卫
    /// （saveTextStorageContent / Vditor flush），绝不读隐藏 buffer。
    func captureActiveBuffer(into note: Note)
    /// 当前仍 dirty 的笔记（含活动笔记）。
    var dirtyNotes: [Note] { get }
}

@MainActor
final class EditingTransitionCoordinator {

    private let presenter: EditingTransitionPresenting

    init(presenter: EditingTransitionPresenting = SystemEditingTransitionPresenter()) {
        self.presenter = presenter
    }

    // MARK: - 统一入口（静默，无 UI）

    /// finish-composition → capture → flush 活动笔记。
    ///
    /// `forceCompositionFinish`：真正的离开点（切笔记/关窗/退出/Cmd+S/
    /// duplicate）传 true——组合输入必须先提交再捕获；失焦与进 preview
    /// 这类「编辑器仍在上下文内」的场景传 false，不打断进行中的 IME
    /// （NE-13：转换期间可安全留在原上下文）。
    @discardableResult
    func finishActiveEditing(
        in context: EditingTransitionContext,
        forceCompositionFinish: Bool
    ) -> EditingFlushOutcome {
        if forceCompositionFinish {
            guard context.finishSourceComposition() else { return .blocked }
        }
        guard let note = context.activeEditingNote, !note.isRetiredForEditing else {
            return .idle
        }
        context.captureActiveBuffer(into: note)
        guard note.needsSave else { return .idle }
        return note.flushPendingSave() ? .saved : .failed(note)
    }

    // MARK: - 可取消前置（AC-09）

    /// 关窗 / 退出的前置网关。true = 允许离开；false = 阻止
    /// （windowShouldClose 返回 false / applicationShouldTerminate 返回
    /// terminateCancel）。先处理活动笔记（含组合输入），再逐一处理其余
    /// dirty 笔记；任一失败进入 Retry/Save Copy/Discard/Cancel 循环。
    /// 经 Save Copy 放行的笔记保持 dirty（原笔记原状），同一次网关内不再
    /// 重复处理——副本已确认写成功即是该笔记的最终结果。
    func prepareExit(in context: EditingTransitionContext) -> Bool {
        var resolvedBySaveCopy = Set<ObjectIdentifier>()
        switch finishActiveEditing(in: context, forceCompositionFinish: true) {
        case .blocked:
            // 组合输入无法安全提交：留在原上下文，不捕获不提示。
            return false
        case .failed(let note):
            guard resolveFailure(of: note, resolvedBySaveCopy: &resolvedBySaveCopy) else {
                return false
            }
        case .idle, .saved:
            break
        }
        for note in context.dirtyNotes {
            if resolvedBySaveCopy.contains(ObjectIdentifier(note)) { continue }
            if !note.flushPendingSave(),
                !resolveFailure(of: note, resolvedBySaveCopy: &resolvedBySaveCopy)
            {
                return false
            }
        }
        return true
    }

    /// 切换笔记前的网关。语义沿用原 tableViewSelectionDidChange 的
    /// save-then-switch：捕获活动 buffer 后立即整篇写盘（不等 debounce），
    /// 保证最后 0.5s 的输入不丢；失败时 Cancel = 选择不切换。
    func prepareNoteSwitch(from outgoing: Note?, in context: EditingTransitionContext) -> Bool {
        guard let outgoing = outgoing, !outgoing.isRetiredForEditing else { return true }
        guard context.finishSourceComposition() else { return false }
        context.captureActiveBuffer(into: outgoing)
        if outgoing.flushPendingSave() { return true }
        var resolved = Set<ObjectIdentifier>()
        return resolveFailure(of: outgoing, resolvedBySaveCopy: &resolved)
    }

    /// Cmd+S：与 prepareExit 同一套失败处理，但没有「阻止离开」语义——
    /// Cancel 只是把笔记留在 dirty。返回是否全部落盘（用于 Saved~ toast）。
    @discardableResult
    func saveAllNow(in context: EditingTransitionContext) -> Bool {
        _ = finishActiveEditing(in: context, forceCompositionFinish: true)
        var resolvedBySaveCopy = Set<ObjectIdentifier>()
        for note in context.dirtyNotes {
            if resolvedBySaveCopy.contains(ObjectIdentifier(note)) { continue }
            if !note.flushPendingSave(),
                !resolveFailure(of: note, resolvedBySaveCopy: &resolvedBySaveCopy)
            {
                return false
            }
        }
        return context.dirtyNotes.isEmpty
    }

    /// 以特定笔记为对象的命令（duplicate 等）前采集：目标恰为活动后端
    /// 正在编辑的笔记时才需要从 buffer 采集，其余笔记镜像已在
    /// note.content。组合输入先提交；无法提交返回 false，调用方中止命令
    /// （命令读取的必须是已确认内容，不是 hidden buffer）。
    func prepareCommandTargeting(_ note: Note, in context: EditingTransitionContext) -> Bool {
        guard context.finishSourceComposition() else { return false }
        if context.activeEditingNote?.isEqualURL(url: note.url) == true {
            context.captureActiveBuffer(into: note)
        }
        return true
    }

    /// 单笔记命令前 flush：失败进入 Retry/Save Copy/Discard/Cancel。
    /// Cancel 返回 false，调用方中止命令（改名/移动前必须先把草稿落盘，
    /// 否则失败路径会让内容与新文件名分裂在两个文件）。
    @discardableResult
    func flushOrResolve(_ note: Note) -> Bool {
        guard note.needsSave else { return true }
        var resolved = Set<ObjectIdentifier>()
        return note.flushPendingSave()
            || resolveFailure(of: note, resolvedBySaveCopy: &resolved)
    }

    // MARK: - 失败解决循环

    /// 呈现 Retry / Save Copy / Discard / Cancel 并等待结果，直到可放行
    /// （retry 成功 / 副本确认写成功 / 草稿显式丢弃）或用户取消。
    /// Save Copy 只把当前草稿另存到用户选定位置，原笔记保持原状（仍
    /// dirty）；Discard 只丢弃会话草稿，磁盘文件不动。
    private func resolveFailure(
        of note: Note,
        resolvedBySaveCopy: inout Set<ObjectIdentifier>
    ) -> Bool {
        while true {
            switch presenter.presentSaveFailure(noteName: note.getFileName()) {
            case .retry:
                if note.flushPendingSave() { return true }
            case .saveCopy:
                guard let destination = presenter.presentSaveCopyPanel(noteName: note.getFileName())
                else { continue }
                if saveCopy(of: note, to: destination) {
                    resolvedBySaveCopy.insert(ObjectIdentifier(note))
                    return true
                }
            case .discard:
                note.discardUnsavedChanges()
                return true
            case .cancel:
                return false
            }
        }
    }

    /// 把当前已提交草稿（note.content 镜像）写到用户选定的副本位置。
    private func saveCopy(of note: Note, to destination: URL) -> Bool {
        guard let data = note.content.string.data(using: .utf8) else { return false }
        do {
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            AppDelegate.trackError(error, context: "EditingTransitionCoordinator.saveCopy")
            return false
        }
    }
}

// MARK: - 生产 UI（NSAlert + NSSavePanel）

@MainActor
final class SystemEditingTransitionPresenter: EditingTransitionPresenting {

    func presentSaveFailure(noteName: String) -> EditingTransitionChoice {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(format: I18n.str("Failed to save \"%@\""), noteName)
        alert.informativeText = I18n.str(
            "Your changes could not be written to disk. Retry the save, keep a copy elsewhere, or discard this draft."
        )
        alert.addButton(withTitle: I18n.str("Retry"))
        alert.addButton(withTitle: I18n.str("Save Copy…"))
        alert.addButton(withTitle: I18n.str("Discard Changes"))
        alert.addButton(withTitle: I18n.str("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .retry
        case .alertSecondButtonReturn: return .saveCopy
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    func presentSaveCopyPanel(noteName: String) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = noteName
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - ViewController 采集面

extension ViewController: EditingTransitionContext {

    var activeEditingNote: Note? {
        if sessionLayoutMode == .wysiwyg, let current = activeWysiwygBackend?.currentNote {
            return current
        }
        return EditTextView.note
    }

    func finishSourceComposition() -> Bool {
        guard sessionLayoutMode != .wysiwyg else { return true }
        return editArea.finishActiveComposition()
    }

    func captureActiveBuffer(into note: Note) {
        if sessionLayoutMode == .wysiwyg {
            activeWysiwygBackend?.flushPendingSave(completion: nil)
        } else {
            editArea.saveTextStorageContent(to: note)
        }
    }

    var dirtyNotes: [Note] {
        storage.noteList.filter(\.needsSave)
    }
}
