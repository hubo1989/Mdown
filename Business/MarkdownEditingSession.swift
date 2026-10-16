import Foundation

// MARK: - T05 正式 MarkdownEditingSession（SPEC §5 API）
//
// 窗口编辑上下文的源码权威：持有 raw source / revision / selection 与
// 身份（ownerToken + canonicalURL + generation）。Note、磁盘写、renderer
// 不注入本层——它们消费 snapshot；对 Note 的 commit/flush 由 T07 的协调层
// 接入，这里不新增任何 save timer。
//
// 身份语义（NE-16）：
// - ownerToken：会话生命周期不变；同 URL 的不同 Note 实例回流复用本会话
//   （EditorStorageOwnership 的 legacy 允许行为不受影响），代际由
//   generation 表达。
// - generation：每次 rebind / replaceAll / rename / retire 递增，令旧
//   buffer、旧 parse/attachment 结果、旧 write 完成一并失效。
// - revision：每次 accepted 编辑 +1；noChange 不增；rejected 不回退。
//
// T05 阶段 source 模式的用户输入不逐键 apply（buffer 的附件化文本与
// raw source 的映射是 T10 投影层职责）；revision 的推进点是程序化整篇
// 替换（watcher 重载、版本恢复）与后续接入的命令入口。因此
// storageRevision 防护在 T05 只拦截「session 已推进而 buffer 未跟上」
// 的整篇写回，不改变既有输入/保存节奏。
@MainActor
public final class MarkdownEditingSession {

    /// parse / attachment / write 等异步任务完成时必须携带并回核对的
    /// 身份快照。latest-wins：owner、generation、revision 任一落后即拒。
    struct JobContext: Equatable {
        let ownerToken: UUID
        let canonicalURL: URL
        let generation: UInt64
        let revision: UInt64

        var identity: EditingIdentity {
            EditingIdentity(
                ownerToken: ownerToken, canonicalURL: canonicalURL, generation: generation
            )
        }
    }

    private(set) var identity: EditingIdentity
    private(set) var markdown: String
    private(set) var selection: MarkdownSelection
    private let isReadOnly: Bool
    private(set) var revision: UInt64 = 0
    private(set) var isRetired = false

    /// buffer 发布时记录的 (generation, revision)（EditTextView 侧防护的对端）。
    /// 两个数字都要比对：replaceAll 归零 revision 后，旧 buffer 的 revision
    /// 数字与新基线相同，只比数字会把旧 buffer 误判为新鲜（PLAN 的
    /// old-generation-same-revision 陷阱）。
    private(set) var storageRevision: UInt64 = 0
    private(set) var storageGeneration: UInt64 = 0

    init(
        identity: EditingIdentity,
        markdown: String,
        selection: MarkdownSelection,
        isReadOnly: Bool
    ) {
        self.identity = identity
        self.markdown = markdown
        self.selection = selection
        self.isReadOnly = isReadOnly
    }

    var snapshot: EditingSnapshot {
        EditingSnapshot(
            identity: identity, revision: revision, markdown: markdown, selection: selection
        )
    }

    // MARK: - 编辑事务

    /// 原子应用一条编辑事务。校验顺序：retired → owner → generation →
    /// revision → readOnly → patch 集合；任一失败原状态不变（不回退）。
    func apply(_ transaction: EditTransaction) -> EditApplyResult {
        if isRetired { return .rejected(.retired) }
        if transaction.identity.ownerToken != identity.ownerToken
            || transaction.identity.canonicalURL != identity.canonicalURL {
            return .rejected(.ownerChanged)
        }
        if transaction.identity.generation != identity.generation {
            return .rejected(.generationChanged)
        }
        if transaction.expectedRevision != revision {
            return .rejected(.staleRevision)
        }
        if isReadOnly { return .rejected(.readOnly) }

        switch MarkdownPatchApplier.applyPatches(transaction.patches, to: markdown) {
        case .success(let updated):
            if updated == markdown {
                return .noChange(
                    EditingSnapshot(
                        identity: identity, revision: revision,
                        markdown: markdown, selection: transaction.selectionAfter
                    ))
            }
            revision += 1
            markdown = updated
            selection = transaction.selectionAfter
            return .accepted(snapshot)
        case .failure(let rejection):
            return .rejected(rejection)
        }
    }

    // MARK: - 生命周期（NE-16：rebind/retire 提升代际）

    /// 同 URL 的新 Note 实例回流：保留 ownerToken，generation+1 并把
    /// 正文重置为传入基线（buffer 需要重新 publish 才能通过保存防护）。
    /// URL 不同返回 false（改名/移动走 `rename` 或放弃会话）。
    @discardableResult
    func rebind(url: URL, markdown baseline: String) -> Bool {
        guard !isRetired, url == identity.canonicalURL else { return false }
        return replaceAll(markdown: baseline)
    }

    /// 全量替换为新基线（watcher 无本地改动重载、版本恢复等显式 source
    /// replacement）：generation+1、revision 归零、旧任务/旧 buffer 全失效。
    @discardableResult
    func replaceAll(markdown newMarkdown: String) -> Bool {
        guard !isRetired else { return false }
        identity = EditingIdentity(
            ownerToken: identity.ownerToken,
            canonicalURL: identity.canonicalURL,
            generation: identity.generation + 1
        )
        markdown = newMarkdown
        revision = 0
        // 不重置 storageRevision/storageGeneration：旧 buffer 的发布身份
        // 保持旧代际，storageIsStale 立即为真直到重新 publish。
        selection = MarkdownSelection(
            anchorUTF16: 0, focusUTF16: 0, affinity: .downstream
        )
        return true
    }

    /// rename/move：更新 canonical URL 并提升代际，旧身份捕获全部失效。
    func rename(to url: URL) {
        guard !isRetired else { return }
        identity = EditingIdentity(
            ownerToken: identity.ownerToken, canonicalURL: url,
            generation: identity.generation + 1
        )
    }

    /// 退役（Trash/删除/会话终结）：此后一切编辑与写回被拒。
    func retire() {
        isRetired = true
        identity = EditingIdentity(
            ownerToken: identity.ownerToken,
            canonicalURL: identity.canonicalURL,
            generation: identity.generation + 1
        )
    }

    // MARK: - buffer 防护（SPEC：为旧 source buffer 增加 revision metadata）

    /// 该会话当前绑定的文件是否为 url（ownerToken + URL 共同决定，
    /// 与既有 owner guard 的 URL 相等判定衔接）。
    func owns(url: URL) -> Bool {
        identity.canonicalURL == url && !isRetired
    }

    /// publishStorage 时记录 buffer 对应的当前身份（generation + revision）。
    func markStoragePublished() {
        storageRevision = revision
        storageGeneration = identity.generation
    }

    /// buffer 是否落后于会话（代际不同或 revision 落后即不得整篇写回；
    /// T05 中正常输入路径双方同处基线，不会误伤）。
    var storageIsStale: Bool {
        storageGeneration != identity.generation || storageRevision < revision
    }

    // MARK: - 异步任务身份（latest parse/attachment/write 共用，不另存 source）

    var currentJobContext: JobContext {
        JobContext(
            ownerToken: identity.ownerToken, canonicalURL: identity.canonicalURL,
            generation: identity.generation, revision: revision
        )
    }

    /// 任务完成回调核对：身份快照与当前完全一致才接受（旧 revision、
    /// 旧 generation、别的会话一律拒绝）。
    func accepts(resultFor context: JobContext) -> Bool {
        !isRetired && context == currentJobContext
    }
}
