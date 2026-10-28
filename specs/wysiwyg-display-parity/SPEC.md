# SPEC — 所见即所得显示替代预览：实现合同

状态：实施规格草案，2026-10-23。本文中的"必须"是本次实施的验收合同，不表示能力已存在。
需求边界见 [PRD.md](PRD.md)，任务卡与验证命令见 [PLAN.md](PLAN.md)。

基线：`feat/native-typora-editor-t12-input`。执行前重查 HEAD、dirty changes、
实际依赖与运行状态；不直推 main/master，不覆盖他人修改。

## 1. 架构决策

### 1.1 总体：显示派生 + 源码权威（不变）

```
source (RichMarkdownTextView.source, 唯一权威)
   │
   ├─ LosslessMarkdownParser → MarkdownProjectionBuilder → display 文本
   │      （已存在：marker 隐藏、inline 语义、display↔source 映射）
   │
   └─ [新增] MarkdownBlockRenderHost 产物（SVG/PNG/HTML 静态图）
          → 挂到 display 层（NSTextAttachment / 块视图 overlay）
          → 只读；点击/键盘回 source 子范围编辑
```

关键不变量（继承自 native-typora-editor SPEC，违反即回退）：

| ID | 不变量 | 实施方式 |
|---|---|---|
| INV-1 | source 字节永不被渲染产物改写 | 渲染产物仅存在于 display 层；保存路径不经 display |
| INV-2 | display↔source 映射稳定 | 产物挂在 display range 上不插入 source 字符；映射表不变 |
| INV-3 | IME marked text 期间不动 textStorage 属性 | 产物应用回调检查 `hasMarkedText()`，命中则推迟到 unmark 后 |
| INV-4 | 渲染失败→源码原文回退，不空白、不丢内容 | host 返回 nil/timeout/error 时显示原 plain fallback |
| INV-5 | 主线程不做重渲染计算 | 产物生成在离屏 WKWebView（既有 host），主线程只应用 |
| INV-6 | #543 owner 规则 | 渲染不引入新 buffer/保存路径；`onSourceCommitted` 镜像保持 |

### 1.2 渲染产物管线（复用 + 补接线）

既有 `MarkdownBlockRenderAdapter`：请求=不可变 source snapshot + themeGeneration +
revision；latest-wins coordinator；按 fingerprint 的有界 cache。**补 UI 接线**：

1. `RichMarkdownTextView.rebuildProjection()` 识别特殊块 kind（math/mermaid/
   plantuml/html/image）→ 生成 `MarkdownBlockRenderRequest`。
2. 主线程立即用 plain fallback（原文）填充，不阻塞首帧。
3. 后台 host 产出静态产物（SVG/PNG）→ 主线程应用为该块的显示附件/overlay。
4. 产物缓存 key = source hash + kind + themeGeneration + 视口宽度。
5. revision/主题代变化 → 旧请求失效（latest-wins），新请求重建。

### 1.3 显示形态决策（每种特殊块）

| 块 | 显示形态 | 编辑入口 | 备注 |
|---|---|---|---|
| 图片 | `NSTextAttachment` 真实图像，`max-width:100%` 等比缩放 | 点击→现有图片属性弹窗（`editImage`） | 从现有 `attachmentPlaceholder` 升级 |
| 数学 inline `$x$` | 行内附件（KaTeX SVG/PNG） | 点击→整段公式的 source 子范围 | 整段公式一起编辑（PRD §8.2 建议） |
| 数学 display `$$..$$` | 块级附件 | 点击→块 source 子范围 | |
| Mermaid | 块级 SVG/PNG 附件 | 点击→块 source 子范围 | 失败：原文 + 错误标记 |
| PlantUML | 块级远端 SVG 图 | 点击→块 source 子范围 | 网络依赖，失败回原文 |
| HTML 块 | 块级 sanitized 静态渲染（strip script/iframe） | 点击→块 source 子范围 | 只读，不执行脚本 |
| 表格 | 网格显示：列对齐 + 边框样式（属性/overlay 绘制） | 单元格 source 子范围（T16 命令保留） | PRD §8.1 建议 source 子范围 |
| 任务列表 | `[x]`/`[ ]` 替换为 checkbox 图形 | 点击 checkbox→`toggleTaskAtSelection` | source patch 已有 |
| Alerts | callout 样式（背景/图标/标题色） | 文本照常编辑 | 投影层属性，非附件 |
| 脚注 | 上标引用 + 文末定义区样式 | 文本照常编辑 | P2，可 partial |
| 长代码 | fenced 块局部滚动（固定高度 + 滚动条） | 文本照常编辑 | 高度阈值可配 |

