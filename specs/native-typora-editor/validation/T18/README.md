# T18 验证记录(阶段 1:formatter `mdown-preserve-v1` 纯逻辑)— 2026-10-22

前序 `4681e7e`(T17 part 1)。只覆盖已落地部分。

## 已交付

- `Helpers/NativeMarkdownFormatter.swift`(PLAN T18 指定 Create):
  - 保护段字节不动(fence/缩进 code/math/frontmatter/raw HTML,经
    LosslessMarkdownParser 块界 + 1 基→0 基行号对齐);
  - 非 hard-break 行尾空白清理(≥2 尾随空格保留;文档末行的尾随空白
    不构成 break,照常清理);
  - 连续空行折叠为单空行(保护段内不折叠);
  - 表格归一:cell 边缘单空格、对齐线 dash≥3 + colon 保留(复用
    MarkdownTableModel 解析,转义/code 内管道不拆);
  - prose 换行与既有 list 写法保持;幂等 f(f(x))==f(x);未知语法逐字
    保留。

## 验证

| 项 | 结果 |
|---|---|
| `NativeMarkdownFormatterTests`(12,含 1 基行号回归) | **12/12**(RED→GREEN) |
| 全量套件 | 576 tests,8 failures = 既有 3 个 WebKit 环境用例(基线已证) |
| SwiftLint --strict | 0;触及文件 swift-format 干净 |

## 调试记录(有证据链)

初版保护行收集用 0 基索引对比 parser 的 1 基 `Block.startLine/endLine`
(`from + 1`),症状:math 块后首行尾随空白被误保留、块内末行被误清理。
逐层 DIAG(rawLines→主循环→final return)缩小到 protectedLines 键不
匹配后定位;一次修复 + 独立回归用例(`testLineIndexBaseIsStableAcross
Blocks` 断言块内保留/块后清理两向)。诊断插桩已全部移除
(assert 复查 0 残留)。

## 阶段 3(同日补交):字节保真重写 + 迟到结果拒绝

- 复查发现第一阶段实现有 8 处内容保真失败(以 RED 测试实证):CRLF
  文档被整篇改写为 LF、无末行换行丢失、多张表格的第二张起使用漂移
  坐标可能替换错位、列表/引用内空行被折叠、reference 定义与多行
  inline code 的空白被改。重写为**同一原文坐标系的一次性 patch 计划**:
  以原始字节切行(逐行记录 content/full 区间与行尾),parser 只消费
  LF 分析副本,所有 patch 经 MarkdownPatchApplier 原子应用(expectedText
  全部取自原文切片);patch 应用失败保留整篇原文。保护段扩展:块级
  (fence/缩进 code/math/frontmatter/raw HTML)+ 行级(reference 定义、
  跨行 inline code span)。表格逐块解析、dash≥3、colon 保留。
- `NativeMarkdownFormatter.Snapshot`:format 发起时捕获 owner/URL/
  代际/revision/原文;`formatText` 两条路径应用前核对——格式化期间
  用户继续输入、undo 回同字节、切笔记、重装载,一律拒绝迟到结果并
  提示重试(SPEC §8.2"与当前不同则拒绝")。source 面应用改为经
  编辑路径整篇替换(与 cleanTypography 同款),结果可 undo/redo;
  删除死代码 replaceEditorStorage。
- 测试:`NativeMarkdownFormatterTests` 20/20(CRLF/BOM 精确字节、混合
  行尾、双表、CRLF 表格、列表空行、reference/多行 code、快照拒绝
  7 种漂移);相关套件 75/75;strict lint/format 干净。

## 阶段 2(同日补交):formatText 调用方退役 Prettier worker

- `ViewController+Editor.formatText` 两条路径(source buffer 与 native
  rich)改为 `NativeMarkdownFormatter.format` 纯函数同步跑(Task 内,
  取消即丢),结果经既有 apply 函数落为整篇替换事务;rich 面单步
  undo(T14 applyWholeSourceReplacement)、source 面整 buffer 替换。
  apply 函数去掉 Prettier 的 placeholder 还原/换行启发式/native
  formatter 已按 mdown-preserve-v1 保留尾换行形态),caret 从活动视图
  现取 clamp;内容无变化时提示 "Typography is already clean~"。
- `MarkdownFormatWorker` actor、`MarkdownFormatOutput`、Prettier/
  PrettierMarkdown import 全部删除;`markdownFormatWorker` 属性移除。
  源码 grep 仅剩注释提及;**包本身保留,T22 统一退依赖**(与
  Highlightr 同策略)。
- 验证:全量 576(同 8 环境失败),SwiftLint strict 0,触及文件
  swift-format 干净。修复了减参后的 NSRange 误下标(编译暴露)。

## T18 剩余(不声称完成)

1. 与旧 Prettier baseline 的 golden 对照与有意差异登记。
2. link target/reference 值、inline raw HTML 的保护段边界扩充。
3. 实机 format 命令矩阵(IME 中取消、切笔记竞争)。
