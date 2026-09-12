# MiaoYan 所见即所得编辑与渲染块单独导出 — 实施 Plan

状态：方案待评审，尚未开始开发。需求和验收以 [SPEC.md](SPEC.md) 为准；本轮用户已明确“Mermaid 等渲染内容单张保存最重要，普通图片另存不是需求”，以此修正优先级与范围。

基线：`main@668e367e4937bd5c887562991400636ced1d3e58`，仓库 `/Users/hubo/Projects/Mdown`。开发前复查实际 HEAD/dirty changes；不直推 `main/master`，通过 PR → Review → Merge。用户本轮只要求规划，不修改业务代码、不提交推送、不启动发布。

## 1. 推荐顺序

**先交付完整、高清、没有裁切和缺字的单张 Mermaid PNG，支持合格 SVG；再扩展 PlantUML 和块级公式。** 普通图片下载不在任务图中，图表导出也不依赖 WYSIWYG。原生编辑的技术验证可并行，但不能挤占核心图表导出的实现与验收。

```text
B0 基线/测试样本
├─ D0 单图表目标 + PNG/SVG 验证
│  → D1 静态快照/隔离渲染/保存 → D2 右键交互/兼容/质量
│  → D-Gate: 单 Mermaid 独立交付
│  → D3: PlantUML + 块级公式扩展（第二里程碑）
└─ W0 原生编辑技术验证 → G0 可行性门
                         ├─ 不通过：保持现有编辑模式，不影响 D 线
                         └─ W1 会话/保存归属 → W2 原生基础编辑
                                                → W3 模式/命令/附件接入
                                                → W4 稳定性/文案/体验 → W-Gate
```

D0/D1 与 W0 可独立推进；涉及 `ViewController`、`MPreviewView` 或 `project.pbxproj` 的交叉集成串行进行，先合并 D2 再接 W3。D3 不阻碍单 Mermaid 首次交付；W 线不通过时，D 线仍可独立验收。

## 2. 阶段任务卡

### B0 — 固化基线、测试清单与样本

**目标：** 记录已有行为和证据，不先做视觉原型再补保存安全。

复查 `AGENTS.md`、`ARCHITECTURE.md`、实际 HEAD、dirty changes、两个 shared scheme 和 deployment target。运行现有 macOS Debug build/unit tests并记录基线错误；不顺手修无关失败，不把未运行结果记为通过。

复用 `EditorStorageOwnershipTests`、`NoteSaveDebounceTests`、`NoteFrontmatterTests`、`ClipboardManagerUTF16Tests`、`HtmlManagerTests`、`MermaidExportTests` 和 `TypographyCleanerTests`。修改超过 100 行的源文件前先补最小回归；无自动测试的 UI 行为在 PR 中明确写出人工 smoke 和其边界。

图表样本覆盖 flowchart/sequence/class/state/ER/gantt、当前引擎支持的 mindmap/ELK、中文/Emoji/长标签、HTML label、暗亮主题、一页多图及内容完全相同的两张图、超宽/超高图、无效源码和延迟字体。为 P1 准备 PlantUML、带编号的块级公式。仅生成测试笔记，不使用用户私密图表。W 线另备空文件、CRLF/BOM/frontmatter、复杂语法、长文和 Unicode 样本。

核对 vendored manifest 与实际资源 hash：Mermaid/KaTeX 的版本目前标记 `unknown`，不能在计划中假定在线文档对应现有 bundle，也不能借机升级依赖。已有 Mermaid 测试是整篇渲染基础，不是单图表导出已验证。

**产物：** 测试样本与基线记录。**退出条件：** D0 与 W0 能各自使用稳定样本，不改变默认模式或用户数据。

### D0 — 单图表命中与完整 PNG/SVG 技术验证

**关联需求：** D-01–D-05、D-07、D-08；**依赖：** B0；最高优先级。

验证 `MPreviewView.willOpenMenu(_:with:)` 与 JS contextmenu 的实际时序，保留既有选中文本逻辑；不得依赖固定 sleep、私有 WebKit API 或上一张图的缓存。对节点/连线/文字/内部空白均定位到同一个 Mermaid 容器；普通图片不出现新入口。