### 1.4 主题一致性

- 渲染产物请求携带 `themeGeneration`（主题/深浅色切换时递增）。
- 色值来源：T19 part 4 的 `RichMarkdownTextView+Appearance` preview-parity 常量
  （正文 #262626/#E7E9EA、链接 #0C6ADA/#1D9BF0、code 底 #f7f7f7/#282e33）。
- 渲染产物背景透明或与预览同底色；深色下产物由 host 用 dark stylesheet 重渲染
  （主题代变化 → cache miss → 重建）。

## 2. 需求

| ID | 合同 | 优先级 |
|---|---|---|
| ND-01 | 图片显示为真实图像附件，限宽 100%，点击进现有属性弹窗 | P0 |
| ND-02 | display/inline 数学渲染为公式图，点击进 source 子范围 | P0 |
| ND-03 | Mermaid 渲染为图；失败回原文+错误标记，源码可编辑 | P0 |
| ND-04 | 表格网格显示（非管道原文）；保留 T16 表格命令与 Tab 导航 | P0 |
| ND-05 | 长代码块局部滚动（高度阈值 + 滚动条），不全文铺开 | P0 |
| ND-06 | 渲染请求 latest-wins；revision/主题代变化正确失效 | P0 |
| ND-07 | 渲染失败/超时→plain fallback，source 不变 | P0 |
| ND-08 | PlantUML 显示为图（远端）；失败回原文 | P1 |
| ND-09 | HTML 块 sanitized 静态渲染，strip script/iframe | P1 |
| ND-10 | 任务列表 checkbox 图形 + 点击切换（走既有 toggle） | P1 |
| ND-11 | Alerts callout 样式（投影层属性） | P1 |
| ND-12 | 深/浅色主题一致性（产物同色，无白底残留） | P1 |
| ND-13 | 脚注结构化显示 | P2 |
| ND-14 | VoiceOver：渲染块暴露 role/label/value；键盘可达编辑入口 | P2 |
| ND-15 | 输入性能不回退（T21 预算保持） | P0 |

## 3. 验收标准

| ID | 标准 | 对应需求 |
|---|---|---|
| AC-D01 | 视觉矩阵语料（含 P0 全部类型）在 WYSIWYG 无原文占位退化 | ND-01..05 |
| AC-D02 | 同文档 WYSIWYG vs 预览逐块信息等价（人工比对，差异登记） | ND-01..11 |
| AC-D03 | 错误 mermaid/超时渲染显示源码且可编辑；保存 round-trip 字节不变 | ND-07 |
| AC-D04 | 点击渲染块进入 source 子范围，改完离开恢复渲染 | ND-02..04 |
| AC-D05 | 深/浅色切换产物同步换色 | ND-12 |
| AC-D06 | 200KiB 首帧 ≤300ms、输入 p95 ≤16ms 不回退 | ND-15 |
| AC-D07 | VoiceOver 读出渲染块语义；键盘可达编辑入口 | ND-14 |

## 4. 验证方式

- 单测：渲染请求生命周期（latest-wins、cache、失效）、plain fallback、
  source round-trip、checkbox toggle、表格网格映射。
- 实机：视觉矩阵截图（WYSIWYG vs 预览，浅/深色），人工逐块比对。
- 压力：`NativeEditorStressBudgetTests` 回归 + 渲染接入后复测。
- VoiceOver/键盘：实机验收（AC-17 延续）。

## 5. 性能预算（不回退）

| 指标 | 预算 | 来源 |
|---|---|---|
| 200KiB/2k 行首帧 | ≤300ms | native-typora-editor SPEC §10 |
| 输入 p95 | ≤16ms | 同上 |
| 渲染产物应用 | 主线程 ≤2ms/块 | 本 SPEC 新增 |
| 产物 cache | 有界（既有 adapter），失效按主题代/revision | T17 |

## 6. 回退策略

任一 P0 需求失败 → 该项回 plain fallback（原文显示），标记 partial，不阻断保存；
INV-1..6 任一被破坏 → 立即回滚该改动并记录复现。
