# PLAN — 所见即所得显示替代预览 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让 WYSIWYG 对特殊块（图片/数学/Mermaid/表格/长代码等）显示渲染态，用户不再需要切预览查看真实渲染。

**Architecture:** 保持 source-authority 投影（LosslessMarkdownParser + MarkdownProjectionBuilder）；渲染产物由既有 `MarkdownBlockRenderHost` 离屏生成，作为 display 层只读附件/overlay 挂载；点击进 source 子范围编辑；失败回 plain fallback。不改预览管线。

**Tech Stack:** Swift 6 / AppKit / TextKit 1、既有 CMarkGFM、既有 MarkdownBlockRenderHost（离屏 WKWebView）、XCTest。macOS 11.5 基线不变。

基线：`feat/native-typora-editor-t12-input`。执行前重查 HEAD、dirty changes；不直推 main/master。

---

## 阶段图

```text
W00 基线与视觉语料
 └─ W01 渲染请求生命周期（adapter → rich 接线，无 UI 变化）
      ├─ W02 图片真实显示（ND-01）
      ├─ W03 数学渲染（ND-02）
      ├─ W04 Mermaid 渲染 + 失败回退（ND-03）
      └─ W05 表格网格显示（ND-04）
           ├─ W06 长代码局部滚动（ND-05）
           ├─ W07 主题一致性（ND-12）
           ├─ W08 PlantUML + HTML 块（ND-08/09）
           ├─ W09 任务 checkbox + alerts callout（ND-10/11）
           ├─ W10 脚注 + VoiceOver 语义（ND-13/14）
           └─ W11 视觉矩阵实机验收 + 性能回归（AC-D01..07）
```

每卡步骤固定：读合同 → 写失败测试 → 确认失败 → 最小实现 → 窄测通过 →
（有 UI 时）实机走流程 → 检查 INV-1..6 → commit。
源代码改动 >100 行或高风险，必须先有失败测试。

---

## W00 — 基线与视觉语料

**Files:**
- Create: `MiaoYanTests/Fixtures/NativeEditor/display-parity-corpus.md`
- Create: `MiaoYanTests/RichDisplayRenderRequestTests.swift`

**Step 1.** 造视觉语料：含图片/表格/inline+display 数学/mermaid（合法+非法）/plantuml/
HTML 块/任务列表/alerts/脚注/长代码（>30 行）/粗斜删链接。
**Step 2.** 写失败测试：语料中每种特殊块被 parser 识别为对应 block kind
（当前图片是 `attachmentPlaceholder`、表格/math/mermaid 是 plain，测试应先暴露差距）。
**Step 3.** 运行确认失败是"识别缺口"而非接线错误。
**Step 4.** Commit: `test(editor): display parity corpus and block-kind expectations`

## W01 — 渲染请求生命周期接线

**Files:**
- Modify: `Helpers/MarkdownBlockRenderAdapter.swift`
- Modify: `Views/RichMarkdownTextView.swift`（rebuildProjection 识别特殊块）
- Test: `MiaoYanTests/RichDisplayRenderRequestTests.swift`

**Step 1.** 失败测试：特殊块进入 rebuildProjection 后产生 `MarkdownBlockRenderRequest`
（snapshot + kind + themeGeneration + revision）；revision 变化使旧请求失效。
**Step 2.** 最小实现：rebuildProjection 识别 math/mermaid/plantuml/html/image 块 →
投递请求；主线程立即用 plain fallback 占位。
**Step 3.** 断言 latest-wins：同块快速两次编辑只接受最后一个产物。
**Step 4.** 全量测试 + lint；Commit: `feat(editor): wire block render requests into rich projection`

## W02 — 图片真实显示（ND-01）

**Files:**
- Modify: `Helpers/MarkdownProjectionBuilder.swift`（attachmentPlaceholder → 图像附件）
- Modify: `Views/RichMarkdownTextView.swift`（图像附件应用、限宽、点击）
- Test: `MiaoYanTests/RichDisplayImageTests.swift`

**Step 1.** 失败测试：图片显示为 `NSTextAttachment`（非 alt 文本）；宽度 ≤ 视口宽。
**Step 2.** 实现：加载 `i/` 附件（路径规则同 `![](/i/<name>)`），等比缩放限宽。
**Step 3.** 点击→现有 `editImage` 弹窗路径回归（已有测试覆盖则引用）。
**Step 4.** source round-trip 断言：显示附件不改 source 字节。
**Step 5.** Commit: `feat(editor): render real image attachments in wysiwyg`

## W03 — 数学渲染（ND-02）

**Files:**
- Modify: `Views/RichMarkdownTextView.swift`（math 块/行内附件）
- Test: `MiaoYanTests/RichDisplayMathTests.swift`

**Step 1.** 失败测试：`$$..$$` 与 `$..$` 渲染为图（host 产物），点击进 source 子范围。
**Step 2.** 实现：math 块走 `MarkdownBlockRenderHost`（已有 math kind）；失败回原文。
**Step 3.** INV-3 断言：marked text 期间产物应用被推迟。
**Step 4.** Commit: `feat(editor): render math blocks in wysiwyg`

## W04 — Mermaid 渲染 + 失败回退（ND-03/07）

**Files:**
- Modify: `Views/RichMarkdownTextView.swift`
- Test: `MiaoYanTests/RichDisplayMermaidTests.swift`

