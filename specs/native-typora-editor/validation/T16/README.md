# T16 验证记录(阶段 1:表格模型层)— 2026-10-22

前序 `0f7d3d2`(T15 part 2)。只覆盖已落地部分;剩余如实列出。

## 已交付

- `Business/MarkdownTableModel.swift`(PLAN T16 指定 Create):
  - parse:table 块 → 行(内容/含换行两套区间 + 行原文缓存)与 cell
    的 UTF-16 区间;`\|` 转义与 code span 内 `|` 不拆;首尾边界管道
    剥除、cell 两侧单空格裁剪;无首尾管道的行同样解析;分隔行识别与
    列对齐(none/left/center/right)。
  - 修改计划(全部产出同 base SourcePatch,应用统一走
    MarkdownPatchApplier):setCell(用户文本 `|` 显式转义写入)、
    insertRow(单 patch 原子)/appendRow、deleteRow(含行尾换行,
    全删保护)、deleteColumn/insertColumn(逐行重建,expectedText 用
    parse 缓存原文保证字节精确)、setAlignment(仅重建分隔行)。
  - expectedText 全部来自缓存原文而非重建文本;模型不持 source、
    不改权威正文。

## 验证

| 项 | 结果 |
|---|---|
| `MarkdownTableEditingTests`(11,RED→GREEN) | **11/11** |
| 全量套件 | 553 tests,8 failures = 既有 3 个 WebKit 环境用例多次断言(基线已证) |
| SwiftLint --strict | 0 violations;触及文件 swift-format 干净 |

## T16 剩余(不声称完成)

1. rich 面表格投影与交互:cell 内直接编辑(IME)、Tab/ShiftTab 跨格、
   Enter 软换行/末格加行、⌘Enter 退出块、跨 cell 选区与粘贴语义、
   行列 insert/delete/move/对齐的菜单或手势入口——经
   RichMarkdownTextView 以本模型 + applyStructurePatches 事务落地
   (G0 已定单 TextKit 投影,不建独立 grid 控件)。
2. 表格行内嵌 code/转义混合的边界 corpus 扩充与真实 IME 实测。
