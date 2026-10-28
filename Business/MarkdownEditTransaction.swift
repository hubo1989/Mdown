import Foundation

private func ascii16(_ c: Character) -> unichar {
    unichar(c.unicodeScalars.first!.value)
}

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

// MARK: - T11 行内格式与链接（纯 patch 规划，不触碰 view/Note）

/// 可经 source patch 创建/移除 delimiter 的行内格式。
public enum MarkdownInlineFormat: String, CaseIterable {
    case strong  // **
    case emphasis  // *
    case strikethrough  // ~~
    case code  // `

    var delimiter: String {
        switch self {
        case .strong: return "**"
        case .emphasis: return "*"
        case .strikethrough: return "~~"
        case .code: return "`"
        }
    }
}

/// 判定选中 source 区间两侧是否已有该格式的 delimiter：
/// 两侧紧贴同名 delimiter（code 仅认单 backtick）⇒ unwrap，否则 wrap。
enum InlineFormatPlanner {
    static func shouldUnwrap(
        _ kind: MarkdownInlineFormat, source: NSString, selected: NSRange
    ) -> Bool {
        let delim = kind.delimiter
        let delimLen = (delim as NSString).length
        // code unwrap 仅匹配单 backtick（`` `x` `` 能退；``x`` 的双 backtick 不动）
        if kind == .code,
            selected.location >= 1, NSMaxRange(selected) + 1 <= source.length
        {
            return source.character(at: selected.location - 1) == ascii16("`")
                && source.character(at: NSMaxRange(selected)) == ascii16("`")
                && (selected.location < 2 || source.character(at: selected.location - 2) != ascii16("`"))
                && (NSMaxRange(selected) + 1 >= source.length || source.character(at: NSMaxRange(selected) + 1) != ascii16("`"))
        }
        guard selected.location >= delimLen, NSMaxRange(selected) + delimLen <= source.length else {
            return false
        }
        let before = source.substring(with: NSRange(location: selected.location - delimLen, length: delimLen))
        let after = source.substring(with: NSRange(location: NSMaxRange(selected), length: delimLen))
        return before == delim && after == delim
    }

    /// wrap/unwrap 的 source patch 对。unwrap 时删除两侧 delimiter，
    /// wrap 时在两侧插入；selectionAfter = patch 应用后的选中区间。
    static func patches(
        _ kind: MarkdownInlineFormat, selected: NSRange, source: NSString, unwrap: Bool
    ) -> (patches: [SourcePatch], selectionAfter: NSRange) {
        let delim = kind.delimiter
        let delimLen = (delim as NSString).length
        if unwrap {
            let before = source.substring(with: NSRange(location: selected.location - delimLen, length: delimLen))
            let after = source.substring(with: NSRange(location: NSMaxRange(selected), length: delimLen))
            let patches = [
                SourcePatch(
                    rangeUTF16: NSRange(location: selected.location - delimLen, length: delimLen),
                    expectedText: before, replacement: ""),
                SourcePatch(
                    rangeUTF16: NSRange(location: NSMaxRange(selected), length: delimLen),
                    expectedText: after, replacement: ""),
            ]
            return (patches, NSRange(location: selected.location - delimLen, length: selected.length))
        }
        let patches = [
            SourcePatch(
                rangeUTF16: NSRange(location: selected.location, length: 0),
                expectedText: "", replacement: delim),
            SourcePatch(
                rangeUTF16: NSRange(location: NSMaxRange(selected), length: 0),
                expectedText: "", replacement: delim),
        ]
        return (patches, NSRange(location: selected.location + delimLen, length: selected.length))
    }
}

// MARK: - 链接扫描与安全 scheme（NE-12 未知语法保留；目标编辑白名单）

/// inline link `[label](target)` 在 source 中的定位（image `![a](b)` 同构，
/// 由 isImage 区分）。reference link `[a][b]` / footnote `[^1]` 不匹配，
/// 保留原样（NE-12）。
public struct InlineLinkSpan: Equatable {
    public let fullRangeUTF16: NSRange
    public let labelRangeUTF16: NSRange
    public let targetRangeUTF16: NSRange
    public let label: String
    public let target: String
    public let isImage: Bool
    public let title: String?
}