以实际 `.language-mermaid` 容器、`displayedNote`、页面代次和 render revision 标识对象，不仅凭 SVG ID：现有 renderer 会按内容缓存 SVG，相同内容的两个图可能复用相同内部 ID。成功条件必须是 `data-mermaid-rendered="true"` 且存在有效 SVG，不能只读 `data-processed`（失败也会置 true）。

分别验证两条 PNG 路径：受控单块 WKWebView 宿主按完整布局截图；SVG 序列化到 canvas 栅格化。重点比较 `foreignObject`、中文/字体、长标签、CSS 变量、箭头/阴影边界、负 viewBox、超出视口的图、分栏/缩放和宿主不可见时的输出。推荐前者，但是否能在 macOS 11.5 API 基线稳定工作必须实测；canvas 不通过 HTML label 样本就淘汰为通用路径。

`WKSnapshotConfiguration.rect` 必须在导出宿主 bounds 内，不能用超界 rect 解决长图；`snapshotWidth` 是 points，必须在不同 backing scale 下解码输出 PNG 核验真实像素尺寸，而非假定宽度乘 2 就是 2×。

同时将 SVG 脱离笔记独立打开，检查 defs、marker、clipPath、样式、字体与 HTML label；只复制 `outerHTML` 成功不代表独立文件有效。导出宿主若必须附着原生窗口才能 snapshot，验证不抢焦点/不闪窗的公开 AppKit 实现并记录限制。

**拟工作范围：** 最小测试宿主与 `MiaoYanTests/RenderedBlockExportTests.swift`；必要时加入独立实验 helper。不要先重构整篇 `exportImage()`，也不要搭通用远程图片下载器。

**退出门：** 同页多图/同内容双图正确命中，至少一份含中文和 HTML label 的 PNG 及一张超视口图完整导出，2× 像素尺寸正确，主预览不被滚动/重排。SVG 限定支持范围有证据。PNG 失败必须在此解决，不能用“仅 SVG”或“截图整页再手工裁切”替代交付。

### D1 — 静态快照、隔离渲染与原生保存

**关联需求：** D-02–D-08；**依赖：** D0 通过。

实现 `RenderedBlockExportController`，维护目标身份、render revision、请求 ID、用户目标 URL 和取消状态。冻结完整单块 SVG/HTML、必要样式/资源、逻辑边界和主题后再渲染，不能在每个异步步骤重新查“当前笔记第 N 张图”。冻结前目标变化则取消，冻结后只使用不可变快照。

实现 PNG：在受控导出宿主中放置这一个块，等渲染/字体/图内资源就绪，按真实逻辑边界与 16 px 建议留白设置画布，选择 1×/2×/3× 后得到明确输出尺寸。不把主预览截图当源，不混入标题、正文、滚动条、选区或背景上下文；超限拒绝并建议较低倍数/SVG，不截断/悄悄降清晰度。

实现 SVG：保留根 SVG、viewBox（含非零起点）、defs、style 和 ID 引用，把必要继承样式变为自包含；保留能安全显示的 HTML label，同时去除脚本/事件/导航等活跃能力。不兼容类型明确提示 PNG，不生产看似成功却缺字的 SVG。暂不引入 SVG 字体轮廓化或新的云端转换依赖。

打开面板前先做只读预检，等待块、字体和资源就绪，确定完整尺寸与 SVG 能力；未完成则显示可取消准备状态，不让用户确认未知像素尺寸。面板选择位置、PNG 倍数与背景，默认 PNG 2× 跟随预览背景；点击保存后复核 identity/revision/布局 fingerprint，匹配才冻结最终快照并编码写入，变化则取消并提示重新导出，不偷偷改变已确认的尺寸。建立生成中的非模态进度和取消，原子写入成功才提示。不要复用 `toastExport` 的模式重置/固定 Downloads 文案，不写 `i/` 附件目录，不修改 Markdown 和 dirty。

导出宿主仅访问 app 管理的导出目录及明确允许的资源，不继承主预览的 `/` 读取范围。冻结/桥接前检查大小与身份，阻止任意原生路径、外部脚本、iframe、新远程访问；所有结果/错误经过有限的导出 API。

