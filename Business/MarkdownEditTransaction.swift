import Foundation

// MARK: - SPEC §5.2 值类型合同
// T02 原型：纯值与纯函数，不读 Note/Storage/renderer；T05 由
// MarkdownEditingSession 挂接生命周期后复用同一套校验语义。

struct EditingIdentity: Equatable {
    let ownerToken: UUID
    let canonicalURL: URL
    let generation: UInt64
}

struct MarkdownSelection: Equatable {
    let anchorUTF16: Int
    let focusUTF16: Int
    let affinity: Affinity

    enum Affinity: Equatable {
        case upstream
        case downstream
    }
}

struct SourcePatch: Equatable {
    let rangeUTF16: NSRange
    let expectedText: String
    let replacement: String
}

enum EditOrigin: String {
    case typing, composition, delete, structure, format, paste
    case attachment, source, previewIntent, restore, externalReload
}

struct EditTransaction {
    let identity: EditingIdentity
    let expectedRevision: UInt64
    let patches: [SourcePatch]
    let selectionBefore: MarkdownSelection
    let selectionAfter: MarkdownSelection
    let origin: EditOrigin
    let undoGroupID: UUID
}

struct EditingSnapshot {
    let identity: EditingIdentity
    let revision: UInt64
    let markdown: String
    let selection: MarkdownSelection
}

enum EditRejection: Error, Equatable {
    case ownerChanged, generationChanged, staleRevision, retired
    case readOnly, compositionActive, invalidRange
    case overlappingPatches, expectedTextMismatch
    case ambiguousProjection
}

enum EditApplyResult {
    case accepted(EditingSnapshot)
    case noChange(EditingSnapshot)
    case rejected(EditRejection)
}

// MARK: - 原子事务应用器（T02 纯函数核心）

/// 校验并应用一组 source patch。事务的所有 patch 以同一 base 的 UTF-16
/// 坐标表达，按 upperBound 降序应用；任一校验失败则整个事务拒绝，
/// 原文不变（原子性）。
enum MarkdownPatchApplier {

    /// 对 snapshot 应用 transaction：identity → revision → patch 原子校验。
    static func apply(_ transaction: EditTransaction, to snapshot: EditingSnapshot) -> EditApplyResult {
        if transaction.identity.ownerToken != snapshot.identity.ownerToken
            || transaction.identity.canonicalURL != snapshot.identity.canonicalURL
        {
            return .rejected(.ownerChanged)
        }
        if transaction.identity.generation != snapshot.identity.generation {
            return .rejected(.generationChanged)
        }
        if transaction.expectedRevision != snapshot.revision {
            return .rejected(.staleRevision)
        }
        switch applyPatches(transaction.patches, to: snapshot.markdown) {
        case .success(let updated):
            if updated == snapshot.markdown {
                return .noChange(
                    EditingSnapshot(
                        identity: snapshot.identity, revision: snapshot.revision,
                        markdown: snapshot.markdown, selection: transaction.selectionAfter
                    ))
            }
            return .accepted(
                EditingSnapshot(
                    identity: snapshot.identity, revision: snapshot.revision + 1,
                    markdown: updated, selection: transaction.selectionAfter
                ))
        case .failure(let rejection):
            return .rejected(rejection)
        }
    }

    /// 校验 patch 集合并按降序应用；失败返回显式拒绝类型，原文不变。
    static func applyPatches(_ patches: [SourcePatch], to source: String) -> Result<String, EditRejection> {
        let utf16 = Array(source.utf16)
        var normalized: [NormalizedPatch] = []
        normalized.reserveCapacity(patches.count)

        for patch in patches {
            let range = patch.rangeUTF16
            // 越界（NSRange 的 length 为负由 NSNotFound/负值统一拒绝）
            guard range.location >= 0, range.length >= 0,
                range.location + range.length <= utf16.count
            else {
                return .failure(.invalidRange)
            }
            // Unicode 不变量：边界必须落在 grapheme cluster 边界
            // （涵盖代理对、CRLF、组合重音、ZWJ emoji 序列）。
            let lower = range.location
            let upper = range.location + range.length
            if !MarkdownSourceMap.isGraphemeBoundary(lower, utf16: utf16, source: source)
                || !MarkdownSourceMap.isGraphemeBoundary(upper, utf16: utf16, source: source)
            {
                return .failure(.invalidRange)
            }
            // expectedText 必须与 base 实际文本一致
            let actual = (source as NSString).substring(with: range)
            if actual != patch.expectedText {
                return .failure(.expectedTextMismatch)
            }
            normalized.append(NormalizedPatch(patch: patch, lower: lower, upper: upper))
        }

        // patch 间重叠（含同位置多 insert 的应用顺序歧义）
        for i in 0..<normalized.count {
            for j in (i + 1)..<normalized.count where overlaps(normalized[i], normalized[j]) {
                return .failure(.overlappingPatches)
            }
        }

        // 按 upperBound 降序（同 upper 时按 lower 降序）应用，base 坐标不漂移
        normalized.sort { $0.upper != $1.upper ? $0.upper > $1.upper : $0.lower > $1.lower }
        var result = source
        for item in normalized {
            let nsRange = NSRange(location: item.lower, length: item.upper - item.lower)
            result = (result as NSString).replacingCharacters(
                in: nsRange, with: item.patch.replacement
            )
        }
        return .success(result)
    }

    private struct NormalizedPatch {
        let patch: SourcePatch
        let lower: Int
        let upper: Int
    }

    /// 重叠规范：空 range 视为一个点。
    /// - 两个空 range 同点 → 重叠（insert 顺序歧义）
    /// - 点严格落在另一 range 开区间内部 → 重叠
    /// - 点位于端点上 → 不重叠（降序应用无歧义）
    private static func overlaps(_ a: NormalizedPatch, _ b: NormalizedPatch) -> Bool {
        let aEmpty = a.lower == a.upper, bEmpty = b.lower == b.upper
        if aEmpty && bEmpty { return a.lower == b.lower }
        if aEmpty { return b.lower < a.lower && a.lower < b.upper }
        if bEmpty { return a.lower < b.lower && b.lower < a.upper }
        return a.lower < b.upper && b.lower < a.upper
    }
}
