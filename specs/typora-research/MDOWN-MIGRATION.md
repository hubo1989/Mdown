# Mdown 现有依赖、编辑入口与迁移风险

状态：2026-10-14 源码只读核验，基线 `main@b8110a942e27ae13ebe531b549a56e5a220f91ae`。本轮未 build/test/启动应用，以下运行风险为静态证据支持的待复现项；未修改业务代码。

## 1. 实际需要替换三条 JS 编辑依赖

当前源码同时有原生源码编辑器与 Vditor 富文本编辑器。不能概括为“只有 NSTexView、WKWebView 仅做预览”，也不能把所有 Web 资源都叫“原 JS 编辑器”。

| 部件 | 真实入口 | 是否属于编辑链路 | 建议 |
|---|---|---|---|
| 原生源码编辑 | `Views/EditTextView.swift:40`，继承 NSTextView | 是，已有原生入口 | 保留，先接统一 MarkdownEditingSession |
| Vditor WYSIWYG | `Views/VditorEditView.swift:18`；`Controllers/ViewController.swift:1104`；`Resources/DownView.bundle/editor.html:105` | 是，WKWebView + JS | 原生投影通过 G0 后替换宿主、桥接与专属资源 |
| Highlightr | `Helpers/CodeBlockHighlighter.swift:46`、`:54` | 是，源码代码块/HTML 高亮 | 单独原生高亮替代，不能只删除 Vditor |
| Prettier / PrettierMarkdown | `Controllers/ViewController+Editor.swift:13`、`:21`、`:36` | 是，显式 Markdown 格式化 | 原生格式化命令替代，保留可撤销和保护范围 |
| CMarkGFM | `Business/Markdown.swift:344` | 原生解析/预览 HTML | 保留；不把 HTML sourcepos 直接作为原文选择映射 |
| 预览 WebKit | `Views/MPreviewView.swift:27` | 主要渲染，仍有 checkbox 编辑桥 | 保留渲染宿主，但内容修改需归原生事务 |
| 图表/PDF 导出宿主 | `Helpers/RenderedBlockExportController.swift:434`、`Helpers/PdfExportController.swift:52` | 独立导出 | 可与编辑替换解耦；D 线继续独立验收 |

Package.resolved 固定 Highlightr 2.3.0（第 5–10 行）、Prettier 0.2.1（第 23–28 行）、swift-cmark-gfm 1.0.2（第 41–46 行）。macOS target 对应依赖 product 在 project.pbxproj；删除前需核验当前 target 的所有 callsite。

旧 build 产物中的 Highlightr/Prettier 对象与资源含 JavaScriptCore/JSContext、highlight.min.js、standalone.js、parser-markdown.js。这支持依赖内部用 JS 的判断，但产物不等于当前 HEAD 的运行证明；dependency checkout 已不在，未补安装或 fetch。

## 2. 原生源码路径已存在，尚缺统一会话/投影

`Helpers/CustomTextStorage.swift:3` 是 NSTextStorageDelegate extension，名称不表示自定义 NSTextStorage 子类。`Controllers/ViewController.swift:1243` 安装 delegate；高亮经过 NotesTextProcessor 和 CodeBlockHighlighter。`Helpers/MarkdownRuleHighlighter.swift:61` 的 Markdown regex/attribute 部分是原生，HTML 标签路径第 377/383 行仍进入 Highlightr。

`NotesTextProcessor.swift:51` 的 hideSyntax 默认 false。通过样式隐藏标记不等于已经建立 source/display 映射或完整 WYSIWYG 结构编辑；当前没有查到现有 MarkdownEditingSession、MarkdownSourceMap、RichMarkdownTextView 实现。

cmark rendering 入口 `renderMarkdownHTML` 对 math 预处理再把 native C parser 输出转 HTML；`Note.getPrettifiedContent`（`Business/Note.swift:513`）还处理 Wikilink 和 frontmatter。输出的 sourcepos 已受到预处理影响，不能当作未经变换的原文 UTF-16 列位置。

## 3. Vditor 的 setter 错配是实施前阻塞

已核验三份当前随包文件：

- `editor.html:146`：setMarkdown 先把 isUpdatingFromSwift 设 true，再调用 `editorInstance.setValue(markdown, callback)`；仅 callback 或 catch 将其复位。
- `vditor/dist/index.d.ts:65`：第二参数实际是可选 clearStack boolean。
- `vditor/dist/index.js:15754`：setValue 处理内容并在 clearStack 为真时清空 undo；没有调用第二参数的 callback。