**拟新增/修改范围：** `Helpers/RenderedBlockExportController.swift`、必要的 `Helpers/RenderedBlockSnapshot.swift`；`Resources/DownView.bundle/js/rendered-block-export.js` 与受控导出模板；`MiaoYanTests/RenderedBlockSnapshotTests.swift`、`MiaoYanTests/RenderedBlockExportTests.swift`。新 JS 的加载方式按 D0 确定，修改自有入口，不改 vendored minified 库。

**退出条件：** A-11–A-14 的数据/渲染/文件安全部分通过；PNG 可重新解码且尺寸和透明度正确，SVG 独立可用；零尺寸、超限、磁盘满、取消和权限失败不写坏文件或误报成功。

### D2 — 右键交互、兼容性与 Mermaid 独立交付

**关联需求：** D-01、D-05–D-08；**依赖：** D1。

将 D0 验证的目标识别接入 native menu，新增“导出此图表…”，显示 renderer 名称、默认文件名、格式、像素尺寸与可用性。loading/error 分别显示可理解状态；给生成的图表容器提供键盘聚焦/菜单与 VoiceOver 名称。普通图片、链接和正文的菜单不变，不出现重复面板。

在 `diagram-handler.js` 的生成路径登记块来源/身份/渲染状态，在预览增量更新和重新渲染时失效旧 revision；同一次 render 的 pending → ready 不另外使操作过期。原生 token 只源于真实右键/键盘菜单动作，不允许 raw HTML 伪造 `.language-mermaid` class 或 JS 消息直接生成文件。

实现保存失败/过期/取消的独立反馈，保持主预览选区、滚动、模式和当前笔记完全不变。覆盖普通预览与分栏，主题变化、缩放、连点两图和一次队列只执行一个请求。全量验证 SPEC 的 A-10–A-15，回归既有整篇 PNG/PDF 与 Mermaid 渲染。

**拟修改范围：** `Views/MPreviewView.swift`、`Views/MPreviewHandlers.swift`、`Resources/DownView.bundle/js/common.js`、`Resources/DownView.bundle/js/diagram-handler.js` 及实际脚本加载入口、四份 macOS `Localizable.strings`。`Extensions/MPreviewView+Export.swift` 仅在提取无副作用逻辑时最小变更，不能让单图表导出走整篇布局恢复链。

**D-Gate：** 实机右键指定图表，保存 PNG 后在系统 Preview 打开验证完整性；SVG 脱离原文独立打开。提供多图/同图重复、中文/HTML label、宽高超视口、暗亮主题、2× 像素尺寸及沙盒保存证据。PNG 核心样本未通过不得宣称“单图表导出已完成”。此里程碑可先合并/交付，不等待 WYSIWYG。

### D3 — PlantUML 与块级公式扩展

**关联需求：** D-02、D-04、D-05、D-08；**依赖：** D2；第二里程碑，不阻碍 Mermaid 首次交付。

复用同一导出协调器，仅增加 provider-specific 捕获/就绪适配。PlantUML 在生成 `.plantuml-image` 时登记其与源码块的关系；`processed` 在网络图片加载前就可能为 true，必须等 `onload`/有效尺寸或记录失败。`onload` 不能代替“已经取得导出资源”的状态：优先复用生成/加载阶段保留的 SVG 字节或静态像素产物，缺失时只在资源准备层重取已登记的原渲染 URL，遵守原网络策略，静态化之后导出宿主仍禁网。不增加新 PlantUML 服务器、不附加无关凭据、不把普通图片当图表。

KaTeX 导出整个 `.katex-display` 根，包括公式编号和必要 CSS/字体。为 `renderMathInElement` 的完成与失败提供明确的块状态，等待字体后捕获；不能把 idle callback 被调度当作公式就绪。首期公式只承诺 PNG，不能以内部某个 SVG 小部件代替整条公式。

**拟修改范围：** `diagram-handler.js`、当前 `index.html` 的 KaTeX 渲染入口或其提取后的自有模块、导出 adapter、对应测试和文案。表格/代码块不顺手扩入此 PR。

