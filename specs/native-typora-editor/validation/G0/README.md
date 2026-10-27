# T04 / G0 — TextKit 1 / IME / undo 可行性门（通过）

日期：2026-10-14（初版）/ 2026-10-15（四项失败补齐后判定 PASS）。新增：`Views/RichMarkdownTextView.swift`（原型）、`Business/MarkdownEditorHistory.swift`（最小原型）、`Helpers/LosslessMarkdownParser.swift`、`Helpers/MarkdownProjectionBuilder.swift`、`Helpers/MarkdownSourceMap.swift`、`Business/MarkdownEditTransaction.swift`，及对应测试文件。全部纯内存 session，未接 Note/Storage/默认保存。

**判定：PASS（本轮修复后）—— 18/18 G0 相关 tests 绿（专项运行），架构探针通过。**

## 本轮四项失败修复（2026-10-15）

| # | 原失败 | 根因 | 修复 | 结果 |
|---|---|---|---|---|
| 1 | `testLargeDocumentProbe` build 3.2s / edit 3.1s | 每次编辑全量 parse+投影+textStorage 替换；init 双重 parse；emphasis 在每个字符尝试 5 种 marker | ① init 不再双重 parse ② `*_~` 预检跳过 95%+ 字符 ③ 简单文本编辑走增量快速路径（跳过全量重建） ④ `replaceCharacters` 替代 `setAttributedString` ⑤ display 不变时跳过 textStorage 替换 | **build 0.19s / edit 0.02s**（17×/130× 提升） |
| 2 | `testCompositionFollowedByTypingStaysConsistent` | `unmarkText` else 分支直接 `rebuildProjection()` 未恢复 selection（`setAttributedString` 重置 selection 到 0） | ① unmarkText 保存/恢复 selection ② `rebuildProjection` display 不变时跳过 textStorage 替换 | ✅ PASS |
| 3 | `testCommitDoesNotWholeReplaceWhileMarked` | `sourceOffset(forDisplay:)` 边界歧义取前段末尾（"行首 "末尾 = source 3 = `**` 前），candidate 插入在 emphasis 外部 | Segment 增加 `isOpening` 标记配对结构前半 marker；边界歧义时 opening marker 后取 next 内容段起点（Typora 语义：在"粗"前打字落在 `**` 内） | ✅ PASS |
| 4 | `testEnterSplitsListItemAtSameLevel` | ① parser `classifyLine` 条件 `stripped.hasPrefix("- "), stripped.hasPrefix("* "), ...` 逗号列表恒 false（4 空格缩进项被分类为 codeIndented）② 测试 display offset 4 在"二级"而非断言预期的"三级" | ① 修复为 `||` 条件 ② 测试 offset 改 7（"三级"内容内） | ✅ PASS |

附加修复：`testTypingPlainParagraphReachesSource` display offset 4→7（原文在"文"与"段"之间插入，断言却在"落"与"。"之间——测试注释中的 display 布局计算遗漏了 blank 行的 display 偏移 +2）；测试 makeView 挂 window（全量序列 firstResponder 稳定性）。

## 已验证能力（G0 合同）

- **直接编辑**：正文、heading 内容、emphasis 内容、code span 内容可直接编辑，source bytes 断言精确（`**AB**` 内输入不删 delimiter、backtick 保留、heading marker 原样）；点击/移动 caret 不改 source。
- **display↔source 映射**：opening boundary 取 next 内容段起点（Typora 语义）、closing boundary 取前段末尾；display 边界歧义经段级映射解析。
- **IME composition**：start/update/commit/cancel 链路 source 精确提交一次；组合期间不重建投影；**组合后 caret 正确恢复，连续直输不串位**。
- **三层 list 结构命令**：Tab/Shift+Tab、空项 Enter 退出、项首 Backspace、Enter 同级拆分（含三层嵌套）；**四级缩进项正确分类为 listItem（parser 修复）**。
- **undo/redo**：typing 与结构命令单一历史，undo 恢复原 source、redo 重放，selection 恢复。
- **性能**：200KiB/4408 行 build **0.19s**、edit **0.02s**（预算 2.0s/2.5s）。
- **架构探针**：单 TextKit 1 投影可承载 marker 隐藏/结构命令/IME；macOS 11.5 目标下编译通过。

## 本机环境事实

- `lsregister` 挂死已用包装脚本规避（详见 T00 BASELINE §2）；本机每轮构建+测试 ≈ 9 分钟。
- 测试宿主内 `insertText`/`setMarkedText` 不自动通知 delegate——已在原型 override 中显式 `didChangeText()`。
- 测试 makeView 挂 NSWindow（全量 vs 专项运行差异根因：firstResponder 状态顺序敏感）。

## 实机验证范围（未覆盖，AC-19/21 保持 not-run）

真实 IME 候选窗交互（中/日文候选选择、取消面板）、多窗口焦点切换下的 marked 状态、Sandbox 文件授权、iOS 读取。全部留 T05+/T21，本页不计 pass。
