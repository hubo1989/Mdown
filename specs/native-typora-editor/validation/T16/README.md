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

## 阶段 2(同日补交):rich 面表格交互

- `RichMarkdownTextView`:caret 在 table 块内时 Tab/Shift+Tab 在可编辑
  行的 cell 间导航(首/末格原地),Enter 在末行 = `appendRow` 一次
  结构事务(origin .structure、可撤销),非末行跳正下方同列;
  管道/分隔行上的 Tab/Enter 吞键不动正文。G0 决定单 TextKit 投影,
  未建独立 grid 控件;cell 定位/落点全部以模型区间为权威坐标。
- 测试:4 个 view 层用例(Tab 往返、末格加行+undo、非末行跳格、
  list 内 Tab 回落不受影响);套件 15/15;全量 557(同 8 环境失败);
  strict lint/format 干净。调试期曾加运行时诊断定位坐标权威性,
  已全部移除(assert 复查 0 残留)。

## 阶段 3(同日补交):模型字节保真与行列移动

- 行缓存改存逐行原字节+真实行尾(CRLF/混合/无末换行保真);expectedText
  全部取缓存原字节;backtick run 定长配对;反斜杠奇偶判定转义;
  setCell 只转义未转义管道(不双转义);insertRow 头行后落分隔行后
  (GFM 不变量);deleteRow 护头/分隔行并保块尾形态;deleteColumn 拒
  单列表格;新增 moveRow/moveColumn(快照内稳定 UUID/columnIDs)。
- 模型级断言 43 条(独立 swiftc harness 连真实 SourcePatch applier 验证)。

## T16 剩余(不声称完成)

1. cell 文本编辑经投影映射的完整矩阵(IME marked 区)、跨 cell 选区
   与粘贴语义、行列操作/对齐的菜单/手势入口(模型命令已备,UI 未接)。
2. 真实 IME cell 输入实测。
