import AppKit

// MARK: - T19 preview-parity 外观(RichMarkdownTextView 扩展)
//
// WYSIWYG 的排版参数对齐 DownView.bundle 预览(index.html / base.css /
// typography.css / theme-*.css 的实测值),两者共用同一套常量:
// - 正文 15px 基准(经 html font-size 缩放,此处直接用注入的字号),
//   line-height 1.74;
// - H1=2em / H2=1.5em / H3=1.25em / H4-6=1em,加粗,行高 1.8,
//   段前 1.6em/0.6em、段后 0.8em/0.6em;
// - 链接色 浅色 #0C6ADA / 深色 #1D9BF0;code 背景 浅色 #f7f7f7 /
//   深色 #282e33;正文色 浅色 #262626 / 深色 #E7E9EA;
// - 列表 marker 以 headIndent + 自绘 overlay 还原(仅布局/绘制属性,
//   display↔source 映射与 source 字节完全不变)。

extension RichMarkdownTextView {

    // MARK: - 预览对齐常量(来源:DownView.bundle css 实测)

    /// 正文行高(typography.css .heti line-height)。
    static let previewLineHeightMultiple: CGFloat = 1.74
    /// 标题行高(typography.css headings line-height)。
    static let previewHeadingLineHeightMultiple: CGFloat = 1.8
    /// 标题 em 倍率(typography.css h1..h6 font-size)。
    static let previewHeadingScales: [CGFloat] = [2.0, 1.5, 1.25, 1.0, 1.0, 1.0]

    /// 正文文字色(index.html :root --text-color / .darkmode)。
    var previewTextColour: NSColor {
        AppEnvironment.current.userData.isDark
            ? NSColor(calibratedRed: 0xE7 / 255, green: 0xE9 / 255, blue: 0xEA / 255, alpha: 1)
            : NSColor(calibratedRed: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255, alpha: 1)
    }

    /// 链接色(theme-light.css --link-color / theme-dark.css --link-color)。
    var previewLinkColour: NSColor {
        AppEnvironment.current.userData.isDark
            ? NSColor(calibratedRed: 0x1D / 255, green: 0x9B / 255, blue: 0xF0 / 255, alpha: 1)
            : NSColor(calibratedRed: 0x0C / 255, green: 0x6A / 255, blue: 0xDA / 255, alpha: 1)
    }

    /// 代码背景(index.html --code-bg)。
    var previewCodeBackground: NSColor {
        AppEnvironment.current.userData.isDark
            ? NSColor(calibratedRed: 0x28 / 255, green: 0x2E / 255, blue: 0x33 / 255, alpha: 1)
            : NSColor(calibratedRed: 0xF7 / 255, green: 0xF7 / 255, blue: 0xF7 / 255, alpha: 1)
    }

    /// 引用文字色(typography.css blockquote color: --text-secondary 近似)。
    var previewQuoteColour: NSColor {
        previewTextColour.withAlphaComponent(0.62)
    }

    // MARK: - 段落样式