**退出条件：** A-16 和 D 线通用安全/尺寸测试通过；PlantUML 分别验证“已有可导出资源”和“仅显示成功但需受限获取原资源”两条路径，跨域/缓存/ATS 行为有实测，获取失败明确报错；公式无缺字/缺编号，普通图片和行内公式不误匹配。只有该阶段通过，文档才扩写为支持这两类。

### W0 — 原生所见即所得技术验证（高风险前置）

**关联需求：** W-02、W-05–W-08、W-11；**依赖：** B0；可与 D0/D1 并行。

在隔离分支/测试宿主中验证最小 AppKit 编辑面，不挂公开菜单、不改默认保存路径。使用现有 TextKit 1 基线，验证一段文字、一个 heading、一组强调、一项任务列表、一个图片 attachment 和一个受保护块；证明在隐藏标记的显示文字上直接编辑确实能生成最小原文 patch。

先写 source map/patch 的纯逻辑测试。明确 cmark 的行/列、UTF-8 和 UTF-16 转换；验证数学保护、frontmatter 剥离、Wikilink 转换、CRLF、制表符、Emoji ZWJ、转义和隐藏标记边界。直接核对 pinned cmark 的 Tab/end-column 语义；现有 HTML formatter 的 `.count`/`NSRange` 光标修正不能当作现成双向映射。对需要上下文的参考定义/嵌套结构不能把任意行片段当独立 Markdown 解析。

用真实中文/日文输入法测试 composition，不仅向 `textStorage` 程序化插入中文。验证边界光标、跨块选区、格式切换、基础段落直接编辑与语义 undo。固定 SPEC 输入/粘贴矩阵并测试三层列表分拆、合并、空项退级；不能只改一项 checkbox 就通过结构验证。每次接受事务后同步推进下一次输入所需局部映射，完整 parse 可异步；人为延迟和乱序返回下连续输入不能被旧映射拒绝，停止输入后投影必须收敛。后台 parse 回调必须可按 revision 过期；对 200 KB/2,000 行样本记录 SPEC 预算。

**拟新增范围：** 源码映射/patch 原型、对应 XCTest 和可丢弃的本地测试宿主；不接触图表线的预览右键文件。经过 G0 认可的实现才整理为后续正式模块，不把原型、DEBUG 日志或一次性样本直接发布。

**G0 通过门：** 基础正文点击后不回整段源码；只改目标区间；真实 IME 不吞字，延迟/乱序解析不漏字且最终收敛；输入规则/字面粘贴符合矩阵，三层列表分拆合并可撤销；同会话跨视图 undo 不串；无操作切换 hash 不变；11.5 基线无未保护新 API；性能预算有测量。

**G0 不通过：** 收集最小复现和测量，停止向现有主控制器堆补丁。在 spec 中说明哪项能力未达标，再决定缩小基础语法范围或另行讨论网页内核。不得自动将 WYSIWYG 定义降级为“源码高亮”，也不能宣布整个需求完成。

### W1 — 会话所有者与保存入口接入

**关联需求：** W-06–W-09；**依赖：** G0 通过。

建立 `MarkdownEditingSession`，让原文、owner、revision 和事务约束归到同一处。先以现有源码模式接入并通过回归，此阶段不展示新富文本视图。原文到 `Note.content` 的提交沿用现有 debounce/flush/版本历史，不新增第二个独立自动保存定时器。

逐一审计源码缓冲区发布、`textDidChange`、切笔记、refill、预览/分栏/演示入口、显式保存、窗口失焦、关窗和 app 退出。补齐 `MainWindowController.windowWillReturnUndoManager` 的活动编辑面路由，不能让新原生视图误用列表的 undo。所有整体源码赋值通过 `publishStorage(_:owner:)`；既有 `saveTextStorageContent(to:)` 不得接收富文本显示字符串，生命周期不能继续无条件从隐藏的旧源码视图读取内容。每次会话提交后同步源码缓冲 revision 或将其失效；同 owner 的旧缓冲回写也须被拒绝。进入既有 `Note.save(content:)` 链，而不是仅赋值 `Note.content`。

