# T19 验证记录(阶段 1:typewriter 与输入策略分流)— 2026-10-22

前序 `616baf3`(T18 part 2)。只覆盖已落地部分。

## 已交付

- `RichMarkdownTextView`:
  - `isTypewriterMode` + `typewriterScrollOffset`(纯几何,nonisolated,
    caret 行中心对准视口中心并 clamp 到内容边界,不足一屏回 0);
    caret 恢复路径(`restoreSelectionFromSource`)接入滚动居中。
    开关只改 view state:不推进 revision、不入历史、不动 dirty。
  - init 关 continuous spell(保守策略:code/math/URL 不得被 spell
    改写;按 range 精确分流的开关留 N2 如实记录);automatic
    quote/dash/text replacement 已在早期阶段关闭,补断言钉住。
- `MarkdownEditorHistory.debugDepth` 观察口(测试断言 view-state 不入
  历史用)。

## 验证

| 项 | 结果 |
|---|---|
| `NativeEditorViewStateTests`(7,PLAN T19 指定文件) | **7/7** |
| 全量套件 | 583 tests,8 failures = 既有 3 个 WebKit 环境用例(基线已证) |
| SwiftLint --strict | 0;触及文件 swift-format 干净 |

## 阶段 2(同日补交):focus 降噪 / 滚动锚 / 菜单审计

- focus 降噪(NE-32):caret 块之外的块前景降 40% alpha;code fence 的
  token 色只涂活跃块(降噪块平色,避免活跃色残留);关闭开关幂等恢复
  全彩;caret 移动经 textViewDidChangeSelection 钩子(视图自身即
  delegate)。只动显示属性:revision/历史/dirty 有断言钉住。
- zoom/mode 滚动锚:refreshFontAttributes 先快照 caret 视口偏移,
  重排后按 anchoredScrollOffset(纯几何,2 用例)顶回原位置。
- 菜单 ObjectID 审计:脚本比对 storyboard 全部 menuItem id 与四语
  Main.strings(分隔符免译)——发现 7 个真缺(Code Block/Inline Code/
  Copy Path/Open in Terminal×2/HTML/PDF/Format)静默发英文,已补译并
  复跑 AUDIT PASS。
- 测试:NativeEditorViewStateTests 11/11;全量 629/629。

## 阶段 3(`15d7c87`,10-22):WYSIWYG 渲染排版

- projection segment 增加带样式的 kind:`strongBody` / `emphasisBody` /
  `strikethroughBody`(按 marker 分型:`~` 串=删除线,≥2 星=粗体,单星=
  斜体)与 `linkLabel`;display 字节与 display↔source 映射不变,只加
  渲染语义。
- `applyDisplayAttributes` 排版:标题分级放大(1.7x..1.0x)加粗;引用
  降 alpha;frontmatter/html/math/thematic-break 变暗;code fence 与
  code span 叠主题背景;链接 label 强调色+下划线。focus 降噪一致性
  保持:彩色装饰只涂活跃块,降噪块维持 40% 平色。
- 测试:RichMarkdownEditingTests +87(标题分级/粗斜删除线/链接强调/
  code 背景/降噪一致性 5 组 + 2 个投影 oracle 更新);当时全量 646/646。

## 阶段 4(`c05306d`+`ee0a409`,10-22~23):预览排版对齐 + 模式互切

- 入口与状态(`c05306d`):工具栏补 WYSIWYG 入口,菜单打磨,状态统一;
  四语 Localizable.strings 补译。
- 预览排版参数对齐(`ee0a409`,新增 `RichMarkdownTextView+Appearance`):
  与 DownView.bundle 预览 CSS 实测值共用同一套常量——正文/标题行高
  1.74/1.8,标题 2/1.5/1.25/1em,段距按基准字号(em 相对 html 基准,
  非标题自身字号),链接色 #0C6ADA/#1D9BF0,code 背景 #f7f7f7/#282e33,
  正文 #262626/#E7E9EA;host 注入 previewFontName/previewFontSize/
  codeFontName(与 HtmlManager previewStyle 同源),且先设色后刷新。
