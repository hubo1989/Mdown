import Foundation

/// T04 / G0 最小原型：跨投影的单一语义历史。
/// 记录每次被采纳的 source patch 与 selection 前后；undo 应用 inverse
/// patch（expected/replacement 互换），redo 重放。composition 提交计为
/// 一组（G0 由调用方保证 insertText 后一次性记录）；typing 时间聚合与
/// viewstate 排除由 T06 正式化。
struct MarkdownEditorHistory {

    struct Entry {
        let patches: [SourcePatch]
        /// 应用 patch 前的 source（inverse 由此构造，避免坐标漂移）。
        let sourceBefore: String
        let selectionBefore: MarkdownSelection
        let selectionAfter: MarkdownSelection
        let name: String
    }

    private(set) var undoStack: [Entry] = []
    private(set) var redoStack: [Entry] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    @discardableResult
    mutating func record(
        patches: [SourcePatch],
        sourceBefore: String,
        revision: UInt64,
        selectionBefore: MarkdownSelection,
        name: String
    ) -> Bool {
        guard !patches.isEmpty else { return false }
        let after = MarkdownSelection(
            anchorUTF16: selectionBefore.anchorUTF16, focusUTF16: selectionBefore.focusUTF16, affinity: .downstream
        )
        undoStack.append(
            Entry(
                patches: patches, sourceBefore: sourceBefore,
                selectionBefore: selectionBefore, selectionAfter: after, name: name
            ))
        redoStack.removeAll()
        _ = revision
        return true
    }

    struct Result {
        let source: String
        let revision: UInt64
        let selection: MarkdownSelection
    }

    mutating func undo(currentSource: String, currentRevision: UInt64) -> Result? {
        guard let entry = undoStack.popLast() else { return nil }
        // inverse：patch 以 sourceBefore 为 base，直接还原整段 source
        redoStack.append(entry)
        return Result(
            source: entry.sourceBefore,
            revision: currentRevision + 1,
            selection: entry.selectionBefore
        )
    }

    mutating func redo(currentSource: String, currentRevision: UInt64) -> Result? {
        guard let entry = redoStack.popLast() else { return nil }
        // patch 无法在其记录的 base 上重放（entry 弃用，不回栈）：
        // source 是权威，绝不以旧 base 静默覆盖当前内容。
        guard case .success(let redone) = MarkdownPatchApplier.applyPatches(entry.patches, to: entry.sourceBefore) else {
            return nil
        }
        undoStack.append(entry)
        return Result(source: redone, revision: currentRevision + 1, selection: entry.selectionAfter)
    }
}
