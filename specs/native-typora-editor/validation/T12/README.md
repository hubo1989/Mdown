# T12 — 输入规则、list/quote、跨块结构

日期：2026-10-20。基线：T11 head `2cb6867` 之上，分支
`feat/native-typora-editor-t12-input`（栈式 PR，目标 T11 分支）。

## 交付

**行级结构模型（`Business/MarkdownBlockModel.swift`，新建）**
- `MarkdownBlockLine`/`MarkdownBlockModel.parseLine`：单行结构前缀解析——
  quote 前缀（含层间空白）、bullet `- + *`、ordered `1. 1)`、GFM task
  `[ ]`/`[x]`；紧贴内容（`-x`/`1.x`/`- [x]abc`）不认 marker。CRLF 行尾
  整体剥离（NE-03）。
- **混合嵌套**：quote 分支对前缀之后的内容递归跑 list/task 解析，
  `> - [x] t` 一次解析出 quote 层 + 内层 list + task（kind 取内层，
  `quotePrefixText`/`quoteDepth`/`markerOffsetUTF16` 携带外层）。quote 内
  list 的 Enter/Tab/toggle 失效缺口由此收敛。
- 结构命令规划（纯函数 → 原子 `SourcePatch`）：
  - `planEnter`：非空拆分（前缀照抄、有序编号只新项 +1——含 ordered+task
    组合与多位数进位；task 复位 `[ ]`）；空项**由内向外**退层（内层缩进
    → 内层 marker → quote 层 → 删行退出，SPEC §4.3）。
  - `planTab`：缩进插 2 空白；退级先内层缩进、再 quote 行内多余间隙
    （`>   - a` Shift+Tab → `> - a`）、最后 quote 层；最外层吞键无操作。
  - `planBackspace`：嵌套项块首先退一级缩进（不变懒延续行）；内层
    marker 剥除；quote 逐层退（`>> ab` → `> ab` 保分隔空格）；最外层退出。
  - `planDeleteForward`：空结构行删整行。`planTaskToggle`：括号内单字符。
  - 所有删改 patch 的 `expectedText` 从 source 实取（tab/混合缩进不再
    硬编码 `"  "` 失配吞键）；应用失败时 handler 返回 false 交还默认
    行为，不吞键。

**输入规则（`Helpers/MarkdownInputRules.swift`，新建）**
- 空段前缀完成匹配（heading 1–6 / bullet / ordered / quote ≤3 层），
  缩进前缀同规则；保护块（code/html/table/frontmatter）排除；CRLF 行尾
  与 LF 同规则。转换不改 source（parser 投影接管），匹配结果用于 undo
  重组与观察口。

**undo 单元重组（`Business/MarkdownEditorHistory.swift`）**
- `collapseTypingPrefix`：前缀完成时把构成该前缀的连续纯插入 typing
  entry 合并为**单条单 patch**（合并 patch 坐标属不同中间版本，逐 patch
  重放会错位——单 patch 化后 undo/redo 不变量成立），一键 undo 回完整
  字面前缀；链不完整保持既有粒度；重组时清空 redo 栈（消除对调用顺序
  的隐式依赖）。

**view 接线（`Views/RichMarkdownTextView.swift`）**
- Enter/Tab/Shift+Tab/Backspace/Delete 结构命令路由 + 输入规则触发 +
  caret 经 source→display 映射恢复（新空行零显示长时回退下一 unit/
  display 末尾）。
- 跨块替换 span 路径收紧：两端点必须落在**不同投影块**（单块选区含隐藏
  inline marker 安全拒绝，恢复 T11 语义）；终点在块缝时吸收下一块起点
  隐藏 marker（不再泄漏成可见字面）。
- 组合输入（marked）期间的单块 patch 校验移除块长限制——投影块长在组合
  中是冻结快照，长候选更新/取消会误拒（实测中文 `zhong` 更新被拒残留在
  display）。
