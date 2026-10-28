# PRD — 所见即所得显示完全替代预览模式

状态：需求草案，2026-10-23。本文只描述产品需求与边界，不表示能力已存在。
实现合同见 [SPEC.md](SPEC.md)，任务与验证见 [PLAN.md](PLAN.md)。

基线：`feat/native-typora-editor-t12-input`（T19 part 4 完成态）。
需求来源：维护者对"WYSIWYG 与预览对任意格式 md（含 mermaid 等）渲染效果是否一致"的
连续追问，与本次"让所见即所得模式的显示效果完全替代预览模式"的直接指令。

## 1. 问题陈述

当前 WYSIWYG（`NativeRichEditorHostView` + `RichMarkdownTextView`）是 source-authority
投影编辑器：普通排版（标题层级、粗斜删、链接色、code 底色、行高、列表 marker）已与
预览 CSS 常量对齐（T19 part 4），但**特殊块仍是原文或占位**，与预览差距如下：

| 内容 | WYSIWYG 现状 | 预览现状 |
|---|---|---|
| 图片 | alt 文本占位（空 alt 显示 `[图]`） | 真实图片渲染，`max-width: 100%` |
| 表格 | 管道符原文 1:1 投影 | GFM HTML 表格，`table-layout: fixed` |
| 数学 `$...$` / `$$...$$` | 原文变暗/等宽 | KaTeX 渲染 |
| Mermaid | fenced code 原文 | SVG 渲染（失败回源码） |
| PlantUML | fenced code 原文 | 远端 SVG 图 |
| HTML 块 | 原文显示 | `CMARK_OPT_UNSAFE` 呈现 |
| 任务列表 | `[x]`/`[ ]` 字面可见 | 可点击 checkbox |
| Alerts（GitHub 提示） | 普通引用块 | callout 样式 |
| 脚注 | 无结构 | cmark footnotes HTML |
| 长代码 | 全文铺开 | `<pre>` 块可局部滚动 |

结果：用户阅读含公式/图表/图片/表格的笔记时，必须切预览才能看到真实渲染。
本次目标是消除这个切换需求。

**代码调查关键事实**：`MarkdownBlockRenderHost`（离屏 WKWebView → 静态 SVG/HTML 产物）
已存在且 T17 验证过快照/缓存语义，但**未接入富编辑显示**——目前只服务导出供给
（`NativeBlockExportSupply`）且生产调用点尚未接上。它是本 PRD 的主要可复用件。

## 2. 目标与非目标

### 2.1 目标

1. **显示完全性**：预览能渲染的内容，WYSIWYG 同样以渲染态显示（不是原文占位）。
   对同一份 Markdown，用户在 WYSIWYG 看到的信息与预览一致。
2. **源码权威不变**：显示是派生层，`RichMarkdownTextView.source` 仍是唯一权威文本；
   渲染产物不回写 source，保存仍经 source patch 路径。
3. **编辑入口保留**：特殊块提供"编辑源码"入口（点击/键盘进入 source 子范围），
   不要求用户直接编辑渲染产物内部。
4. **失败不丢源码**：渲染超时/失败/错误（如非法 mermaid）一律回退原文显示，
   绝不空白、绝不丢内容。
5. **主题一致性**：浅色/深色下与预览同色（复用 T19 part 4 的 preview-parity 常量
   与 `themeGeneration` 机制）。

### 2.2 非目标

- 不要求特殊块的**交互式** WYSIWYG（如在渲染公式里打字、拖 mermaid 节点）。
  渲染态是只读显示，编辑走源码。
- 不移除预览模式、不改预览管线、不动 `renderMarkdownHTML` / DownView.bundle 的
  渲染语义（预览作为对照基准和阅读模式保留）。
- 不做像素级克隆预览；要求信息与视觉层级等价（字体族/字号/行高/颜色/间距）。
- 不引入 SwiftUI 进编辑核心（AGENTS.md 约束）；不把正文换成 WKWebView。
- 不做协同编辑、不改 iOS 端、不改 Note/Storage/同步语义。
- PlantUML 的远端依赖行为保持现状（预览即远端）；不在本次内做离线 PlantUML。

## 3. 用户场景

1. **阅读含公式笔记**：打开笔记，`$$E=mc^2$$` 直接显示为排版公式；点击公式进入
   源码编辑，移开光标后恢复渲染。
