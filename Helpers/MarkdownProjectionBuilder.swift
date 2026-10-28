import Foundation

/// T03 原型：display 投影构建。
/// 从 LosslessMarkdownParser.Document 的块内容生成投影 segments 与
/// display 文本；每个 segment 同时携带 source 与 display 的 UTF-16 range，
/// 双向偏移映射由此构成（段内线性）。所有坐标都是全文 source 坐标。
///
/// 原型支持：ATX heading / list / quote 的 marker 隐藏；inline 的
/// strong/emphasis/delimiter 成对 marker、code span、`[t](url)` 与
/// `![a](url)`（destination 隐藏）。未配对、转义、未知结构一律
/// plainFallback：原样显示，编辑语义回退 source（不猜测）。
/// Pending（不投影，整块原样）：table 单元格、html inline、autolink、
/// ref link 定义拆分、footnote、setext heading。
struct MarkdownProjectionBuilder {

    enum SegmentKind: Equatable {
        case text
        case hiddenMarker  // ** ` # > - 等 marker：显示空
        case codeSpan  // 行内 code（backtick 隐藏，内容等宽显示）
        case linkDestination  // (url) 部分：显示空
        case attachmentPlaceholder  // 图片：alt 作为占位显示
        case metadata  // frontmatter：整块原样
        case plainFallback  // 保护块/未识别：原样显示，编辑回退 source
        // T19 视觉：行内样式体(marker 隐藏,内容带渲染语义)
        case strongBody  // **x** 内容：粗体
        case emphasisBody  // *x* 内容：斜体
        case strikethroughBody  // ~~x~~ 内容：删除线
        case linkLabel  // [label](url) 的 label：链接色
        // 渲染块（mermaid/math/plantuml）：显示为附件占位字符，
        // 真实图由视图层挂 NSTextAttachment；点击附件切换源码/渲染态。
        case renderedBlock
    }

    struct Segment: Equatable {
        let kind: SegmentKind
        let sourceRangeUTF16: NSRange
        let displayRangeUTF16: NSRange
        /// 该段贡献的 display 文本（hidden 为空串）。
        let displayText: String
        /// G0 修复：配对结构的 opening marker（`**`/`` ` ``/`[` 的前半）。
        /// 边界歧义时 caret 应进入结构内容（next start），而非结构外部。
        var isOpening: Bool = false
    }

    struct Projection: Equatable {
        let display: String
        let segments: [Segment]

        /// display 偏移 → source 偏移（段内线性换算）。
        /// 边界歧义（hidden marker 与文字段共享同一边界）时：
        /// - opening marker 之后（进入结构）：取 next 内容段起点
        ///   （Typora 语义：在"码"前打字落在 code 内容内、闭 backtick 之前）
        /// - closing marker 之前（离开结构）：取前内容段末尾
        /// - 无结构歧义（纯文本边界）：取前段末尾。
        func sourceOffset(forDisplay offset: Int) -> Int? {
            if let inner = segments.first(where: {
                offset > $0.displayRangeUTF16.location && offset < NSMaxRange($0.displayRangeUTF16)
            }) {
                if inner.kind == .attachmentPlaceholder || inner.kind == .renderedBlock {
                    return NSMaxRange(inner.sourceRangeUTF16)
                }
                return linearMap(offset, from: inner.displayRangeUTF16, to: inner.sourceRangeUTF16)
            }
            // 边界匹配跳过 0 显示长的段：marker 段无显示表面，其端点不代表
            // 显示位置（code span 闭 backtick 前的 caret 必须归属 code 段末尾）。
            if let prevIndex = segments.lastIndex(where: {
                NSMaxRange($0.displayRangeUTF16) == offset && $0.displayRangeUTF16.length > 0
            }) {
                // G0 修复：检查是否有 opening marker 在 previous 与 next 内容之间。
                // 有则 caret 应进入结构内容（Typora：在"**粗**"前打字落在"粗"前）。
                var idx = prevIndex + 1
                var hasOpening = false
                while idx < segments.count && segments[idx].displayRangeUTF16.length == 0 {
                    if segments[idx].isOpening { hasOpening = true }
                    idx += 1
                }
                if hasOpening, idx < segments.count,
                    segments[idx].displayRangeUTF16.location == offset,
                    segments[idx].displayRangeUTF16.length > 0
                {
                    return segments[idx].sourceRangeUTF16.location
                }
                // closing boundary 或纯文本边界：前段末尾
                return NSMaxRange(segments[prevIndex].sourceRangeUTF16)
            }
            if let next = segments.last(where: {
                $0.displayRangeUTF16.location == offset && $0.displayRangeUTF16.length > 0
            }) {
                return next.sourceRangeUTF16.location
            }
            return nil
        }