- task 勾选字面 `[x] `/`[ ] ` 保持可见（投影改 parseLine 后的连带回归
  修复；T14 原生勾选框前的过渡态）。

**投影（`Helpers/MarkdownProjectionBuilder.swift`）**
- heading marker 长度改实测（缩进 + `#`×level + 分隔空白）——裸 `#` 无
  空格时不再吞换行（旧 `level+1` 越界根因）。
- 行前缀统一走 `parseLine`（quote 混合行隐藏完整前缀，内层 list marker
  不再显示字面）；删除死代码 `quotePrefixLength`。

## 验证

本机 `xcodebuild test` 均带
`MACOSX_DEPLOYMENT_TARGET=12.0 CODE_SIGNING_ALLOWED=NO`
（同 T11，工程设置未改）。

| 项 | 结果 |
|---|---|
| `MarkdownListEditingTests`（37 用例） | **37/37 passed**，含三层 bullet、quote×list 混合（拆分/空项退级/Tab/Backspace/toggle）、有序 task 编号、块缝 caret、跨块替换（含块缝终点吸收与单块隐藏 marker 拒绝） |
| `MarkdownInputRulesTests`（20 用例） | **20/20 passed**，含 CRLF 行尾矩阵 |
| 相关七套件合计 | **131/131 passed**（Projection 18 + History 14 + Composition 9 + Inline 18 + RichEditing 20 + List 37 + InputRules 20…以 `Executed 131 tests, with 0 failures` 为准） |
| 全量单测 | 最终轮 **447 tests：439 passed + 8 failed（3 用例：MermaidExportTests×2 + MathRenderingRuntimeTests×1，Sandbox restriction，与 T08–T11 基线一致），无新增失败** |
| SwiftLint `--strict`（改动 7 文件） | 0 violations |
| swift-format | 本机 brew 版 604.0.0 全仓报数百处（T11 基线 18 处为旧版工具所测），**工具版本漂移**，改动文件在该版本下无法作有效新旧对比；代码风格按仓库既有形态书写。CI 的 swift-format job 待合栈触发后核实 |
| RED→GREEN | 12 个新用例先跑 RED（20 断言失败，逐条对应本任务修复的缺陷），实现后 GREEN |

### 实机冒烟（Debug build，AX 驱动）

- 视图菜单「切换所见即所得」切入 native 投影：AXTextArea 值由
  `- [x] ab` 变为 `ab`——marker 隐藏生效（T10 结论复现）。
- 键盘输入自动化经系统中文 IME 合成（拼音分隔符混入 display），无法作为
  精确断言源；改用剪贴板粘贴路径驱动，模式切换时序不稳。**逐键结构编辑
  的实机冒烟未完成**，以单测矩阵 + G0/T10 实机投影结论为证。

## 已知限制（不阻塞 T12 退出门的边角）

- 输入规则 ordered 限 1–9 位数字（`10. ` 两位数可触发，10 位以上极端
  长编号不转换；parseLine 本身无此限制）。
- `planDeleteForward` 的 caret 容忍窗为内容起点前后 1 unit，未覆盖
  marker 侧更左位置（注释已按实际守卫书写）。
- 行首 tab 缩进的 ordered 行按 CommonMark 是 indented code，不属 list
  结构命令管辖（测试矩阵以此为准，不造反 CommonMark 期望）。
- BOM 开头的 heading marker 映射错位（新旧皆有的既有边角，投影入口未
  跳过 BOM unit；已在审查记录，留 T14/T21 顺手修）。

## 未验证范围

- 真实 IME 候选窗下 list/quote 内的组合输入（单测以 AppKit input
  protocol 形态覆盖，候选窗交互留实机，G0/T19 范围）。
- swift-format CI job：工具版本漂移待合栈到 main 后由 CI 实际裁决。
- 跨块粘贴（T13）、preview checkbox intent（T14）按计划不在本轮。
