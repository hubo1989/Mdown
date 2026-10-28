import Foundation

/// T06 正式：跨投影的单一语义历史（SPEC §5.4）。
///
/// 记录每次被采纳的 source patch 与 selection 前后；undo 应用 inverse
/// patch（expected/replacement 互换），redo 重放。同 note 的 source 与
/// rich 投影共享同一份历史；view 自动 undo（NSTextView allowsUndo）必须
/// 关闭，登记只能走这里——否则同一动作会被记两次。
///
/// 合并策略（NE-15 的「聚合时间策略固定记录」）：只有 typing 可合并，
/// 且要求同 origin、同 undoGroup、selection 紧贴上一次 selectionAfter、
/// patch 范围与上一次末尾相邻、距上次记录未超 `coalescingInterval`。
/// composition 提交、paste、format、structure 一律独立成组——SPEC 明确
/// 「IME 提交、paste、format、table structure 各为明确 group」。
struct MarkdownEditorHistory {

    /// 合并窗口。不是 Typora 的 3s 也不是 Vditor 的 800ms——按 SPEC 要求
    /// 「聚合时间策略固定记录，不盲抄」，取一个可通过测试验证、对手感
    /// 影响中性的值；如需调整必须先改这里并补测试。
    static let defaultCoalescingInterval: TimeInterval = 1.0

    /// 内存上限（SPEC §9 的 undo 内存预算：显式限额，不裁当前 dirty 原文
    /// 或跨 note 历史）。达到上限丢弃最旧 entry，保留最新可 undo 路径。
    static let maxEntries = 200

    struct Entry: Equatable {
        /// 实际应用过的 patch（base = sourceBefore）。
        let patches: [SourcePatch]
        /// 应用 patch 前的 source（inverse 由此构造，避免坐标漂移）。
        let sourceBefore: String
        let selectionBefore: MarkdownSelection
        let selectionAfter: MarkdownSelection
        let origin: EditOrigin
        let undoGroupID: UUID
        let recordedAt: Date
        let name: String
    }

    private(set) var undoStack: [Entry] = []
    private(set) var redoStack: [Entry] = []
    private let coalescingInterval: TimeInterval
    private let now: () -> Date