2. **阅读含 mermaid 流程图笔记**：图直接显示；点击进入源码改节点，保存后图更新。
3. **图文混排**：图片真实显示且不超宽（`max-width: 100%`），点击打开现有图片属性
   编辑入口。
4. **表格**：表格以网格形态显示（非管道符原文）；编辑时可进入单元格源码编辑
   （保留 T16 的表格命令与 Tab 导航）。
5. **错误恢复**：mermaid 语法错误时显示源码 + 错误标记，源码可编辑，保存不丢。
6. **深浅色切换**：切深色后渲染块与正文同步换色，无白底残留。
7. **VoiceOver**：渲染块暴露可读的 alt/标题/角色，键盘可达"编辑源码"入口。

## 4. 成功标准

| # | 标准 | 验证方式 |
|---|---|---|
| S1 | 覆盖语料（含图片/表格/数学/mermaid/PlantUML/HTML/alerts/task/脚注/长代码）在 WYSIWYG 无"原文占位"退化 | 实机视觉矩阵 + 截图对比 |
| S2 | 同文档 WYSIWYG vs 预览信息等价（人工逐块比对） | 实机比对，差异逐项登记 |
| S3 | 渲染失败源码可见可编辑；保存 round-trip 字节不变 | 单测 + 实机 |
| S4 | 深/浅色与预览色值一致 | 实机比对 + 常量断言 |
| S5 | 输入延迟不回退（既有 T21 预算不因渲染接入劣化） | 压力测试回归 |
| S6 | VoiceOver 可读渲染块语义，键盘可达编辑入口 | AC-17 实机 |

## 5. 优先级

| 优先级 | 范围 |
|---|---|
| P0 | 图片真实显示、数学渲染、Mermaid 渲染、表格网格显示、长代码局部滚动、失败回退 |
| P1 | PlantUML 显示、HTML 块安全显示、任务列表 checkbox、alerts callout、深浅色一致性 |
| P2 | 脚注结构化、VoiceOver 完整语义、键入时增量渲染优化 |

P0 进入"可宣布替代预览"门槛；P1/P2 允许后续迭代但须在 SPEC 验收里如实标 partial。

## 6. 关键约束（继承，不可违反）

- **#543 缓冲归属**：保存只经 `RichMarkdownTextView.source` → `onSourceCommitted`
  → `note.content`；绝不从隐藏 `EditTextView` buffer 或渲染产物保存。
- **IME marked text**：`hasMarkedText()` 期间禁止任何 textStorage 属性重写
  （含渲染产物应用）。
- **protected regions**：代码/数学/链接目标/wikilink/frontmatter 不得被格式化或
  spell 改写。
- **显示是派生**：source 字节与 display↔source 映射不因渲染产物改变；
  渲染产物只能是 display 层的附加（attachment/overlay），不是 source 替换。
- **AppKit 编辑核心**：不把 SwiftUI/WKWebView 推进 `EditTextView` /
  `MPreviewView` / `ViewController`。
- **性能**：T21 预算（200KiB 首帧 ≤300ms、输入 p95 ≤16ms）不因渲染接入回退；
  渲染在后台/离屏，主线程只应用已接受产物。

## 7. 与既有规格的关系

- 本 PRD 满足 `specs/native-typora-editor/SPEC.md` 的 NE-32（字体/主题/VoiceOver）
  的显示侧，扩展 NE-06/NE-08 的投影模型到特殊块渲染态。
- 不改变 `specs/wysiwyg-and-rendered-block-export/SPEC.md` 的 D 线（单 Mermaid
  PNG/SVG 导出优先）；本次是编辑面显示，不是导出。
- 复用 `MarkdownBlockRenderHost` / `MarkdownBlockRenderAdapter` 的快照、主题代、
  latest-wins、有界 cache 语义（T17 已验证），补 UI 接线。

## 8. 开放问题（需维护者裁定）

1. **表格编辑形态**：网格显示后，单元格编辑是继续走 source 子范围（T16 现状）
   还是做点选单元格直接编辑？建议前者，风险低且保 source 权威。
2. **数学 inline 与 display 的编辑体验**：inline `$x$` 渲染后点击进源码，
   是否接受"整段公式一起编辑"？建议接受。
3. **替代深度**："完全替代预览"是否允许在 P0 完成后保留预览按钮（建议保留，
   阅读模式）？还是需要同时隐藏/移除预览入口？
4. **PlantUML 远端**：WYSIWYG 显示 PlantUML 是否接受同样走远端
   `plantuml.com`（与预览一致）？建议接受，但需标注网络依赖。
