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

## T18 剩余(不声称完成)

1. 接 `ViewController.formatText` 的 markdownFormatWorker 替换
   (现有 Prettier worker 退役留 T22),以 source patch/整篇替换事务
   应用、单步撤销、失败/取消不写正文、revision 失配拒绝。
2. 与旧 Prettier baseline 的 golden 对照与有意差异登记。
3. link target/reference 值、inline raw HTML 的保护段边界扩充。
4. 实机 format 命令矩阵(IME 中取消、切笔记竞争)。