- 属性残留修复:rebuildProjection 的 display 不变分支重铺基础字体/
  前景/段落样式,**x** 两次包裹/解包不再残留旧粗体。
- 逐行列表 marker:容器块每行在 headIndent gutter 自绘 bullet/序号
  (深度取整除规则钉为单一事实源,序号在深度退出与 bullet↔ordered
  切换时重置);display 字节与映射不动。
- 预览 ⇄ WYSIWYG 互为切换:从预览进 WYSIWYG 预置恢复目标(不再翻
  savedLayoutModeBeforePreview 落回 source);工具栏两按钮互斥(预览
  展示期间 wysiwyg 不亮)。
- 实机冒烟(smoke copy)已验:H1/H2 层级、粗/斜体、蓝色下划线链接、
  inline-code chip、code-fence token 色(预览背景)、逐行 bullet。
- 提交时全量 650/650;strict lint/format 干净。

## 复验(2026-10-23,接续会话)

| 项 | 结果 |
|---|---|
| 全量套件(基线命令,`MACOSX_DEPLOYMENT_TARGET=12.0` override) | **651/651**,0 failures |
| SwiftLint --strict | 0 violations(205 文件) |
| 触及文件 swift-format --strict | 干净 |

注:仓库级 `swift-format --recursive .` 会扫到 `Build/Intermediates`
下 T22 退场前的 Prettier 产物(非源码),检查按触及文件口径执行。

## 视觉矩阵实测(2026-10-23,含 Retina/深浅色)

隔离 smoke 副本 `com.mdown.t19.smoke`(独立 bundle ID + 临时库),
语料含 H1-H3/粗斜删链接/引用/列表/表格/图片/长代码/数学/mermaid。
本机 Liquid Retina XDR + 外接 4K,截图 3024x1792(2x)。

| 象限 | WYSIWYG | 预览 |
|---|---|---|
| 浅色 | 标题层级/粗斜删/链接蓝/inline-code chip/引用降噪/bullet 正确 | 同左 + 表格网格 + 图片真实 + 数学渲染 E=mc² + mermaid 流程图 |
| 深色 | 同上,链接/code chip/引用深色一致,无白底残留 | 同上,深色主题正确换色 |

结论:
- **T19 排版对齐(ND 范畴)通过**:标题层级、行高、链接色、code 底色、
  引用降噪在深/浅色均与预览视觉一致(Retina 2x 无模糊)。
- **特殊块仍是原文**(数学 `$$`、mermaid fence、表格管道、图片 alt
  占位),仅预览渲染——这是新 PRD `wysiwyg-display-parity` 的缺口,
  不属 T19 排版合同。
- **发现缺陷:有序列表 marker 错位**。WYSIWYG 中序号与内容错行错值
  ("1."脱离成独立行、"有序第一项"旁是"2."),预览正确(1./2./1嵌套/3.)。
  浅/深色均复现,与主题无关。归属逐行 marker 自绘实现(T19 part 4),
  需独立修复,不在排版常量范畴。
- 深色首启若未生效,检查 `appearanceType` 是否为 `<integer>`(plist
  类型);`defaults write ... 2` 默认写 string,`as? Int` 读不到会静默
  回退 System。这是测试设置陷阱,非产品缺陷。
- 预览首帧有 1-10s 加载延迟(WKWebView 冷启),初次截图空白属加载
  非故障,DOM 树最终完整(math/mermaid/表格语义均在)。

## T19 剩余(不声称完成)

1. **spell 按 protected kind 精确分流:AppKit 平台限制裁定** —
   NSTextView/NSSpellChecker 只有整视图开关,无 per-range 排除 API;
   N1 保守策略(富面整体关 continuous spell)保持,精确分流需
   NSSpellChecker 子类化,归 N2,不再列为可收窄缺口。
2. ~~font/line spacing/Retina/darklight 一致性核对~~ **已实测通过**
   (见上视觉矩阵);图片/table 宽度限制、长 code 局部 scroll 视觉已
   采(table 限宽生效、code 全铺待 ND-05 局部滚动)。
3. 实机 keyboard/VoiceOver(AC-17 真实验收,需人机交互)。
4. **有序列表 marker 错位**(新发现,见上)需修复。