        /// source 偏移 → display 偏移（边界歧义同上取后段）。
        func displayOffset(forSource offset: Int) -> Int? {
            if let inner = segments.first(where: {
                offset > $0.sourceRangeUTF16.location && offset < NSMaxRange($0.sourceRangeUTF16)
            }) {
                return linearMap(offset, from: inner.sourceRangeUTF16, to: inner.displayRangeUTF16)
            }
            if let boundary = segments.last(where: { $0.sourceRangeUTF16.location == offset }) {
                return boundary.displayRangeUTF16.location
            }
            if let tail = segments.last(where: { NSMaxRange($0.sourceRangeUTF16) == offset }) {
                return NSMaxRange(tail.displayRangeUTF16)
            }
            return nil
        }

        private func linearMap(_ offset: Int, from: NSRange, to: NSRange) -> Int {
            let into = offset - from.location
            let ratio = from.length == 0 ? 0 : Double(into) / Double(from.length)
            return to.location + Int((Double(to.length) * ratio).rounded())
        }
    }

    /// 渲染块显示态（Typora 交互：默认只显示渲染图，点击展开源码+图）。
    enum RenderedBlockMode: Equatable {
        case collapsed  // 只显示渲染图（附件占位字符）
        case expanded  // 上方源码 + 下方渲染图
    }

    /// 对单个块构建投影。display 坐标从 0 开始（每块独立投影；视图拼接
    /// 时按行位移，T10 接入）。
    /// `renderedMode` 仅对 mermaid/math/plantuml 等渲染块生效（PRD ND-02/03）。
    func buildProjection(
        for block: LosslessMarkdownParser.Block, in document: LosslessMarkdownParser.Document,
        renderedMode: RenderedBlockMode = .collapsed
    ) -> Projection {
        let source = document.source
        let blockText = (source as NSString).substring(with: block.rangeUTF16)

        switch block.kind {
        case .frontmatter:
            return plain(blockText, kind: .metadata, base: block.rangeUTF16.location)
        case .codeFence(let info):
            if Self.isRenderableBlock(kind: block.kind, info: info) {
                return renderedBlockProjection(
                    blockText: blockText, block: block, mode: renderedMode)
            }
            return plain(blockText, kind: .plainFallback, base: block.rangeUTF16.location)
        case .codeIndented, .htmlBlock, .mathBlock, .table, .thematicBreak, .blank:
            return plain(blockText, kind: .plainFallback, base: block.rangeUTF16.location)
        case .heading(let level):
            let text = blockText as NSString
            var markerLen = 0
            while markerLen < text.length,
                text.character(at: markerLen) == asciiUnit(" ") || text.character(at: markerLen) == asciiUnit("\t")
            {
                markerLen += 1
            }
            markerLen += level
            // 裸标题 marker 不带分隔空格；换行仍是可编辑的显示位置。
            while markerLen < text.length,
                text.character(at: markerLen) == asciiUnit(" ") || text.character(at: markerLen) == asciiUnit("\t")
            {
                markerLen += 1
            }
            // marker 段用文档绝对坐标（与 inlineSegments 一致）：块相对 0 会
            // 让非首块 heading 的 marker 指向文档开头。display 坐标统一由
            // finalize 重算（inlineSegments 已各自 finalize，重算幂等）。
            var segments = [
                Segment(
                    kind: .hiddenMarker,
                    sourceRangeUTF16: NSRange(location: block.rangeUTF16.location, length: markerLen),
                    displayRangeUTF16: NSRange(location: -1, length: 0),
                    displayText: ""
                )
            ]
            segments.append(contentsOf: inlineSegments(of: blockText, contentStart: markerLen, block: block))
            finalizeDisplayRanges(&segments)
            return Projection(display: segments.displayText, segments: segments)
        case .listItem, .quote:
            // 多行容器逐行处理：行前缀（quote 层 + 内层 list marker）隐藏，
            // 行内容走 inline
            return lineWiseProjection(blockText: blockText, block: block)
        case .paragraph:
            let segments = inlineSegments(of: blockText, contentStart: 0, block: block)
            return Projection(display: segments.displayText, segments: segments)
        }
    }

