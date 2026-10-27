# T03 — lossless parse 与 display/source 原型

日期：2026-10-14。新增（已注册 pbxproj）：`Helpers/LosslessMarkdownParser.swift`（含 `LosslessParseCoordinator`）、`Helpers/MarkdownProjectionBuilder.swift`、`MdownTests/NativeFixtureLoader.swift`、三个测试文件。测试 28/28 绿；全套 240 tests 仅剩 BASELINE §1.1 既有环境性失败；swiftlint --strict 0 violations。

## 设计决定

1. **块级无损用自写行扫描器**（行锚定、天然可逆：块 range 联合覆盖全文，切片重建 == 原文，`Document.isLossless` 不变量 + 全 fixtures roundtrip 测试固定）。cmark 不在本层；作为**语义对照通道**由测试实测 pin（见下）。
2. **投影**（`MarkdownProjectionBuilder`）：块级 marker（ATX/list/quote 前缀）与 inline（`**`/`__`/`~~`/`*`/`_` 成对、code span、`[t](url)`/`![a](url)`）产生 hiddenMarker/linkDestination/codeSpan/attachmentPlaceholder 段；未配对/转义/未知结构一律原样显示（不猜测）。display↔source 双向偏移映射：非折叠段内部恒等、段边界复合后仍是段边界（hidden marker 段内部偏移在 display 无表面，折叠到相邻边界是固有语义；affinity 选择留给 T04 caret 层）。
3. **乱序收敛**：`LosslessParseCoordinator.publish(revision:)` 严格递增校验，旧 revision 结果一律拒绝（200/500ms 注入的确定性等价测试固定）；「字符操作同步推进局部 map」在 T04 视图层叠加。

## pinned cmark 行为（实测固定）

- `CMARK_OPT_SOURCEPOS` 下 heading/code fence 的 start/end line 与行扫描一致（含 CRLF 文件：cmark 把 CRLF 当单换行）。
- **cmark 无 frontmatter 概念**：`---\ntitle: x\n---`（无空行）被解析为 hr + **setext heading**（L2-L3）+ hr；行扫描器整体当 frontmatter。CRLF 文件同样。此差异已 pin 为已知行为（frontmatter 属 Mdown 语义，预览管线在 renderMarkdownHTML 前剥离）。
- cmark 列按 UTF-8 byte 计（中文 3 byte/字、tab 1 byte）；`Document.utf16Offset(line:utf8Column:)` 提供换算。
- container（list/quote）的 cmark end sourcepos 不可靠，不用作对照。

## 重要实测发现

- **`String(data:encoding:.utf8) 会剥离 UTF-8 BOM`**：磁盘文件有 BOM 但解码后 String 无 BOM。`NativeFixtureLoader.loadString` 已显式回补；**T07 的文件读取路径（FileWrapper）必须同样防 BOM 丢失**，否则 roundtrip 保存会把 BOM 弄丢。
- `consumeContainer` 简化规则的边界已固定：quote 行不并入列表容器（引用开始新块）；段落懒延续把列表/引用前导行并入段落（原型简化，完整 CommonMark 容器延续在支持表中 pending）。

## 支持表与 pending（T03 原型边界）

支持：frontmatter（BOM 感知、CRLF 感知）、ATX heading、fenced code（嵌套按更长闭 fence）、indented code（4 空格/1 tab）、blockquote（深度）、有序/无序列表（2 空格或 1 tab 一级）、thematic break、GFM table（header+delimiter+行）、html block（`<`+字母）、blank、paragraph 懒延续。

Pending（原样保留原文，不投影结构）：link reference definition / footnote 定义的独立拆分、setext heading、autolink、raw inline HTML、table 单元格 inline 投影、GFM task list marker 的 checkbox 段（当前并入 listItem marker）、跨块 affinity/空块/跨格式选择的完整规则（T04）。

## 测试清单

- `MarkdownRoundTripTests`（7）：全 fixtures 无损 + 切片重建逐字节、空/单行、纯 frontmatter、CRLF 不切断、BOM 留块内、frontmatter 界定。
- `LosslessMarkdownParserTests`（12）：块种类序列、fence 跨闭 fence、嵌套 ````、table 范围、cmark sourcepos 对照（LF/CRLF/中文列/tab）、乱序收敛。
- `MarkdownProjectionTests`（9）：`**AB**` marker 独立成段（改 B 不动 delimiter）、未闭合/转义原样、code span、link/图片、heading marker、保护块 plainFallback、fence 内容不进 inline、边界折叠不变量、display 长度守恒。