接入重命名、移动、外部 watcher、Trash 和版本恢复；将 watcher 的旧 `editArea.string` 备份改为会话权威 Markdown 快照。写失败保留 dirty；被删除 Note 不复活；source identity/generation 变更后异步结果和保存请求失效。有本地修改时遇到外部变化先保留双版本并阻止覆盖；按 SPEC 已明确的本期合同仅保留进程内草稿；正常换笔记/关窗/退出前，未解决冲突或写失败必须提供重试、另存 Markdown 副本、明确放弃或取消的可取消流程，不等到 `applicationWillTerminate` 才处理。强制退出/崩溃后的恢复不在本期承诺内；不偷偷引入未设计的恢复目录。

**拟新增/修改范围：** `Business/MarkdownEditingSession.swift`；`Views/EditTextView.swift`；`Controllers/ViewController.swift`、`Controllers/ViewController+Editor.swift`、`Controllers/ViewController+Action.swift`、`Views/NotesTableView.swift` 的编辑/选择采集入口；`Controllers/MainWindowController.swift`、`Controllers/AppDelegate.swift`；按实际调用链有限修改 `Business/Note.swift`、watcher 和版本恢复入口。继续使用 `AppEnvironment.current` 获取服务。

**测试范围：** 新增 `MarkdownEditingSessionTests`，扩展 `EditorStorageOwnershipTests`、`NoteSaveDebounceTests`；必要时新增 watcher/删除/恢复的最小测试替身，覆盖失败后换笔记/关窗/退出的保留与明确放弃路径。测试 A 编辑 → preview → B → 退出，以及关窗前 debounce 未执行、磁盘写失败、删除后旧回调到达。

**退出条件：** A-06、A-07 通过；旧源码/分栏用户行为不变；明确所有 active buffer 进入保存路径的唯一入口。没有这项证据，不进入 W2。

### W2 — 原生基础内容直接编辑

**关联需求：** W-02–W-07、W-11；**依赖：** W1。

把 W0 通过的原型收敛成独立 AppKit `RichMarkdownTextView` 与它实际需要的源码映射逻辑。视图只拥有派生显示内容，所有键入、选区替换、格式命令和附件删除转成 source transaction；图片异步更新、主题和 layout 不登记编辑/保存。

按依赖顺序完成段落/heading → 行内格式/链接 → 引文/列表/任务勾选 → 图片 attachment → 复杂块显式源码入口。输入规则与普通段落编辑共用命令语义，不能对代码/数学/frontmatter 生效。不可可靠处理的跨块选区先转源码，不靠整篇 AST 序列化“修复”。

同笔记内语义 undo/redo 由会话统一管理，保留切换前后源码选区；定义被隐藏标记两侧的光标 affinity、空块和 attachment 删除行为。点击正文不展开源码是必须的端到端验收，不以快照样式测试替代。

**拟新增/修改范围：** `Views/RichMarkdownTextView.swift`、`Helpers/MarkdownSourceMap.swift`，必要时从 W0 收敛单独的 lossless parser；`MiaoYanTests/MarkdownSourceMapTests.swift`、`MiaoYanTests/RichMarkdownEditingTests.swift`。仅在需要时共享 `Business/Markdown.swift` 的解析选项，不改变既有渲染输出语义。

**退出条件：** A-01–A-05 的基础语法通过；样本 round-trip/未修改片段测试通过；超限/不支持语法能无损回源码。使用真实 AppKit 编辑操作补足纯逻辑测试，不能只测预先拼好的 Markdown。

### W3 — 模式、菜单、命令与附件整合

**关联需求：** W-01、W-04、W-06、W-08、W-10；**依赖：** W2；触及图表线文件前先合并 D2。