    private func asciiUnit(_ c: Character) -> UInt16 {
        UInt16(c.asciiValue ?? 0)
    }

    private func lineWiseProjection(
        blockText: String, block: LosslessMarkdownParser.Block
    ) -> Projection {
        let ns = blockText as NSString
        var segments: [Segment] = []
        var lineStart = 0
        while lineStart < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = ns.substring(with: lineRange)
            let parsed = MarkdownBlockModel.parseLine(
                line as NSString, lineRange: NSRange(location: 0, length: line.utf16.count))
            let prefixLen = parsed.prefixLength
            // task 勾选字面（`[x] `/`[ ] `）保持可见：T14 原生勾选框落地前，
            // 勾选状态必须可见可定位（NE-07）。
            var hiddenLen = prefixLen
            if let task = parsed.task {
                let bracketRel = task.checkOffsetUTF16 - 1
                if bracketRel >= 0, bracketRel < prefixLen {
                    hiddenLen = bracketRel
                }
            }
            segments.append(
                Segment(
                    kind: .hiddenMarker,
                    sourceRangeUTF16: NSRange(location: block.rangeUTF16.location + lineStart, length: hiddenLen),
                    displayRangeUTF16: NSRange(location: -1, length: 0), displayText: "",
                    // T12：行级 marker 是 opening——上一行末与下一行内容首共享
                    // 的 display 边界点，caret 归属下一行内容首（marker 后），
                    // 否则结构命令后落在新行首的输入会插到上一行尾。
                    isOpening: true
                ))
            if hiddenLen < prefixLen {
                segments.append(
                    Segment(
                        kind: .text,
                        sourceRangeUTF16: NSRange(
                            location: block.rangeUTF16.location + lineStart + hiddenLen,
                            length: prefixLen - hiddenLen),
                        displayRangeUTF16: NSRange(location: -1, length: prefixLen - hiddenLen),
                        displayText: ns.substring(
                            with: NSRange(location: lineStart + hiddenLen, length: prefixLen - hiddenLen))
                    ))
            }
            segments.append(
                contentsOf: inlineSegments(
                    of: blockText, contentStart: lineStart + prefixLen,
                    block: block, limit: NSMaxRange(lineRange)
                ))
            lineStart = NSMaxRange(lineRange)
        }
        var finalized = segments
        finalizeDisplayRanges(&finalized)
        return Projection(display: finalized.displayText, segments: finalized)
    }

    // MARK: - inline 扫描（坐标相对 blockText；返回前统一加块起点）

    private func inlineSegments(
        of blockText: String, contentStart: Int, block: LosslessMarkdownParser.Block, limit: Int? = nil
    ) -> [Segment] {
        let ns = blockText as NSString
        let total = min(ns.length, limit ?? ns.length)
        var segments: [Segment] = []
        var cursor = contentStart
        let base = block.rangeUTF16.location

        func appendText(_ from: Int, _ to: Int) {
            guard to > from else { return }
            segments.append(
                Segment(
                    kind: .text,
                    sourceRangeUTF16: NSRange(location: base + from, length: to - from),
                    displayRangeUTF16: NSRange(location: -1, length: to - from),  // display 坐标在 finalize 填
                    displayText: ns.substring(with: NSRange(location: from, length: to - from))
                ))
        }

        while cursor < total {
            let ch = ns.character(at: cursor)
            // 转义：下一个字符原样并入文本
            if ch == asciiUnit("\\"), cursor + 1 < total,
                let scalar = UnicodeScalar(ns.character(at: cursor + 1)), CharacterSet.punctuationCharacters.union(.symbols).contains(scalar),
                scalar.isASCII
            {
                segments.append(
                    Segment(
                        kind: .text,
                        sourceRangeUTF16: NSRange(location: base + cursor, length: 2),
                        displayRangeUTF16: NSRange(location: -1, length: 1), displayText: String(scalar)))
                cursor += 2
                continue
            }
            // code span（仅 backtick 字符触发扫描；limit 通常为行尾，
            // 跨行配对会把后行内容吞进本行投影并重复显示）
            if ch == asciiUnit("`") {
                if let span = codeSpanRange(ns, from: cursor, limit: total) {
                    let openEnd = span.openEnd
                    let closeStart = span.closeStart
                    let closeEnd = span.closeEnd
                    segments.append(
                        Segment(
                            kind: .hiddenMarker,
                            sourceRangeUTF16: NSRange(location: base + cursor, length: openEnd - cursor),
                            displayRangeUTF16: NSRange(location: -1, length: 0),
                            displayText: "", isOpening: true
                        ))
                    segments.append(
                        Segment(
                            kind: .codeSpan,
                            sourceRangeUTF16: NSRange(location: base + openEnd, length: closeStart - openEnd),
                            displayRangeUTF16: NSRange(location: -1, length: closeStart - openEnd),
                            displayText: ns.substring(with: NSRange(location: openEnd, length: closeStart - openEnd))
                        ))
                    segments.append(
                        Segment(
                            kind: .hiddenMarker,
                            sourceRangeUTF16: NSRange(location: base + closeStart, length: closeEnd - closeStart),
                            displayRangeUTF16: NSRange(location: -1, length: 0),
                            displayText: ""
                        ))
                    cursor = closeEnd
                    continue
                }
            }
            // emphasis / strikethrough 成对 marker
            // G0 性能修复：仅 *_~ 字符才尝试 marker 匹配（跳过 95%+ 字符）
            if ch == asciiUnit("*") || ch == asciiUnit("_") || ch == asciiUnit("~") {
                if let marker = emphasisMarker(at: cursor, in: ns, limit: total) {
                    if let close = findClosing(marker: marker, from: cursor + marker.utf16.count, in: ns, limit: total) {
                        let openLen = marker.utf16.count
                        segments.append(
                            Segment(
                                kind: .hiddenMarker,
                                sourceRangeUTF16: NSRange(location: base + cursor, length: openLen),
                                displayRangeUTF16: NSRange(location: -1, length: 0),
                                displayText: "", isOpening: true
                            ))
                        let contentLen = close - (cursor + openLen)
                        // T19 视觉:按 marker 分型(~=删除线;>=2 星/下划线=
                        // 粗体;单个=斜体)——渲染层据此上 NSFont trait。
                        let bodyKind: SegmentKind
                        if marker.hasPrefix("~") {
                            bodyKind = .strikethroughBody
                        } else if openLen >= 2 {
                            bodyKind = .strongBody
                        } else {
                            bodyKind = .emphasisBody
                        }
                        segments.append(
                            Segment(
                                kind: bodyKind,
                                sourceRangeUTF16: NSRange(location: base + cursor + openLen, length: contentLen),
                                displayRangeUTF16: NSRange(location: -1, length: contentLen),
                                displayText: ns.substring(with: NSRange(location: cursor + openLen, length: contentLen))
                            ))
                        segments.append(
                            Segment(
                                kind: .hiddenMarker,
                                sourceRangeUTF16: NSRange(location: base + close, length: openLen),
                                displayRangeUTF16: NSRange(location: -1, length: 0),
                                displayText: ""
                            ))
                        cursor = close + openLen
                        continue
                    }
                }
            }
            // link / image
            if ch == asciiUnit("[") || (ch == asciiUnit("!") && cursor + 1 < total && ns.character(at: cursor + 1) == asciiUnit("[")) {
                if let segs = linkSegments(at: cursor, in: ns, isImage: ch == asciiUnit("!"), base: base, limit: total) {
                    segments.append(contentsOf: segs)
                    let last = segs.last!
                    cursor = last.sourceRangeUTF16.location - base + last.sourceRangeUTF16.length
                    continue
                }
            }
            // 普通字符：前进到下一个潜在结构起点（文本段由 mergeTextRuns 合并）
            cursor += 1
        }

        segments = mergeTextRuns(into: segments, blockText: ns, contentStart: contentStart, base: base, limit: total)

        var finalized = segments
        finalizeDisplayRanges(&finalized)
        return finalized.map { seg in
            Segment(
                kind: seg.kind,
                sourceRangeUTF16: seg.sourceRangeUTF16,
                displayRangeUTF16: seg.displayRangeUTF16,
                displayText: seg.displayText,
                isOpening: seg.isOpening
            )
        }
    }

    // MARK: - 辅助

    private func plain(_ text: String, kind: SegmentKind, base: Int) -> Projection {
        // sourceRange 用文档绝对坐标（与其他投影一致）：textDidChange 等消费方
        // 把段坐标当文档全局用，块相对 0 会让非首块编辑全部命中文档开头。
        let segment = Segment(
            kind: kind,
            sourceRangeUTF16: NSRange(location: base, length: text.utf16.count),
            displayRangeUTF16: NSRange(location: 0, length: text.utf16.count),
            displayText: text
        )
        return Projection(display: text, segments: [segment])
    }

    /// 是否为可渲染块(PRD ND-03/08)。
    /// 当前仅 mermaid——host 有在线渲染产物;plantuml 待接既有
    /// RenderedBlockExportController 管线后再纳入,先行占位只会留下
    /// 永空的附件位。math 暂不走渲染占位——既有测试合同要求 math
    /// 投影保留源码原文(MarkdownRawBlockEditingTests),且 math→图
    /// 转换需 HTML 产物路径。
    static func isRenderableBlock(kind: LosslessMarkdownParser.BlockKind, info: String) -> Bool {
        switch kind {
        case .codeFence(let fenceInfo):
            let lang = fenceInfo.trimmingCharacters(in: .whitespaces).lowercased()
            return lang == "mermaid"
        default:
            return false
        }
    }

    /// 剥掉 codeFence 的开/闭围栏行,返回围栏内原文(行界含 \r 的按
    /// 原字节保留,行间换行统一 \n)。围栏识别与 consumeFence 同规则:
    /// 同字符、闭长度 ≥ 开长度、闭行仅围栏字符与空白;无闭围栏(EOF
    /// 截断)时内容到块尾。这是渲染请求的 source 形态(host 合同,与
    /// 主预览 cmark 输出一致):围栏行不属于图源码,mermaid 拿到
    /// ```` ```mermaid ```` 行必然解析失败。
    static func fenceContent(of blockText: String) -> String {
        var lines = blockText.components(separatedBy: "\n")
        let endsWithNewline = lines.last?.isEmpty == true
        if endsWithNewline { lines.removeLast() }
        guard let open = lines.first else { return "" }
        let openTrimmed = open.trimmingCharacters(in: .whitespaces)
        guard let openChar = openTrimmed.first, openChar == "`" || openChar == "~",
            openTrimmed.prefix { $0 == openChar }.count >= 3
        else { return blockText }
        let openLen = openTrimmed.prefix { $0 == openChar }.count
        var end = lines.count
        if lines.count > 1 {
            for i in 1..<lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.prefix { $0 == openChar }.count >= openLen,
                    trimmed.allSatisfy({ $0 == openChar || $0.isWhitespace })
                {
                    end = i
                    break
                }
            }
        }
        var content = lines[1..<end].joined(separator: "\n")
        if endsWithNewline { content += "\n" }
        return content
    }

    /// 渲染块投影：collapsed 只显示附件占位字符；expanded 显示源码+附件。
    /// 附件占位字符固定为 U+FFFC（NSAttachmentCharacter），视图层在该
    /// 字符上挂 NSTextAttachment 显示真实渲染图。
    /// sourceRange 始终覆盖整块原文，display↔source 映射不因渲染产物改变。
    private func renderedBlockProjection(
        blockText: String, block: LosslessMarkdownParser.Block, mode: RenderedBlockMode
    ) -> Projection {
        let base = block.rangeUTF16.location
        let attachmentChar = "\u{FFFC}"
        switch mode {
        case .collapsed:
            // 只显示附件：display 1 字符，映射到整块 source。
            let segment = Segment(
                kind: .renderedBlock,
                sourceRangeUTF16: block.rangeUTF16,
                displayRangeUTF16: NSRange(location: 0, length: 1),
                displayText: attachmentChar
            )
            return Projection(display: attachmentChar, segments: [segment])
        case .expanded:
            // 源码在上、渲染图在下（Typora 点击展开态）。
            // 源码段走 plainFallback（编辑语义回退 source），附件段在末尾。
            let sourceLen = blockText.utf16.count
            var segments: [Segment] = [
                Segment(
                    kind: .plainFallback,
                    sourceRangeUTF16: block.rangeUTF16,
                    displayRangeUTF16: NSRange(location: 0, length: sourceLen),
                    displayText: blockText
                ),
                Segment(
                    kind: .renderedBlock,
                    sourceRangeUTF16: NSRange(location: NSMaxRange(block.rangeUTF16), length: 0),
                    displayRangeUTF16: NSRange(location: sourceLen, length: 1),
                    displayText: attachmentChar
                ),
            ]
            return Projection(display: blockText + attachmentChar, segments: segments)
        }
    }

    /// 行首 list marker 的长度：缩进 + 恰好一个合法 marker（`-`/`+`/`*` 或
    /// `数字.`/`数字)`）+ 尾随空白。之前的实现把 marker 后连续的 `*`/数字/
    /// `.` 一并当前缀，`- **bold**` 会隐藏 "- **" 留下残缺的 "bold**"。
    /// 无 marker 的行（懒延续行、容器内空行）必须返回 0。
    private func listItemMarkerLength(_ blockText: String) -> Int {
        let t = blockText as NSString
        var i = 0
        while i < t.length {
            let c = t.character(at: i)
            if c == asciiUnit(" ") || c == asciiUnit("\t") {
                i += 1
            } else {
                break
            }
        }
        let indent = i
        func trailingSpaces(_ from: Int) -> Int {
            var j = from
            while j < t.length {
                let c = t.character(at: j)
                if c == asciiUnit(" ") || c == asciiUnit("\t") {
                    j += 1
                } else {
                    break
                }
            }
            return j
        }

        if indent < t.length {
            let c = t.character(at: indent)
            // 无序：单个 -/+/*（后跟空格，或行尾/行末的裸 marker 空项）
            if c == asciiUnit("-") || c == asciiUnit("+") || c == asciiUnit("*") {
                let after = indent + 1
                if after < t.length {
                    let n = t.character(at: after)
                    if n == asciiUnit(" ") || n == asciiUnit("\t") {
                        return trailingSpaces(after)
                    }
                    // 裸 marker（行尾换行或块末）合法；紧贴内容（"-x"）不是 marker
                    return (n == asciiUnit("\n") || n == asciiUnit("\r")) ? after : 0
                }
                return after
            }
            // 有序：数字串 + ./) + 空格
            var digits = 0
            var j = indent
            while j < t.length, t.character(at: j).isDigitScalar {
                digits += 1
                j += 1
            }
            if digits > 0, j < t.length,
                t.character(at: j) == asciiUnit(".") || t.character(at: j) == asciiUnit(")")
            {
                j += 1
                if j < t.length, t.character(at: j) == asciiUnit(" ") || t.character(at: j) == asciiUnit("\t") {
                    return trailingSpaces(j)
                }
                // "2." 行尾是空项；"1.x" 紧贴内容不是 marker
                return (j < t.length && (t.character(at: j) == asciiUnit("\n") || t.character(at: j) == asciiUnit("\r"))) || j == t.length
                    ? j : 0
            }
        }
        return 0
    }

    /// 行首 quote 前缀（`>` + 缩进）由 `MarkdownBlockModel.parseLine` 的
    /// quote 分支处理（含混合嵌套的内层 list/task 前缀）。

    private struct CodeSpanRange {
        let openEnd: Int
        let closeStart: Int
        let closeEnd: Int
    }

    private func codeSpanRange(_ ns: NSString, from: Int, limit: Int) -> CodeSpanRange? {
        var openLen = 0
        while from + openLen < limit, ns.character(at: from + openLen) == asciiUnit("`") {
            openLen += 1
        }
        guard openLen > 0 else { return nil }
        var i = from + openLen
        while i < limit {
            if ns.character(at: i) == asciiUnit("`") {
                var closeLen = 0
                while i + closeLen < limit, ns.character(at: i + closeLen) == asciiUnit("`") {
                    closeLen += 1
                }
                if closeLen == openLen {
                    return CodeSpanRange(openEnd: from + openLen, closeStart: i, closeEnd: i + closeLen)
                }
                i += closeLen
            } else {
                i += 1
            }
        }
        return nil
    }

    /// 预计算 emphasis marker UTF-16 模式（避免每次调用创建数组）。
    private static let emphasisPatterns: [(String, [UInt16])] = [
        "**", "__", "~~", "*", "_",
    ].map { ($0, Array($0.utf16)) }

    private func emphasisMarker(at i: Int, in ns: NSString, limit: Int) -> String? {
        for (marker, units) in Self.emphasisPatterns {
            guard i + units.count <= limit else { continue }
            var matches = true
            for (k, unit) in units.enumerated() where ns.character(at: i + k) != unit {
                matches = false
                break
            }
            if matches { return marker }
        }
        return nil
    }

    private func findClosing(marker: String, from: Int, in ns: NSString, limit: Int) -> Int? {
        let units = Array(marker.utf16)
        let m = units.count
        var i = from
        while i + m <= limit {
            // 奇数个前导反斜杠转义的 marker 是字面量，不是闭符（\*a\*b* 取末尾 *）
            if i > 0, ns.character(at: i - 1) == asciiUnit("\\") {
                var backslashes = 0
                var j = i - 1
                while j >= 0, ns.character(at: j) == asciiUnit("\\") {
                    backslashes += 1
                    j -= 1
                }
                if backslashes % 2 == 1 {
                    i += 1
                    continue
                }
            }
            var matches = true
            for (k, unit) in units.enumerated() where ns.character(at: i + k) != unit {
                matches = false
                break
            }
            if matches { return i }
            i += 1
        }
        return nil
    }

    private func linkSegments(at i: Int, in ns: NSString, isImage: Bool, base: Int, limit: Int) -> [Segment]? {
        if isImage, let span = InlineLinkScanner.span(at: i, in: ns as String), NSMaxRange(span.fullRangeUTF16) <= limit {
            return [
                Segment(
                    kind: .attachmentPlaceholder,
                    sourceRangeUTF16: NSRange(location: base + i, length: span.fullRangeUTF16.length),
                    displayRangeUTF16: NSRange(location: -1, length: 0),
                    displayText: span.label.isEmpty ? "[图]" : InlineLinkScanner.unescape(span.label))
            ]
        }
        let openBracket = i + (isImage ? 1 : 0)
        guard let labelEnd = findUnescaped("]", from: openBracket + 1, in: ns, limit: limit),
            labelEnd + 1 < limit,
            ns.character(at: labelEnd + 1) == asciiUnit("("),
            let closeParen = findUnescaped(")", from: labelEnd + 2, in: ns, limit: limit)
        else {
            return nil
        }
        let labelStart = openBracket + 1
        let labelRange = NSRange(location: labelStart, length: labelEnd - labelStart)
        var segments: [Segment] = []
        if isImage {
            segments.append(
                Segment(
                    kind: .hiddenMarker,
                    sourceRangeUTF16: NSRange(location: base + i, length: openBracket - i),
                    displayRangeUTF16: NSRange(location: -1, length: 0), displayText: ""
                ))
        }
        segments.append(
            Segment(
                kind: .hiddenMarker,
                sourceRangeUTF16: NSRange(location: base + openBracket, length: 1),
                displayRangeUTF16: NSRange(location: -1, length: 0), displayText: "",
                isOpening: true
            ))
        segments.append(
            Segment(
                kind: isImage ? .attachmentPlaceholder : .linkLabel,
                sourceRangeUTF16: NSRange(location: base + labelStart, length: labelRange.length),
                displayRangeUTF16: NSRange(location: -1, length: labelRange.length),
                displayText: isImage && labelRange.length == 0 ? "[图]" : ns.substring(with: labelRange)
            ))
        segments.append(
            Segment(
                kind: .hiddenMarker,
                sourceRangeUTF16: NSRange(location: base + labelEnd, length: 1),
                displayRangeUTF16: NSRange(location: -1, length: 0), displayText: ""
            ))
        segments.append(
            Segment(
                kind: .linkDestination,
                sourceRangeUTF16: NSRange(location: base + labelEnd + 1, length: closeParen + 1 - (labelEnd + 1)),
                displayRangeUTF16: NSRange(location: -1, length: 0), displayText: ""
            ))
        return segments
    }

    private func findUnescaped(_ target: String, from: Int, in ns: NSString, limit: Int) -> Int? {
        let unit = UInt16(target.utf8.first!)
        var i = from
        while i < limit {
            let c = ns.character(at: i)
            if c == asciiUnit("\\") {
                i += 2
                continue
            }
            if c == unit { return i }
            i += 1
        }
        return nil
    }

    // MARK: - 文本合并与 display 坐标 finalize

    private func mergeTextRuns(into structured: [Segment], blockText: NSString, contentStart: Int, base: Int, limit: Int? = nil) -> [Segment] {
        // 以 structured 的 sourceRange 为界，把未覆盖的区间补成 text 段
        let upperBound = limit ?? blockText.length
        var result: [Segment] = []
        var cursor = contentStart
        let sorted = structured.sorted { $0.sourceRangeUTF16.location < $1.sourceRangeUTF16.location }
        for seg in sorted {
            let relStart = seg.sourceRangeUTF16.location - base
            if relStart > cursor {
                result.append(
                    Segment(
                        kind: .text,
                        sourceRangeUTF16: NSRange(location: base + cursor, length: relStart - cursor),
                        displayRangeUTF16: NSRange(location: -1, length: relStart - cursor),
                        displayText: blockText.substring(with: NSRange(location: cursor, length: relStart - cursor))
                    ))
            }
            result.append(seg)
            cursor = relStart + seg.sourceRangeUTF16.length
        }
        if cursor < upperBound {
            result.append(
                Segment(
                    kind: .text,
                    sourceRangeUTF16: NSRange(location: base + cursor, length: upperBound - cursor),
                    displayRangeUTF16: NSRange(location: -1, length: upperBound - cursor),
                    displayText: blockText.substring(with: NSRange(location: cursor, length: upperBound - cursor))
                ))
        }
        return result
    }

    private func finalizeDisplayRanges(_ segments: inout [Segment]) {
        var offset = 0
        for i in 0..<segments.count {
            let seg = segments[i]
            segments[i] = Segment(
                kind: seg.kind,
                sourceRangeUTF16: seg.sourceRangeUTF16,
                displayRangeUTF16: NSRange(location: offset, length: seg.displayText.utf16.count),
                displayText: seg.displayText,
                isOpening: seg.isOpening
            )
            offset += seg.displayText.utf16.count
        }
    }
}

// MARK: - 小型构造辅助

private extension Array where Element == MarkdownProjectionBuilder.Segment {
    init(kind: MarkdownProjectionBuilder.SegmentKind, sourceRange: NSRange, in blockText: String) {
        let ns = blockText as NSString
        let text = ns.substring(
            with: NSRange(
                location: sourceRange.location,
                length: Swift.min(sourceRange.length, ns.length - sourceRange.location)
            ))
        self.init()
        append(
            MarkdownProjectionBuilder.Segment(
                kind: kind,
                sourceRangeUTF16: sourceRange,
                displayRangeUTF16: NSRange(location: -1, length: kind == .hiddenMarker ? 0 : sourceRange.length),
                displayText: kind == .hiddenMarker ? "" : text
            ))
    }

    var displayText: String { reduce("") { $0 + $1.displayText } }
}

private extension UInt16 {
    var isDigitScalar: Bool { self >= 0x30 && self <= 0x39 }  // '0'...'9'
}
