import Foundation

/// `mdown-preserve-v1`:在同一原文坐标系中计划格式化 patch。
/// 行尾、BOM 和受保护片段保留原字节；不重排 prose 或 list。
enum NativeMarkdownFormatter {
    /// format 发起时捕获的身份快照:同一 owner/URL/代际/revision/原文
    /// 仍然成立才允许应用结果——迟到的格式化结果不得覆盖用户后续输入
    /// 或已切换的笔记(SPEC §8.2"与当前不同则拒绝")。
    struct Snapshot {
        let owner: UUID
        let url: URL
        let generation: UInt64
        let revision: UInt64
        let source: String

        /// `currentOwner` 是发起方在应用时提供的**最新**令牌:任何新的
        /// format 发起都会替换它,旧快照的 owner 与之失配即拒绝——
        /// 快照内部令牌只用于一致性,不能与自身比较。
        func matches(
            currentOwner: UUID, url: URL, generation: UInt64,
            revision: UInt64, source: String
        ) -> Bool {
            self.owner == currentOwner && self.url == url && self.generation == generation
                && self.revision == revision && self.source == source
        }
    }

    private struct Line {
        let content: String
        let contentRange: NSRange
        let fullRange: NSRange
        let ending: String
    }

    static func format(_ source: String) -> String {
        let lines = sourceLines(source)
        guard !lines.isEmpty else { return source }
        // parser 只消费分析副本。实际 patch 始终指向带原始行尾的 source。
        let analysis = lines.map(\.content).joined(separator: "\n")
        let document = LosslessMarkdownParser().parse(analysis)
        let protected = protectedLines(in: document, lines: lines)
        var patches: [SourcePatch] = []
        var tableLines = Set<Int>()
        for block in document.blocks {
            guard case .table = block.kind else { continue }
            let model = MarkdownTableModel.parse(source: analysis, blockRange: block.rangeUTF16)
            guard model.rows.count >= 2, model.rows[1].isDelimiter else { continue }
            for (index, row) in model.rows.enumerated() {
                let lineIndex = block.startLine - 1 + index
                guard lines.indices.contains(lineIndex), !protected.contains(lineIndex) else { continue }
                let cells = row.cells.map { cell -> String in
                    let text = cell.text.trimmingCharacters(in: .whitespaces)
                    guard row.isDelimiter else { return text }
                    let dashes = String(repeating: "-", count: max(3, text.filter { $0 == "-" }.count))
                    return (text.hasPrefix(":") ? ":" : "") + dashes + (text.hasSuffix(":") ? ":" : "")
                }
                tableLines.insert(lineIndex)
                let replacement = MarkdownTableModel.rebuildLine(cells: cells)
                appendPatch(for: lines[lineIndex], replacement: replacement, to: &patches)
            }
        }

        var previousBlank = false
        for (index, line) in lines.enumerated() {
            guard !protected.contains(index), !tableLines.contains(index) else {
                previousBlank = false
                continue
            }
            let blank = line.content.trimmingCharacters(in: .whitespaces).isEmpty
            if blank {
                if previousBlank, mayCollapseBlank(at: index, lines: lines, document: document) {
                    patches.append(
                        SourcePatch(
                            rangeUTF16: line.fullRange,
                            expectedText: line.content + line.ending, replacement: ""))
                } else {
                    appendPatch(for: line, replacement: "", to: &patches)
                }
            } else {
                let trailingStart =
                    line.content.lastIndex(where: { $0 != " " && $0 != "\t" })
                    .map { line.content.index(after: $0) } ?? line.content.startIndex
                let suffix = line.content[trailingStart...]
                // Markdown hard break 只认两个及以上空格，tab 不替代空格。
                let hardBreak =
                    suffix.count >= 2 && suffix.allSatisfy { $0 == " " }
                    && index < lines.count - 1
                if !hardBreak {
                    appendPatch(for: line, replacement: String(line.content[..<trailingStart]), to: &patches)
                }
            }
            previousBlank = blank
        }
        switch MarkdownPatchApplier.applyPatches(patches, to: source) {
        case .success(let formatted): return formatted
        case .failure: return source  // 任何不确定映射保留整篇原文。
        }
    }

    private static func appendPatch(for line: Line, replacement: String, to patches: inout [SourcePatch]) {
        guard line.content != replacement else { return }
        patches.append(
            SourcePatch(
                rangeUTF16: line.contentRange, expectedText: line.content, replacement: replacement))
    }

    private static func sourceLines(_ source: String) -> [Line] {
        let ns = source as NSString
        var lines: [Line] = []
        var location = 0
        while location < ns.length {
            var start = 0
            var end = 0
            var contentEnd = 0
            ns.getLineStart(
                &start, end: &end, contentsEnd: &contentEnd,
                for: NSRange(location: location, length: 0))
            let contentRange = NSRange(location: start, length: contentEnd - start)
            lines.append(
                Line(
                    content: ns.substring(with: contentRange), contentRange: contentRange,
                    fullRange: NSRange(location: start, length: end - start),
                    ending: ns.substring(with: NSRange(location: contentEnd, length: end - contentEnd))))
            location = end
        }
        return lines
    }

    private static func protectedLines(
        in document: LosslessMarkdownParser.Document, lines: [Line]
    ) -> Set<Int> {
        var protected = Set<Int>()
        for block in document.blocks {
            switch block.kind {
            case .codeFence, .codeIndented, .htmlBlock, .mathBlock, .frontmatter:
                protected.formUnion((block.startLine - 1)...(block.endLine - 1))
            default: break
            }
        }
        // 多行 code span 以及链接定义保守地保护所跨整行；不触碰其空白。
        var inlineDelimiter = 0
        var inlineStart = 0
        for (index, line) in lines.enumerated() {
            if protected.contains(index) { continue }
            let trimmed = line.content.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]"),
                trimmed[trimmed.index(after: close)...].hasPrefix(":")
            {
                protected.insert(index)
                continue
            }
            let units = Array(line.content.utf16)
            var cursor = 0
            while cursor < units.count {
                if units[cursor] == 92, inlineDelimiter == 0 { cursor += 2; continue }
                guard units[cursor] == 96 else { cursor += 1; continue }
                let start = cursor
                while cursor < units.count, units[cursor] == 96 { cursor += 1 }
                let count = cursor - start
                if inlineDelimiter == 0 {
                    inlineDelimiter = count
                    inlineStart = index
                } else if count == inlineDelimiter {
                    if index > inlineStart { protected.formUnion(inlineStart..<index) }
                    inlineDelimiter = 0
                }
            }
            if inlineDelimiter > 0 { protected.insert(index) }
        }
        return protected
    }

    private static func mayCollapseBlank(
        at index: Int, lines: [Line], document: LosslessMarkdownParser.Document
    ) -> Bool {
        // list/quote 空行影响松紧列表及 continuation 归属，保守保留。
        if document.blocks.contains(where: {
            switch $0.kind {
            case .listItem, .quote:
                return index >= $0.startLine - 1 && index <= $0.endLine
            default: return false
            }
        }) {
            return false
        }
        let previous = lines[..<index].last { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
        let next = lines.dropFirst(index + 1).first { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
        for neighbor in [previous, next].compactMap({ $0 }) {
            let text = neighbor.content
            if text.hasPrefix(" ") || text.hasPrefix("\t") { return false }
            if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") || text.hasPrefix(">") {
                return false
            }
        }
        return true
    }
}