    /// 正文段落:行高 1.74,保留默认首行缩进 0。
    func makeBaseParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = Self.previewLineHeightMultiple
        return style
    }

    /// 标题段落:行高 1.8 + 分级段距。预览 CSS 的 margin(em)相对的是
    /// html 基准字号(bodyFont = 注入的 previewFontSize),不是标题自身
    /// 字号——H1 顶距 = 1.6 × 基准,而非 1.6 × H1 字号。
    func makeHeadingParagraphStyle(level: Int) -> NSMutableParagraphStyle {
        let style = makeBaseParagraphStyle()
        style.lineHeightMultiple = Self.previewHeadingLineHeightMultiple
        let em = bodyFont.pointSize
        if level <= 2 {
            style.paragraphSpacingBefore = em * 1.6
            style.paragraphSpacing = em * 0.8
        } else {
            style.paragraphSpacingBefore = em * 0.6
            style.paragraphSpacing = em * 0.6
        }
        return style
    }

    // MARK: - 列表 marker(headIndent + 自绘 overlay)

    /// 每个 list 块的悬挂缩进与 marker 文本(ordered 计序号,unordered 圆点)。
    struct PreviewListMarker {
        let depth: Int
        let ordinal: Int
        let ordered: Bool
        var text: String { ordered ? "\(ordinal)." : "•" }
        /// 深度基准缩进(每层 20pt,首层从容器边缘起)。
        var baseIndent: CGFloat { CGFloat(max(depth - 1, 0)) * 20 }
        /// marker 自身宽度(序号宽于圆点)。
        var markerWidth: CGFloat { ordered ? 24 : 12 }
        /// 整段 headIndent:marker 宽 + 6pt 间距。
        var headIndent: CGFloat { baseIndent + markerWidth + 6 }
    }

    /// 按文档顺序为 list 块计算 marker(序号在同深度连续 list 内递增,
    /// 遇到非 list/quote 块或更浅层重置)。纯计算,不触碰存储。
    func computeListMarkers() -> [PreviewListMarker] {
        var result: [PreviewListMarker] = []
        var counters: [Int: Int] = [:]
        var previousDepth = 0
        let ns = source as NSString
        for block in document.blocks {
            switch block.kind {
            case .listItem:
                // 容器块逐行解析:一个块可含多行(连续列表项在 parser 里是
                // 单块多行),每行各自的深度/序号独立累计。
                var lineLoc = block.rangeUTF16.location
                let blockEnd = NSMaxRange(block.rangeUTF16)
                while lineLoc < blockEnd {
                    let lineRange = ns.lineRange(for: NSRange(location: lineLoc, length: 0))
                    let parsed = MarkdownBlockModel.parseLine(ns, lineRange: lineRange)
                    if case .none = parsed.kind {
                        // 空白/续行不产生 marker,但也不重置计数(同一列表内)
                    } else {
                        // 深度规则与 parser 的 indentDepth 对齐:每 2 空格/1 tab
                        // 一级;MarkdownBlockLine.indentUTF16 已含前导空白数。
                        let depth = parsed.indentUTF16 / 2
                        let ordered: Bool
                        if case .ordered = parsed.kind { ordered = true } else { ordered = false }
                        if depth < previousDepth {
                            for key in counters.keys where key > depth {
                                counters.removeValue(forKey: key)
                            }
                            counters[depth] = 0
                        } else if depth == previousDepth, let lastMarker = result.last,
                            lastMarker.ordered != ordered
                        {
                            // 同层 marker 类别切换(圆点列表 → 数字列表)= 新列表,
                            // 序号从 1 重数。
                            counters[depth] = 0
                        }
                        counters[depth, default: 0] += 1
                        result.append(
                            PreviewListMarker(
                                depth: depth, ordinal: counters[depth] ?? 1, ordered: ordered))
                        previousDepth = depth
                    }
                    lineLoc = NSMaxRange(lineRange)
                }
            default:
                counters.removeAll()
                previousDepth = 0
            }
        }
        return result
    }

    /// 把 headIndent 写进对应 list 块的段落属性(applyDisplayAttributes 调用)。
    /// 只影响布局;storage 字符串与 display↔source 映射不变。
    func applyListParagraphIndents(storage: NSTextStorage) {
        let markers = computeListMarkers()
        var index = 0
        for item in rendered {
            guard case .listItem = item.block.kind else { continue }
            for segment in item.projection.segments
            where segment.kind == .hiddenMarker && segment.isOpening {
                guard index < markers.count else { break }
                let marker = markers[index]
                index += 1
                // 该行 display 区间:marker 段尾到行尾换行(或块尾)
                let lineStart = item.displayStart + NSMaxRange(segment.displayRangeUTF16)
                let blockDisplayEnd = item.displayStart + item.projection.display.utf16.count
                var lineEnd = blockDisplayEnd
                let nsDisplay = string as NSString
                var probe = lineStart
                while probe < nsDisplay.length, probe < blockDisplayEnd {
                    if nsDisplay.character(at: probe) == 0x0A {
                        lineEnd = probe
                        break
                    }
                    probe += 1
                }
                let range = NSRange(location: lineStart, length: max(0, lineEnd - lineStart))
                guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
                let style = makeBaseParagraphStyle()
                style.headIndent = marker.headIndent
                style.firstLineHeadIndent = marker.headIndent
                storage.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
    }

    /// 自绘列表 marker(在 draw(_:) 的 super 之后调用):圆点/序号画在
    /// headIndent 留出的左侧空位,与正文同色、垂直居中于首行。
    /// ND-04:表格网格 overlay(行线+列线+外框)。只动绘制,不动 storage
    /// 与映射;坐标沿 drawListMarkers 的容器坐标约定(见其注释)。
    func drawTableGrid(in dirtyRect: NSRect) {
        guard !tableGridGeometries.isEmpty, let layoutManager else { return }
        let ns = string as NSString
        let charWidth = ("0" as NSString).size(withAttributes: [.font: codeFont]).width
        guard charWidth > 0.5 else { return }
        for geo in tableGridGeometries {
            guard geo.displayRange.length > 0, NSMaxRange(geo.displayRange) <= ns.length
            else { continue }
            var rowRects: [CGRect] = []
            var start = geo.displayRange.location
            while start < NSMaxRange(geo.displayRange) {
                let lineRange = NSIntersectionRange(
                    ns.lineRange(for: NSRange(location: start, length: 0)), geo.displayRange)
                guard lineRange.length > 0 else { break }
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: lineRange, actualCharacterRange: nil)
                if glyphRange.length > 0 {
                    let rect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                    if rect.height > 0 { rowRects.append(rect) }
                }
                start = NSMaxRange(lineRange)
            }
            guard rowRects.count >= 2, let first = rowRects.first, let last = rowRects.last
            else { continue }
            let top = first.minY, bottom = last.maxY
            if bottom < dirtyRect.minY || top > dirtyRect.maxY { continue }
            let left = first.minX
            let right = left + CGFloat(geo.totalVisualColumns) * charWidth
            let path = NSBezierPath()
            path.lineWidth = 1
            for rect in rowRects {
                path.move(to: NSPoint(x: left, y: rect.maxY))
                path.line(to: NSPoint(x: right, y: rect.maxY))
            }
            path.move(to: NSPoint(x: left, y: top))
            path.line(to: NSPoint(x: right, y: top))
            for boundary in geo.boundaryVisualColumns {
                let x = left + CGFloat(boundary) * charWidth
                path.move(to: NSPoint(x: x, y: top))
                path.line(to: NSPoint(x: x, y: bottom))
            }
            contentTextColor.withAlphaComponent(0.25).setStroke()
            path.stroke()
        }
    }

    func drawListMarkers(in dirtyRect: NSRect) {
        guard let layoutManager, let container = textContainer else { return }
        // TextKit1 的 containerOrigin 由 textContainerInset 与绘制换算得出;
        // 这里自绘 marker 只需容器内坐标,直接以 (0,0) 为基准再按 firstRect 偏移。
        let origin = NSPoint.zero
        let markers = computeListMarkers()
        let markerFont = NSFontManager.shared.convert(bodyFont, toSize: bodyFont.pointSize * 0.85)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: markerFont,
            .foregroundColor: contentTextColor,
        ]
        var index = 0
        for item in rendered {
            guard case .listItem = item.block.kind else { continue }
            // 块内每行一个 opening hiddenMarker 段(lineWise 投影),
            // marker 序列与 computeListMarkers 的行序一一对应。
            for segment in item.projection.segments
            where segment.kind == .hiddenMarker && segment.isOpening {
                guard index < markers.count else { break }
                let marker = markers[index]
                index += 1
                let charIndex =
                    item.displayStart + NSMaxRange(segment.displayRangeUTF16)
                guard charIndex >= 0, charIndex < (string as NSString).length else { continue }
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
                guard glyphIndex < layoutManager.numberOfGlyphs else { continue }
                let lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphIndex, effectiveRange: nil)
                let text = NSAttributedString(string: marker.text, attributes: attrs)
                let size = text.size()
                let x = origin.x + marker.baseIndent + 2
                let y = origin.y + lineRect.midY - size.height / 2
                // 只画在 headIndent 空位内,不与正文字形重叠
                if x + size.width <= origin.x + marker.headIndent - 2 {
                    text.draw(at: NSPoint(x: x, y: y))
                }
            }
        }
        _ = container
    }
}