**静态支持的失败场景：**正常 setMarkdown 成功后，没有该 callback，isUpdatingFromSwift 保持 true；`editor.html:138` 跳过后续 input 通知；作为第二参数传入的 function 又是 truthy，导致 clearStack 执行。Swift 侧 load/apply 的调用在 `VditorEditView.swift:151`–`:161`。

本轮没有运行复现，也没有修改 setter。实施前应先用实际 App 加载→输入→消息→Note.content→保存的回归场景证明症状，修复加载状态与 setter 合同；仅改一个 setTimeout 不会解决下节的会话/生命周期问题。

## 4. owner 保护需要增加同 owner 的 revision

现有 `EditTextView.publishStorage`（`:989`）记录 storageNote；`saveTextStorageContent`（`:994`）拒绝跨 URL owner 写入，但同 URL 的旧 buffer 仍可写。源码输入有 object identity 检查（`ViewController.swift:1319`），之后进入 Note.save。

Vditor change handler（`VditorEditView.swift:108`）只读 markdown payload，没有 noteID、generation、revision 或 main-frame 身份。`:164` 先赋 Note.content，再等待外层 0.5 秒调用 Note.save；Note 的已有保存 debounce 约 1.5 秒。这不是统一 session，两个计时层可能给生命周期留下空窗。

以下入口目前仍从 source editArea 采内容：

| 入口 | 位置 | 静态风险 |
|---|---|---|
| Cmd+S | `Controllers/ViewController+Action.swift:1618` | 同 owner 的隐藏旧 source 通过 guard，覆盖 Vditor 更新 |
| 关窗 | `Controllers/MainWindowController.swift:273` | 先采 source，再 flush；新编辑面未统一接入 |
| 退出 | `Controllers/AppDelegate.swift:164` | 同样依赖 source buffer |
| 失焦 | `Controllers/MainWindowController.swift:257` | 只检查 Note.needsSave；Vditor 外层 0.5 秒期间可能尚未置 dirty |
| duplicate 等内容命令 | `ViewController+Action.swift:555` 等 | 必须明确当前权威正文，而不是不分模式采 source |

**建议：**session identity 包含 Note 实例、canonical URL、generation；每次 commit 有 expectedRevision、源码 patches 和旧文本校验。Note.content 是已提交快照；隐藏 source 同步到同 revision，或标记失效并拒绝采集。先让源码模式接入统一 session，再接原生富文本模式。

## 5. 可复用的存储能力

保留 `Business/Note.swift` 的 dirty/debounce/flush、原子写入、缺失文件拒写、retire 防回调复活；关键位置第 557/592/602、626/729/743 行。成功保存后的版本和 Wikilink 更新（`:662`）继续沿用，不另建一套与它竞争的保存定时器。

`Business/NoteVersionManager.swift:19` 对 Note.content 做后台快照；`VersionHistoryViewController.swift:482` 恢复后直接 fill source；`Helpers/FileSystemEventManager.swift:246`–`:302` 冲突备份读 editArea.string、更新 Note 并清 undo。这些入口需改为 session authority，而不是只在新视图内部完善保存。

附件、重命名、移动、Trash、iCloud/symlink 和外部 watcher 也需绑定 owner/revision；沿用已有不复活/原子写入边界，不借本轮重构改变存储格式或 iOS 附件约定。

## 6. IME、选区与两套历史

- Note 为每笔记分配 UndoManager（`Note.swift:18`）；EditTextView 在切换时路由该 manager（`:552`）。
- `MainWindowController.swift:151` 的 undo 路由认识 EditTextView；新原生视图需要显式接会话，不能默认落到列表 undo。
- Vditor 有自身 DOM-diff undo（随包 index.js:14258），未见与 Note manager 同步。
- 原生部分有局部 hasMarkedText guard（`EditTextView.swift:871`、`:1301`、`:1319`、`:1337`）；NSTextStorage 样式扫描尚未看到统一 marked-text gate。未见模式/笔记切换的完整 composition commit/cancel 合同。
- 源码 cursor 第 905/970 行做 xattr 保存/恢复；Vditor bridge 没有 source selection map。
- 异步 format apply（`ViewController+Editor.swift:978`）检查 requestID、URL、owner，未检查同笔记输入后的 revision；随后全 buffer replace（`:1001`）及保存（`:1006`）。继续输入/undo 后旧结果覆盖新 source 是待复现风险。