    init(
        coalescingInterval: TimeInterval = MarkdownEditorHistory.defaultCoalescingInterval,
        now: @escaping () -> Date = Date.init
    ) {
        self.coalescingInterval = coalescingInterval
        self.now = now
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 诊断观察口:当前历史栈深度(测试断言 view-state 不入历史用)。
    var debugDepth: Int { undoStack.count + redoStack.count }

    /// 最近一次 entry 是否还能被一次紧随其后的 typing 合并。
    /// 规则见头部注释；任一条件失败即新开 entry。redo 栈在 record 时
    /// 已清空，所以合并只可能发生在 undoStack 顶。
    private func coalesceCandidate(
        origin: EditOrigin,
        undoGroupID: UUID,
        selectionBefore: MarkdownSelection,
        patches: [SourcePatch]
    ) -> Int? {
        guard origin == .typing else { return nil }
        guard let lastIndex = undoStack.indices.last else { return nil }
        let last = undoStack[lastIndex]
        guard last.origin == .typing else { return nil }
        guard last.undoGroupID == undoGroupID else { return nil }
        // 时间窗
        guard now().timeIntervalSince(last.recordedAt) <= coalescingInterval else { return nil }
        // selection 必须紧贴上一次编辑后的位置（不允许中间有点击/移动）
        guard selectionBefore == last.selectionAfter else { return nil }
        // patch 必须是单 patch 且紧跟上一次 patch 末尾（连续 typing 的
        // 唯一安全形态；跨块/删除/结构命令都已在 origin 上排除）。
        guard patches.count == 1, let patch = patches.first, let lastPatch = last.patches.last else {
            return nil
        }
        let lastPatchEnd = lastPatch.rangeUTF16.location + lastPatch.replacement.utf16.count
        guard patch.rangeUTF16.location == lastPatchEnd else { return nil }
        // expectedText 必须为空（纯插入）。带 expectedText 的 typing 是
        // 替换（如选区覆盖），独立成组以免 undo 粒度跳变。
        guard patch.expectedText.isEmpty, lastPatch.expectedText.isEmpty else { return nil }
        return lastIndex
    }

    /// 登记参数包（避免函数超 5 参的 lint 限制，同时让调用方明确语义）。
    struct RecordInput {
        let patches: [SourcePatch]
        let sourceBefore: String
        let selectionBefore: MarkdownSelection
        let selectionAfter: MarkdownSelection
        let origin: EditOrigin
        var undoGroupID: UUID = UUID()
        let name: String
    }

    /// 登记一次已采纳的编辑。返回 true 表示入栈（新增或合并），false
    /// 表示该编辑不产生历史（空 patch 集）。调用方负责保证 patches 已经
    /// 成功应用到 sourceBefore 得到当前 source——history 不验证。
    @discardableResult
    mutating func record(_ input: RecordInput) -> Bool {
        guard !input.patches.isEmpty else { return false }

        if let mergeIndex = coalesceCandidate(
            origin: input.origin, undoGroupID: input.undoGroupID,
            selectionBefore: input.selectionBefore, patches: input.patches
        ) {
            // 合并：把新 patch 追加到既有 entry 末尾，selectionAfter 推进
            // 到本次的 selectionAfter；redo 栈在 record 时已清空。合并只
            // 影响 undo 粒度，source 由 patches 顺序应用自然正确。
            let existing = undoStack[mergeIndex]
            undoStack[mergeIndex] = Entry(
                patches: existing.patches + input.patches,
                sourceBefore: existing.sourceBefore,
                selectionBefore: existing.selectionBefore,
                selectionAfter: input.selectionAfter,
                origin: existing.origin,
                undoGroupID: existing.undoGroupID,
                recordedAt: now(),
                name: existing.name
            )
        } else {
            undoStack.append(
                Entry(
                    patches: input.patches, sourceBefore: input.sourceBefore,
                    selectionBefore: input.selectionBefore,
                    selectionAfter: input.selectionAfter,
                    origin: input.origin, undoGroupID: input.undoGroupID,
                    recordedAt: now(), name: input.name
                ))
            // 上限丢弃最旧（保留最新可 undo 路径；上限是 SPEC 的显式预算）
            if undoStack.count > Self.maxEntries {
                undoStack.removeFirst(undoStack.count - Self.maxEntries)
            }
        }
        redoStack.removeAll()
        return true
    }

    /// 输入规则触发（结构前缀完成，T12）时把栈顶构成该前缀的连续纯插入
    /// typing entry 合并为单条——「一键 undo 回完整字面前缀」（SPEC §4.3）。
    /// 这是跨时间窗的显式重组（用户可能在符号与空格间停顿超过
    /// coalescingInterval）；链不完整（点击/删除/结构命令打断了前缀输入）
    /// 则不动，undo 按既有粒度分次——分次不吞字，合并只影响粒度。
    mutating func collapseTypingPrefix(
        prefixRange: NSRange, selectionAfter: MarkdownSelection, name: String
    ) -> Bool {
        let prefixEnd = NSMaxRange(prefixRange)
        // 从栈顶向下收集：纯插入、patch 顺序相邻、合并后恰好覆盖
        // [prefixRange.location, prefixEnd)。entry 内可能已是 coalesce 过
        // 的多 patch，末尾按 replacement 实际长度推进。
        var collected: [Entry] = []
        var expectedEnd = prefixEnd
        for entry in undoStack.reversed() {
            guard entry.origin == .typing, !entry.patches.isEmpty,
                entry.patches.allSatisfy({ $0.expectedText.isEmpty && $0.rangeUTF16.length == 0 })
            else { break }
            let entryStart = entry.patches.first!.rangeUTF16.location
            var cursor = entryStart
            var adjacent = true
            for patch in entry.patches where adjacent {
                if patch.rangeUTF16.location != cursor { adjacent = false }
                cursor += patch.replacement.utf16.count
            }
            guard adjacent, cursor == expectedEnd, entryStart >= prefixRange.location else { break }
            collected.append(entry)
            expectedEnd = entryStart
        }
        guard let first = collected.last,
            first.patches.first!.rangeUTF16.location == prefixRange.location
        else { return false }

        // 收集的 patch 坐标属于各自中间版本，不能作为同一 base 的多 patch
        // 重放；连续插入合成一条，undo/redo 才保持同一文本顺序。
        let mergedText = collected.reversed().flatMap(\.patches).map(\.replacement).joined()
        let mergedPatches = [
            SourcePatch(
                rangeUTF16: NSRange(location: prefixRange.location, length: 0),
                expectedText: "", replacement: mergedText)
        ]
        // 重组改变 undo 链形态：既有 redo 重放坐标可能过期，直接作废
        // （fail-closed；record 后的触发路径 redo 本就为空，这里消除对
        // 调用顺序的隐式依赖）。
        redoStack.removeAll()
        undoStack.removeLast(collected.count)
        undoStack.append(
            Entry(
                patches: mergedPatches, sourceBefore: first.sourceBefore,
                selectionBefore: first.selectionBefore,
                selectionAfter: selectionAfter,
                origin: .typing, undoGroupID: UUID(),
                recordedAt: now(), name: name))
        return true
    }

    struct Result: Equatable {
        let source: String
        let selection: MarkdownSelection
        let origin: EditOrigin
        let name: String
    }

    /// undo：把栈顶 entry 的 sourceBefore 恢复为当前 source。revision 由
    /// 调用方（session/view）推进——history 不拥有 revision 语义，只
    /// 保证 undo 之后 source 回到 entry 之前的状态。
    mutating func undo(currentSource: String) -> Result? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(entry)
        return Result(
            source: entry.sourceBefore,
            selection: entry.selectionBefore,
            origin: entry.origin,
            name: entry.name
        )
    }

    /// redo：重放栈顶 entry 的 patches 到其 sourceBefore。重放结果必须
    /// 等于 undo 之前的当前 source——这是「undo 后未发生新编辑」的
    /// 不变量；若不成立说明有外部写绕过了 history，拒绝 redo 而不是
    /// 静默覆盖。
    mutating func redo(currentSource: String) -> Result? {
        guard let entry = redoStack.popLast() else { return nil }
        guard
            case .success(let redone) = MarkdownPatchApplier.applyPatches(
                entry.patches, to: entry.sourceBefore
            )
        else {
            // patch 无法在其记录的 base 上重放：entry 弃用（不回栈），
            // source 是权威，绝不以旧 base 静默覆盖当前内容。
            return nil
        }
        undoStack.append(entry)
        return Result(
            source: redone,
            selection: entry.selectionAfter,
            origin: entry.origin,
            name: entry.name
        )
    }
}
