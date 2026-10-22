import Foundation

// MARK: - T18 原生 Markdown 格式化(PLAN T18 / SPEC §8.2 / NE-15 / NE-25)
//
// `mdown-preserve-v1` 第一阶段:保护段字节不动(fence/缩进 code/math/
// frontmatter/raw HTML);非 hard-break 行尾空白清理;空行折叠为单空行;
// 表格边缘单空格、对齐线 ≥3 字符并保留 colon;prose 换行与既有 list
// 写法保持(不重排);幂等。未知语法除可解释的空白规则外逐字保留。
//
// 保护段经 LosslessMarkdownParser 的块类型判定;表格归一复用
// MarkdownTableModel 的解析(转义/code 内管道不拆)。

enum NativeMarkdownFormatter {

    /// 格式化全文;纯函数,不改权威正文(调用方经 source patch 应用)。
    static func format(_ source: String) -> String {
        let ns = source as NSString
        guard ns.length > 0 else { return source }
        let document = LosslessMarkdownParser().parse(source)

        // 1) 收集保护区间(行级):整块保护的种类
        var protectedLines = Set<Int>()
        for block in document.blocks {
            switch block.kind {
            case .codeFence, .codeIndented, .htmlBlock, .mathBlock, .frontmatter:
                // Block.startLine/endLine 是 1 基(parser `from + 1`),
                // rawLines 索引是 0 基——统一到 0 基再比对。
                for line in (block.startLine - 1)...(block.endLine - 1) {
                    protectedLines.insert(line)
                }
            default:
                break
            }
        }

        // 2) 行级处理:保护行原样;普通行清尾随空白(非 hard break)、
        //    连续空行折叠
        var lines = source.components(separatedBy: "\n")
        // components 会因末尾 \n 产生空尾元素;用NSString 行遍历保持字节真实
        lines.removeLast()  // 还原最后空元素,行内容按 NSString 重取
        var rawLines: [String] = []
        var loc = 0
        let total = ns.length
        while loc < total {
            let r = ns.lineRange(for: NSRange(location: loc, length: 0))
            var contentEnd = NSMaxRange(r)
            if contentEnd > r.location, ns.character(at: contentEnd - 1) == 0x0A {
                contentEnd -= 1
                if contentEnd > r.location, ns.character(at: contentEnd - 1) == 0x0D {
                    contentEnd -= 1
                }
            }
            rawLines.append(ns.substring(with: NSRange(location: r.location, length: contentEnd - r.location)))
            loc = NSMaxRange(r)
        }

        var outLines: [String] = []
        var blankRun = 0
        var lastWasText = false
        let lastIndex = rawLines.count - 1
        for (index, line) in rawLines.enumerated() {
            if protectedLines.contains(index) {
                outLines.append(line)
                blankRun = 0
                lastWasText = true
                continue
            }
            var processed = line
            // hard break(≥2 尾随空格)保留——但文档末行的尾随空白
            // 不构成 break(其后无内容),照常清理
            if !isHardBreak(processed) || index == lastIndex {
                processed = processed.replacingOccurrences(
                    of: "[ \\t]+$", with: "", options: .regularExpression)
            }
            if processed.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun >= 2 { continue }  // 折叠:连续空行只留一个
                outLines.append(processed.isEmpty ? "" : processed)
                lastWasText = false
            } else {
                blankRun = 0
                outLines.append(processed)
                lastWasText = true
            }
        }
        _ = lastWasText

        var joined = outLines.joined(separator: "\n")
        // 保持原文末尾换行形态
        if source.hasSuffix("\n") { joined += "\n" }

        // 3) 表格归一:按块定位 table,行级替换(复用 TableModel)
        return normalizeTables(joined, document: document, source: source)
    }

    private static func isHardBreak(_ line: String) -> Bool {
        line.hasSuffix("  ") || line.hasSuffix(" \t")
    }

    /// 表格行归一:cell 边缘单空格;对齐线 ≥3 dash + colon 保留。
    private static func normalizeTables(
        _ processed: String, document: LosslessMarkdownParser.Document, source: String
    ) -> String {
        guard
            document.blocks.contains(where: {
                if case .table = $0.kind { return true }; return false
            })
        else {
            return processed
        }
        // 在已处理文本上重新解析(processed 与 source 的表格内容一致,
        // 只是空白/空行可能变化;表格块按行号定位需要重解析)
        let doc2 = LosslessMarkdownParser().parse(processed)
        let ns2 = processed as NSString
        var result = processed
        for block in doc2.blocks {
            guard case .table = block.kind else { continue }
            let model = MarkdownTableModel.parse(source: processed, blockRange: block.rangeUTF16)
            guard !model.rows.isEmpty else { continue }
            var replacements: [(NSRange, String)] = []
            for row in model.rows {
                if row.isDelimiter {
                    let markers = model.alignments.enumerated().map { index, align -> String in
                        let dashes = String(repeating: "-", count: 3)
                        let existing =
                            row.cells.indices.contains(index)
                            ? row.cells[index].text : ""
                        let width = max(3, existing.filter { $0 == "-" }.count)
                        let d = String(repeating: "-", count: width)
                        _ = dashes
                        switch align {
                        case .none: return d
                        case .left: return ":" + d
                        case .center: return ":" + d + ":"
                        case .right: return d + ":"
                        }
                    }
                    replacements.append((row.rangeUTF16, MarkdownTableModel.rebuildLine(cells: markers)))
                } else {
                    replacements.append(
                        (row.rangeUTF16, MarkdownTableModel.rebuildLine(cells: row.cells.map(\.text))))
                }
            }
            for (range, text) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
                result = (result as NSString).replacingCharacters(in: range, with: text)
            }
        }
        return result
    }
}