TextFormatter 可以留作 source command fallback，但其 NSRange 不能直接套到富文本投影。新视图的隐藏 delimiter、附件占位和跨块选择均要经过 source map。

## 7. 预览、公式、图表与导出不宜整体删除

`DownView.bundle/index.html:61`–`:79` 加载 preview highlight.js、Mermaid、KaTeX、Markmap 等；它们与 Vditor 专属副本可能不同。`diagram-handler.js:46` 使用本地 Mermaid SVG，`:153` 有远程 PlantUML URL，`:195` 是 Markmap。当前预览不能自动称为“全离线渲染”，原生替换需明确这些依赖策略。

`Business/HtmlManager.swift:761` HTML 导出仍有 CDN base；资源路径/离线合同需独立改进。块导出与 PDF 有独立 WK 宿主，既有保存面板和导出控制器可先保留；禁止为删除 Vditor 而删整个 DownView.bundle。

预览 checkbox 也会写正文：`Views/MPreviewHandlers.swift:17`–`:32` 取全局 EditTextView.note，按 checkbox 序号修改 Note/save。严格去 JS 编辑链路时，应改为原生事务入口或原生控件；否则仅移除 Vditor 仍保留 JS 驱动正文修改且存在旧 preview 的 owner 问题。

## 8. 既有 W/D 方案与当前代码有漂移

既有 SPEC 第 144–148 行明确选择 AppKit 富文本投影，**不采用网页编辑器**；PLAN 第 104–146 行定义 TextKit 1 的 W0/G0/W1/W2、原文 source map、MarkdownEditingSession 和 RichMarkdownTextView。首轮 Typora 报告把 W 线描述成 WKWebView 路线是不准确的。

既有文档基线是 main@668e367 并写“未实施”；当前 HEAD 已接 Vditor 和图表导出控制器，不能用旧状态判断当前实现。此次只记录漂移，不擅改其产品决策或计划正文；继续保留原生 G0 与单 Mermaid D 线的独立优先级。

推荐正式组件名优先与既有方案一致：`MarkdownEditingSession`、`MarkdownSourceMap`、`RichMarkdownTextView`。新计划中的 Native* 名称均是暂定角色，不意味着要另造平行组件或重复事务层。

## 9. 有效测试边界

| 测试 | 已看到的断言 | 本轮限制 |
|---|---|---|
| `EditorStorageOwnershipTests.swift:38` | 跨 note/同 URL owner 的 storage/save 条件 | 未运行；未覆盖同 owner 旧 revision |
| `NoteSaveDebounceTests.swift:36/67/194` | dirty、flush、删除后不复活 | 未运行；不自动覆盖 Vditor 外层 debounce |
| `VditorIntegrationTests.swift:31/103/135` | 资源、view state、load/currentNote 等 | 不实际验证键入→桥→保存、round-trip 或 IME；`:175` 的缺 VC 路径直接 return |
| pbxproj / shared scheme / CI | tests 已注册，scheme skipped=NO，CI 运行 | 注册与配置不等于当前 HEAD 已通过 |

需要补：同 owner 的 revision 竞争、marked text 真实输入、跨模式 undo/source map、formatter 期间继续输入、Vditor 加载后 input bridge、外层 debounce 未执行时关窗/退出、watcher/恢复权威快照。性能和导出保真仍需真实结果。

## 10. 最小替换边界与顺序

1. 把 setter/生命周期/owner/revision 的既有阻塞做实际复现，先冻结当前行为与测试基线。
2. 在 source 模式建立 MarkdownEditingSession，统一 commit、保存、生命周期、watcher、附件/版本恢复与内容命令；保留现有 Note 保存服务。
3. 按既有 W0/G0 用 TextKit 1 验证原生显示投影、最小 source patches、真实 IME、跨块选区和 undo。
4. 原生投影通过后替换 Vditor host、handler、模式路由与专属资源，新增 view 接系统 undo/菜单/字体/主题。
5. 分别替换 Highlightr 和 Prettier，核验所有 direct/indirect callsite 后移除产品和资源。
6. 保留 cmark 和渲染/导出边界；如目标扩展到整应用零 JS，则为公式、图表、演示和 HTML renderer 各立兼容合同后逐项实施。

本轮结果是具体迁移准备和静态风险清单；没有宣称这些问题已修复或整个编辑器已本地化。
