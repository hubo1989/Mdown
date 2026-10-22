# T15 验证记录(阶段 1:tokenizer + source 编辑路径)— 2026-10-22

前序 `8a62fd6`(T14)。本记录只覆盖已落地部分;T15 未完成项在文末如实列出。

## 已交付

- `Helpers/NativeCodeHighlighter.swift`:SPEC §8.1 首批 9 语言族(Swift/ObjC/C/
  C++/JS/TS/Python/JSON/HTML/CSS/Shell/SQL/YAML)的 UTF-16 token 化。
  token 是原文不相交子区间,正文零改写;未闭合 string/comment 吞到末尾
  不崩溃;alias 表(含 `c++`/`ts`/`yml` 等)驱动,未知语言返回 nil →
  plain code 样式。
- 子代理静态审查发现的 5 类真实缺陷已修并有回归测试:数字吞运算符/
  `1...3`/SQL `1--`;Python 无前缀字符串双推进(空串吞行、裸三引号);
  HTML 标签 token 契约(`<p`/`</p>` 合并、属性止于 `=`);C `'"'` 字符
  字面量误开串;JS 模板/Shell/SQL 单引号跨行截断;Swift 嵌套块注释。
- source 编辑路径去 Highlightr:`CodeBlockHighlighter.highlightCode` 改为
  native token 上色(基础样式打底 + 类别色,明暗两套,保留体积上限/
  skip 逻辑与 `.codeBlock`/`.codeLanguage` 属性);`NotesTextProcessor`
  删除 `hl`/`getHighlighter`,`getLanguage` 改按别名表判定(`go` 特例
  随之取消——那是 Highlightr 的 bug 规避);`EditTextView`/`PrefsModel`
  移除 Highlightr 引用。**Highlightr 包保留,T22 统一退依赖。**

## 验证

| 项 | 结果 |
|---|---|
| `NativeCodeHighlighterTests`(22,含 5 组回归 + 集成冒烟) | **22/22**(RED→GREEN) |
| 全量套件 | 542 tests,8 failures = 既有 3 个 WebKit 环境用例的多次断言(与 T14 HEAD 同集,worktree 复跑已证) |
| Debug build | **BUILD SUCCEEDED** |
| SwiftLint --strict | 0 violations |
| swift-format(触及文件) | 0 violations;仓库另有 T10–T12 既有文件(MarkdownEditorHistory/MarkdownEditingSessionTests/MarkdownInputRulesTests)的历史格式偏差 50 处,非本轮引入,不在此顺手改 |

过程事故(如实记录):一次 python 切片误删 NotesTextProcessor 中段
(~470 行),编译失败暴露后以 `git show HEAD:` 恢复基线并重做精确替换,
最终文件与 HEAD 的差异仅为上述刻意改动;期间无提交。

## 阶段 2(同日补交):rich 面 fence 高亮

- `RichMarkdownTextView.applyDisplayAttributes` 的 codeFence 分支接入
  `NativeCodeHighlighter`:fence 块投影 1:1(plainFallback),token range
  直接平移到 display;明暗 palette 复用 `CodeBlockHighlighter.tokenPalette`
  (开放为 internal)。超限块(500/3000)与未知语言回基础样式;marked
  期间 rebuildProjection 早退,属性不漂移;只动属性不动 source/history/
  revision。
- 后台异步暂不做:单块同步 tokenize 为微秒级(22 用例含 64k 行 <1s),
  无跨帧 stale 风险;若 T21 压测暴露主线程尖峰再引入按 revision 拒
  stale 的异步管线(记录为待验证假设,不是已证事实)。
- 测试:`RichMarkdownEditingTests` 新增 2 用例(token 上色/超限与未知
  语言回基础),套件 20/20;tokenizer 22/22;全量 542(同 8 环境失败)。

## 阶段 3(同日补交):块级命令

- `RichMarkdownTextView.setCodeFenceLanguage`:只替换开围栏后的 info 串
  (backtick/tilde 3+ 运行),内容与定界符字节不动,单条 source 事务
  可撤销;fence 外 false。
- `exitCodeBlockAtCaret` + ⌘Return 路由:fence 内退出块 = 块后插空段落
  (EOF 变体补段),caret 落新行,一次 undo;块外交还默认键行为。
- 测试:5 例(语言替换+撤销/块外拒绝/裸围栏插 info/退出块 caret+undo/
  块外退出拒绝),套件 25/25。

## T15 剩余(不声称完成)

1. 语言界定符的**面板 UI**(本阶段交付 source 事务命令面,面板入口留
   T19/T23 设置界面)。
2. Highlightr ↔ native 的 golden 对照——包已随 T22 移除,无对照基准;
   以 T15 的 22 例 token 边界 corpus 为行为基线。压力测量见
   validation/T21(单样本)。
3. ~~T14 遗留~~ 已闭环:checkbox 正向写盘实机证据见 validation/T14
   (2026-10-22,旧构建/新构建对照)。