在既有编辑设置和菜单加入口；新编辑布局状态只能有一个 owner，旧模式开关为兼容访问。实现 SPEC 的 `⌘3`、`⌘\`、Presentation/PPT 返回策略，保持 `⌘0`–`⌘5` 现有用途。新用户默认值及旧偏好迁移有测试，无笔记、Trash 和只读上下文不能提供不可用的编辑动作。

建立“命令 → 当前编辑会话”的最小适配，不全面重写 First Responder。查找/替换、TOC、Wikilink、格式化、快捷模板等会改内容或使用位置的调用点必须显式选支持或转源码；保留 storyboard selectors/outlets。默认复制给外部应用的是可见文本；提供显式“复制 Markdown”/“粘贴 Markdown”，外部普通粘贴不猜测语法，应用内保真粘贴使用单独的 Markdown pasteboard 类型，不能把隐藏语法悄悄混入普通文字剪贴板。

粘贴/拖入图片复用 `ClipboardManager` 与现有 `i/` 写入逻辑，但传入捕获的会话 owner/revision，而不是上传返回时重新取 selection。文件写成功后才插入引用；失败不插空链接；在途切换笔记时不写错笔记，孤立的自建附件沿用可恢复的清理路径处理。链接编辑校验 scheme，不允许点击执行 `javascript:` 等内容。

Prettier 保持显式命令，不增加 format-on-save；从会话取得原文，携带 revision，结果一次性提交到同笔记并补齐内容级 undo/redo；在途切笔记/继续输入后不能覆盖新内容。若某命令尚不能完成坐标映射，用“提交 → 转源码并定位 → 执行”的既定路径，不静默禁用。

**拟修改范围：** `Controllers/ViewController+Editor.swift`、模式/编辑相关 extensions、`Controllers/EditorPrefsViewController.swift`、`Helpers/UserDefaultsManagement.swift`、`Business/Types.swift`、`Helpers/EditorMenuManager.swift`、`Helpers/TextFormatter.swift`、`Helpers/ClipboardManager.swift`、`Resources/Localization/Base.lproj/Main.storyboard` 以及相应的四种非英文资源。以上为候选改动面，不要求无差别修改每个文件。

**退出条件：** A-08、A-09 以及 A-06 的模式组合通过，附件失败/迟到回调不污染正文；所有现有内容命令有明确路由，没有“模式显示正常但命令改到旧 textStorage”的残留。

### W4 — 兼容性、可恢复性和付费版体验验收

**关联需求：** 全部 W 需求，D 线集成回归；**依赖：** W3。

执行 A-01–A-15；D3 已交付时追加 A-16，未交付时不能声称 PlantUML/公式完成；记录机型、系统、构建配置与 p95。检查大图异步加载、暗亮主题、字体/缩放、键盘焦点、VoiceOver、长标题、列表对齐与空态；不借此更换整个侧栏材质或图标体系。触及 renderer 时一起回归 Mermaid、图片、PDF 分页、等待就绪和 `max-width: 100%`。

更新中英文 README 的产品定位、真实功能边界和快捷方式说明；检查 `skills/miaoyan/` 对编辑模式/导出的产品说明是否需要同步。若修改项目 agent skills，只改 `.agents/skills/` canonical source 并执行同步检查。发布说明只在功能通过后更新，且不能把“已有本地 build”写成已发布。

**退出条件：** 需求到测试的覆盖无空项；macOS Debug build、单测、SwiftLint strict、swift-format strict 全部通过，必要 iOS 回归通过；实机流程有证据；没有未处置的 owner/保存、IME 或 undo 阻断项。正式发布另走各自渠道流程，本计划不授权打 tag、上传或送审。

## 3. 并行协作与文件所有权

| 工作流 | 可并行责任 | 明确避让 |
| --- | --- | --- |
| 图表 worker | D0 命中/PNG 验证、D1 静态快照/导出、D2 菜单；之后 D3 provider 扩展 | 不改编辑会话、格式命令和编辑模式状态 |
| 编辑 worker | W0 映射/IME/undo 验证，随后 W1–W3 分阶段 | 不在 D2 尚未合并时改右键 JS、`diagram-handler.js` 或 `MPreviewView` |
| 集成人/主代理 | 工程注册、共享文件、生命周期集成和 PR 边界 | 不同时让两位 worker 重写同一 `project.pbxproj` |
| 验证 reviewer | 在开发进行时补边界用例/审查风险；阶段结束核验结果 | 不根据作者总结或绿色编译替代实机操作证据 |

每个 worker 只修改分配的文件，不回退其他人的未提交工作。新 Swift 源码/测试文件注册 Xcode 的 `PBXBuildFile`、`PBXFileReference`、group children、对应 target Sources 四处；fixture 如作为 bundle resource，额外核对正确资源阶段。iOS 不应编译新 AppKit 类。

## 4. 测试和验收实施方式

| 测试层 | 必测内容 | 证据形式 |
| --- | --- | --- |
| 纯逻辑 XCTest | 源码 map/patch、会话原子性；图表身份/revision、尺寸/倍数预检、命名与取消/保存状态机 | 固定样本与断言，不能只检查 PNG 文件存在 |
| 会话/存储集成 | 所有者、debounce、关窗、外部变更、删除、恢复、失败保持 dirty | 临时目录/可控时钟证明最终原文和磁盘状态 |
| WKWebView 渲染集成 | Mermaid 成功/失败/同内容双图/多图、ready 与字体、defs/HTML label、独立 PNG/SVG | 可控宿主与实际图形结果、像素尺寸、目标包含/排除断言 |
| 故障与恶意输入 | 伪造 renderer 容器/token、旧 revision、超限/非有限尺寸、活跃 SVG、资源超时/失败、取消、磁盘错误 | 本地 fixture/测试替身，不用用户真实图表与私人路径 |
| 实机 smoke | 图表任意子节点右键、超视口完整导出、Finder/Preview 打开、主题/缩放、IME/undo/模式往返 | 录像/截图 + PNG 像素和边界验证 + 笔记前后 hash |
| Sandbox smoke | 保存到不同目录、取消/覆盖、授权失效及导出宿主最小资源访问 | 正确签名的 App Store 配置测试 app；unsigned build 不能证明权限行为 |
| 兼容回归 | macOS 11.5 API/可用测试机、新系统、iOS 读取同一 Markdown、既有整篇导出 | 记录实际覆盖；缺设备时明确“未验证”，不声称全兼容 |

首版不强制新增 XCUITest，沿用 XCTest 纯逻辑与可控宿主，加真实 UI smoke。只插入中文不等于真实 IME 测试，只显示面板不等于保存成功，只得到 PNG 不等于内容未裁切。现有 `MermaidExportTests` 标注 macOS 12.0+，其通过不能作为 11.5 兼容证据。

### 4.1 验证命令

在仓库根运行，先窄后宽。以下是实施阶段需要执行的命令，**本次文档规划没有运行 app build 或测试**。

```bash
# 开发前确认目标与未提交变更；不要重置不属于自己的改动
git rev-parse --show-toplevel
git branch --show-current
git rev-parse HEAD
git status --short