**Step 1.** 失败测试：合法 mermaid 渲染为 SVG 图；非法 mermaid 显示原文 + 错误标记。
**Step 2.** 实现：mermaid kind 走 host（已有）；error → plain fallback + 标记属性。
**Step 3.** AC-D03：错误块源码可编辑，保存 round-trip 字节不变。
**Step 4.** Commit: `feat(editor): render mermaid with source fallback on error`

## W05 — 表格网格显示（ND-04）

**Files:**
- Modify: `Helpers/MarkdownProjectionBuilder.swift` / `Views/RichMarkdownTextView+Appearance.swift`
- Test: `MiaoYanTests/RichDisplayTableTests.swift`

**Step 1.** 失败测试：表格显示为网格（列对齐/边框），非管道符原文。
**Step 2.** 实现：表格块显示形态 = 列位对齐 + 边框绘制（属性/overlay），
单元格 source 子范围编辑（T16 命令与 Tab 导航保留）。
**Step 3.** 回归 `MarkdownTableEditingTests`（既有命令不破）。
**Step 4.** Commit: `feat(editor): grid display for tables in wysiwyg`

## W06 — 长代码局部滚动（ND-05）

**Files:**
- Modify: `Views/RichMarkdownTextView+Appearance.swift`
- Test: `MiaoYanTests/RichDisplayCodeTests.swift`

**Step 1.** 失败测试：超阈值行数的 fenced 块显示高度受限 + 可滚动。
**Step 2.** 实现：高度阈值 + 局部滚动（overlay/exclusion）；文本照常可编辑。
**Step 3.** Commit: `feat(editor): local scroll for long code blocks`

## W07 — 主题一致性（ND-12）

**Files:**
- Modify: `Views/RichMarkdownTextView.swift` / adapter（themeGeneration）
- Test: `MiaoYanTests/RichDisplayThemeTests.swift`

**Step 1.** 失败测试：themeGeneration 变化 → 旧产物失效 → 新产物按新主题重建。
**Step 2.** 实现：深/浅色切换递增主题代；产物底色与 preview-parity 常量一致。
**Step 3.** 实机：深/浅色各截图，与预览比对无白底残留。
**Step 4.** Commit: `feat(editor): theme-consistent rendered blocks`

## W08 — PlantUML + HTML 块（ND-08/09）

**Files:**
- Modify: `Views/RichMarkdownTextView.swift` / host
- Test: `MiaoYanTests/RichDisplaySpecialBlocksTests.swift`

**Step 1.** 失败测试：plantuml 显示为图（远端）；HTML 块 sanitized 显示（无 script）。
**Step 2.** 实现：plantuml 复用预览的远端 encoder 路径；HTML 用 host 静态产物
（strip script/iframe，INV-4）。
**Step 3.** Commit: `feat(editor): plantuml and sanitized html display`

## W09 — 任务 checkbox + alerts callout（ND-10/11）

**Files:**
- Modify: `Helpers/MarkdownProjectionBuilder.swift` / `RichMarkdownTextView+Appearance.swift`
- Test: `MiaoYanTests/RichDisplayTaskAlertsTests.swift`

**Step 1.** 失败测试：`[x]`/`[ ]` 显示 checkbox 图形；alerts 显示 callout 样式。
**Step 2.** 实现：checkbox 图形点击→既有 `toggleTaskAtSelection`；alerts 走投影属性。
**Step 3.** Commit: `feat(editor): task checkboxes and alert callouts`

## W10 — 脚注 + VoiceOver 语义（ND-13/14）

**Files:**
- Modify: `Views/RichMarkdownTextView.swift`（AX 元素）
- Test: `MiaoYanTests/RichDisplayAccessibilityTests.swift`

**Step 1.** 失败测试：渲染块 AX role/label/value 可读；键盘可达编辑入口。
**Step 2.** 实现：NSAccessibilityElement 暴露块语义；脚注结构化（P2 可 partial）。
**Step 3.** Commit: `feat(editor): accessibility semantics for rendered blocks`

## W11 — 视觉矩阵实机验收 + 性能回归

**Files:**
- Create: `specs/wysiwyg-display-parity/validation/README.md`

**Step 1.** 实机视觉矩阵：语料在 WYSIWYG vs 预览、浅/深色，逐块比对并截图。
**Step 2.** 性能：`NativeEditorStressBudgetTests` + 渲染接入后复测（AC-D06）。
**Step 3.** VoiceOver/键盘实机（AC-D07）。
**Step 4.** 记录 pass/partial/blocked，不冒充。
**Step 5.** Commit: `docs: display parity visual matrix and perf record`

---

## 验证命令

```bash
xcodebuild -project MiaoYan.xcodeproj -scheme MiaoYan -configuration Debug \
  CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0 build
xcodebuild test -project MiaoYan.xcodeproj -scheme MiaoYan \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  MACOSX_DEPLOYMENT_TARGET=12.0
swiftlint lint --strict
git ls-files '*.swift' | xargs swift-format lint --strict
```

实机验证用隔离 smoke 副本（独立 bundle ID + 临时库），不动用户笔记。

## 退出门

- P0（AC-D01/D02/D03/D04/D06）全通过 → 可宣布"WYSIWYG 显示可替代预览查看"。
- P1/P2 未完项如实标 partial，不阻断宣布，但不得宣称"全部完成"。
- INV-1..6 任一被破坏 → 回滚并记录。