enum InlineLinkScanner {
    static func unescape(_ text: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        var result = ""
        var escaped = false
        for scalar in text.unicodeScalars {
            if escaped {
                if !scalar.isASCII || !punctuation.contains(scalar) { result.append("\\") }
                result.unicodeScalars.append(scalar)
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    /// 扫出 source 中全部 inline link（按出现顺序）。未配对/转义/`][`/
    /// `]:` 定义一律跳过，原文不动。
    static func scan(_ source: String) -> [InlineLinkSpan] {
        let ns = source as NSString
        var spans: [InlineLinkSpan] = []
        var i = 0
        while i < ns.length {
            let ch = ns.character(at: i)
            if ch == ascii16("\\") {
                i += 2
                continue
            }
            let isImage =
                ch == ascii16("!") && i + 1 < ns.length
                && ns.character(at: i + 1) == ascii16("[")
            guard ch == ascii16("[") || isImage else {
                i += 1
                continue
            }
            if let span = spanAt(i, in: ns, isImage: isImage) {
                spans.append(span)
                i = NSMaxRange(span.fullRangeUTF16)
            } else {
                i += 1
            }
        }
        return spans
    }

    static func span(at i: Int, in source: String) -> InlineLinkSpan? {
        let ns = source as NSString
        guard i < ns.length else { return nil }
        let isImage =
            ns.character(at: i) == ascii16("!")
            && i + 1 < ns.length && ns.character(at: i + 1) == ascii16("[")
        guard ns.character(at: i) == ascii16("[") || isImage else { return nil }
        return spanAt(i, in: ns, isImage: isImage)
    }

    private static func spanAt(_ i: Int, in ns: NSString, isImage: Bool) -> InlineLinkSpan? {
        let openBracket = i + (isImage ? 1 : 0)
        guard let labelEnd = findUnescaped("]", from: openBracket + 1, in: ns),
            labelEnd + 1 < ns.length,
            ns.character(at: labelEnd + 1) == ascii16("("),
            let closeParen = closingDestination(from: labelEnd + 2, in: ns)
        else { return nil }
        let labelStart = openBracket + 1
        let targetStart = labelEnd + 2
        let destinationRange = NSRange(location: targetStart, length: closeParen - targetStart)
        let destination = ns.substring(with: destinationRange) as NSString
        var lower = 0
        while lower < destination.length, CharacterSet.whitespaces.contains(UnicodeScalar(destination.character(at: lower)) ?? " ") { lower += 1 }
        var upper = lower
        if lower < destination.length, destination.character(at: lower) == ascii16("<") {
            lower += 1
            upper = lower
            while upper < destination.length, destination.character(at: upper) != ascii16(">") { upper += 1 }
            guard upper < destination.length else { return nil }
        } else {
            while upper < destination.length, !CharacterSet.whitespaces.contains(UnicodeScalar(destination.character(at: upper)) ?? " ") {
                if destination.character(at: upper) == ascii16("\\"), upper + 1 < destination.length { upper += 1 }
                upper += 1
            }
        }
        let targetRange = NSRange(location: targetStart + lower, length: upper - lower)
        let suffixStart = upper < destination.length && destination.character(at: upper) == ascii16(">") ? upper + 1 : upper
        let suffix = destination.substring(from: suffixStart).trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String?
        if suffix.isEmpty {
            title = nil
        } else if suffix.count >= 2, let first = suffix.first, first == "\"" || first == "'", suffix.last == first {
            title = unescape(String(suffix.dropFirst().dropLast()))
        } else {
            return nil
        }
        return InlineLinkSpan(
            fullRangeUTF16: NSRange(location: i, length: closeParen + 1 - i),
            labelRangeUTF16: NSRange(location: labelStart, length: labelEnd - labelStart),
            targetRangeUTF16: targetRange,
            label: ns.substring(with: NSRange(location: labelStart, length: labelEnd - labelStart)),
            target: ns.substring(with: targetRange),
            isImage: isImage, title: title
        )
    }

    private static func closingDestination(from start: Int, in text: NSString) -> Int? {
        var cursor = start
        var depth = 0
        var quote: unichar?
        var angled = false
        while cursor < text.length {
            let unit = text.character(at: cursor)
            if unit == ascii16("\\") { cursor += 2; continue }
            if let delimiter = quote {
                if unit == delimiter { quote = nil }
            } else if angled {
                if unit == ascii16(">") { angled = false }
            } else if unit == ascii16("<") {
                angled = true
            } else if unit == ascii16("\"") || unit == ascii16("'"),
                cursor > start, text.character(at: cursor - 1) == ascii16(" ")
            {
                quote = unit
            } else if unit == ascii16("(") {
                depth += 1
            } else if unit == ascii16(")") {
                if depth == 0 { return cursor }
                depth -= 1
            }
            cursor += 1
        }
        return nil
    }

    private static func findUnescaped(_ target: String, from: Int, in ns: NSString) -> Int? {
        let unit = ascii16(Character(target))
        var i = from
        while i < ns.length {
            let c = ns.character(at: i)
            if c == ascii16("\\") {
                i += 2
                continue
            }
            if c == unit { return i }
            i += 1
        }
        return nil
    }
}

/// link target 编辑的安全 scheme 白名单（NE-12/防注入）。
/// 无 scheme（相对路径/锚点/#fragment）允许；http/https/mailto 允许；
/// javascript/data/vbscript 及其他未知 scheme 拒绝。
enum MarkdownLinkSafety {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func isEditableTarget(_ target: String) -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return false }
        // scheme 语法：RFC 3986 ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"
        guard let colon = trimmed.firstIndex(of: ":") else { return true }  // 相对/锚点
        let scheme = String(trimmed[trimmed.startIndex..<colon]).lowercased()
        guard !scheme.isEmpty, scheme.first?.isLetter == true,
            scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return false }
        return allowedSchemes.contains(scheme)
    }
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