# 示例：本地验证新增会话测试；测试类加入后再运行
xcodebuild test -project MiaoYan.xcodeproj -scheme MiaoYan \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MiaoYanTests/MarkdownEditingSessionTests

# macOS 全量验证
xcodebuild -project MiaoYan.xcodeproj -scheme MiaoYan \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project MiaoYan.xcodeproj -scheme MiaoYan \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
swiftlint lint --strict
swift-format lint --recursive . --strict

# 共享 Markdown、资源或 target membership 变更时回归 iOS
xcodebuild -project MiaoYan.xcodeproj -scheme MiaoYanMobile \
  -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build

# 改 public release notes 后运行对应 renderer smoke
bash scripts/release-ci/notes_to_html.sh .github/RELEASE_NOTES.md > /tmp/miaoyan-notes.html
bash scripts/release-ci/render_release_body.sh .github/RELEASE_NOTES.md > /tmp/miaoyan-release-body.html
```

本机测试禁用签名是既有测试 Team ID 问题的标准处理，不代表 App Store 沙盒验证完成。App Store 打包脚本含清理、archive 和 export，不能为验证此文档而顺手执行；准备渠道产物时使用项目现有 appstore/release skill。

### 4.2 需求追踪

| 实施阶段 | 对应验收 |
| --- | --- |
| D0 | A-10–A-12 的完整单块/保真/尺寸前置，A-14 的目标身份 |
| D1 | A-11–A-14 的静态产物、隔离渲染、文件和取消语义 |
| D2 / D-Gate | A-10–A-15 的完整 Mermaid 交付 |
| D3 | A-16 及 A-12–A-15 中适用的尺寸/就绪/安全/兼容 |
| W0 / G0 | A-01–A-05 的最小用例，A-09 的性能/兼容性前置 |
| W1 | A-06、A-07，A-05 的会话隔离 |
| W2 | A-01–A-05、A-09 的源码回退 |
| W3 | A-06、A-08、A-09、A-15 的模式/命令/文案 |
| W4 | W 线全量集成与已交付 D 能力回归；A-16 只在 D3 完成后宣称通过 |

## 5. PR、风险与回退

D0 做可丢弃的窄验证；D1 静态导出管线与 D2 菜单/质量分别审查，D-Gate 后合并为可独立交付的 Mermaid 功能；D3 再扩图型。W0 是验证 PR，W1/W2/W3/W4 按阶段推进。每个 PR 包含变更、影响、测试方法和未验证边界，不能在 PR 标题里用普通图片另存替代渲染图表导出。

| 风险 | 预防/发现阶段 | 未通过时处理 |
| --- | --- | --- |
| 只保存一个节点/当前可见区域，或相同内容图使用重复 ID 导错目标 | D0/D2 多图/重复图/超视口样本 | 按容器与 render revision 绑定完整块，阻断不完整 PNG 发布 |
| `foreignObject`、中文、主题/字体/defs 丢失 | D0/D1 独立 SVG/PNG 样本 | 优先受控渲染宿主；PNG 保真不通过则阻断，不能只有 SVG 冒充完成 |
| 导出宿主离屏空白、尺寸超限、隐藏窗口抢焦点 | D0/D1 实机 snapshot 与画布预检 | 在公开 API 范围解决，降低用户显式选择倍数或提示 SVG，不截断/闪窗 |
| processed 被误判 ready 或旧回调覆盖新图 | D0/D2 provider 状态及 revision 测试 | 校验真正成功/资源/字体，旧目标取消，失败不出文件 |
| raw HTML 伪造图表或导出宿主执行活跃内容 | D1/D2 token/registry/静态资源隔离 | 拒绝并报告；不继承主预览 `/` 文件访问，不扩大 ATS |
| 所见即所得只是隐藏标记、普通编辑重排原文 | W0/W2 直接输入与无损测试 | 不降低定义；复杂结构回源码，基础结构失真则阻断新模式 |
| 同 owner 旧缓冲、生命周期、IME/undo、格式化迟到结果覆盖内容 | W0/W1/W2/W3 定向测试 | 补最小复现/DEBUG 证据，拒绝旧 revision，保留草稿，阻断发布 |
| iCloud/外部编辑被覆盖或被删笔记复活 | W1 冲突/删除/回调测试 | 保留恢复内容，拒绝自动覆盖，阻断发布 |
| 11.5/Sandbox/本地化缺少证据 | D-Gate/W4 | 明确缺口，不声称全渠道完成 |

图表功能用独立入口/提交边界回退，关闭后保持原整篇 PNG/PDF 导出和 Mermaid 渲染；不删除已导出的用户文件。关闭 WYSIWYG 前安全提交或保留恢复草稿，磁盘始终是兼容 Markdown。两条线均不靠清空笔记/附件或整库快照实现回滚。

## 6. 工作量判断与本轮完成定义

单渲染块导出是中等至偏大的扩展，真实难点在完整边界、SVG/HTML label/字体、离屏渲染与目标代次，不是加一个“保存”按钮。D0 验证后先估 Mermaid 工期，D3 单独估算。WYSIWYG 是大规模编辑链能力，W0 后再估，不能让它拖住用户最重要的图表功能，也不在未验证技术方案上承诺日期。

本轮只交付两份规划文档。完成标准：核心 Mermaid 优先级准确，普通图片保存已排除，范围与格式明确，阶段依赖和文件责任不冲突，每个需求有验收，路径/命令可核对，风险有停止或回退机制。功能是否实现，必须以后续代码、测试与实机证据判定；本计划不授权打 tag、上传或送审。
