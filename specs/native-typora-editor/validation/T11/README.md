# T11 — 普通正文、行内格式与链接

日期：2026-10-20。基线：T10 head `72a8995` 之上，分支
`feat/native-typora-editor-t11-inline`。

## 交付

**行内格式 planner（`Business/MarkdownEditTransaction.swift`）**
- `MarkdownInlineFormat`：strong/emphasis/strikethrough/code 四种，各带
  delimiter 常量。
- `InlineFormatPlanner`：纯函数判定 wrap/unwrap。unwrap 仅当选中 source
  区间两侧**紧贴**同名 delimiter（code 额外要求是单 backtick span——
  两侧 backtick 之外不得再贴 backtick，避免把 `` `x` `` 从 `` ``x`` ``
  内层误剥）；wrap 生成两条插入 patch（两侧 delimiter），unwrap 生成两条
  删除 patch。所有 patch 经 `MarkdownPatchApplier` 原子应用。
- code wrap 防破坏守卫：紧邻 backtick 时插入会制造歧义 run
  （`` ``x`` `` → `` ```x``` ``），显式拒绝（返回 false，source 不动）。

**inline link 扫描与安全 scheme（同文件）**
- `InlineLinkSpan` + `InlineLinkScanner`：扫描全文 `[label](target)`（含
  image `![a](b)`），未配对/转义/`][`/`]:` 一律不匹配，原文不动；
  reference link `[a][b]` 与 footnote `[^1]` 不匹配（NE-12 保留原位）。
- `MarkdownLinkSafety.isEditableTarget`：target 编辑白名单——无 scheme
  （相对路径/`#fragment`）与 `http`/`https`/`mailto` 允许；`javascript`/
  `data`/`vbscript` 及一切非白名单 scheme、空串、含换行拒绝。

**view 层 API（`Views/RichMarkdownTextView.swift`）**
- `applyInlineFormat(_:)`：选中区间（空选中取光标处连续非空白词）wrap/
  unwrap；display↔source 区间经投影段映射，跨块/歧义显式拒绝；登记
  `.format` 历史（undo/redo 单一语义）；selectionAfter 映射回 display。
- `updateLinkTarget(_:)`：只替换 target range 字节，label 字节原样
  （独立编辑）；安全 scheme 校验失败不动 source。
- `linkAtSelection()` + `onOpenLink` 回调 + `mouseDown` override：
  **⌘+click** 命中 link 时开链接（回调交 host 解析相对路径），普通 click
  走默认 caret 行为——modifier+open 与 click-edit 区分（NE-06）。

**测试**
- 新 `MiaoYanTests/MarkdownInlineEditingTests.swift`（18 用例）：wrap/
  unwrap/undo、四格式、code 双 backtick 拒绝、空选中取词、未选中范围
  字节不动、link label/target 独立、危险 scheme 拒绝、白名单矩阵、
  ⌘+click 开链接与非 ⌘ 判定面（`openLinkIntent`）、reference/footnote
  保留原位、unclosed/escape 原样可编辑、softbreak 段内精确映射、
  marker affinity 双边界（opening 后输入落结构内、closing 后输入落结构
  外）、heading 内 Enter 拆分（下半成无 marker 段落，原 marker 字节
  不动）。
- `RichMarkdownEditingTests` 补 2 用例：heading 内格式命令 marker 字节
  精确、format 命令 undo 回原文。

## 验证

本机 `xcodebuild test` 均带
`MACOSX_DEPLOYMENT_TARGET=12.0 CODE_SIGNING_ALLOWED=NO`
（本机 Xcode 不支持 11.5 target，仅命令行覆盖，工程设置未改；CI 上
runner 用 11.5 兼容工具链）。

| 项 | 结果 |
|---|---|
| `MarkdownInlineEditingTests` | **18/18 passed**（与 `RichMarkdownEditingTests` 同跑 37/37，TEST SUCCEEDED） |
| `RichMarkdownEditingTests` | **19/19 passed**（含新增 2 用例） |
| 全量单测（最终，修正后） | **394 tests：391 passed + 3 failed，失败全为既有环境用例（2 Mermaid + 1 Math，Sandbox restriction，与 T08/T09/T10 基线一致），无新增失败**。此前一轮全量的第 4 个失败是本次新测试自身坐标错误（`testScannerSkipsReferenceAndFootnote`：选中 display 1 却按 2 写期望——view 行为正确；该用例在前几轮被截断的运行中从未执行到，首次执行即暴露，修正后过） |
| swiftlint --strict | 改动文件 0 违规 |
| swift-format --strict | 改动文件 0 **新增**违规（全仓 18 个存量违规为基线，逐行 diff 确认无一条来自本次改动） |

### 测试环境踩坑记录（后续任务参考）

1. **`NSEvent.mouseEvent` + `mouseDown(with:)` 的 super 路径不能在
   XCTest 环境驱动**：无真实事件源时 `super.mouseDown` 同步等待窗口
   服务（主线程卡 `nextEventMatchingMask`；全量跑靠 LS 查询超时后 18s
   侥幸通过，单跑死等）。⌘+click 命中 link 提前 return 不碰 super，
   可安全驱动；其余修饰只测判定面。为此把 modifier 判定抽成纯方法
   `openLinkIntent(modifierFlags:)`。
2. **此前多轮"套件通过"记录不完整**：两次后台跑在 suite 切换处被
   截断，`MarkdownInlineEditingTests` 有 5 个用例（scanner/modifierClick/
   softbreak/unclosed/updateLinkTarget×2 中若干）从未执行到，全量跑才
   首次覆盖并暴露 1 个断言坐标错。教训：以 `Executed N tests` 行为
   准，不以"无失败输出"为准。

## 未验证范围

- `applyInlineFormat` / `updateLinkTarget` 尚无菜单/快捷键入口（⌘B/⌘I
  等）——命令 adapter 接线在 T12（"rich/command adapter 最小连接"），
  T11 交付为 view API + patch 语义，测试经真实 input 事件驱动。
- 实机 UI 冒烟（AX 驱动 native 面选中→格式命令）推迟到 T12 命令入口
  落地后一并做——无 UI 入口时实机只能复现测试已覆盖的 API 路径。
