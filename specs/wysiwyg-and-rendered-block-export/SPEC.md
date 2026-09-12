# MiaoYan 所见即所得编辑与渲染块单独导出 — Spec

状态：方案草案，未实施。本文中的“必须”是建议采用的验收合同，不表示对应能力已经存在。实施任务见 [PLAN.md](PLAN.md)。

核验基线：仓库 `/Users/hubo/Projects/Mdown`，分支 `main`，HEAD `668e367e4937bd5c887562991400636ced1d3e58`；开始规划时工作区干净。开发前必须重新检查基线和工作区。

## 1. 产品决策与边界

**用户已明确的优先级：最重要的是 Mermaid 等渲染内容的单张保存，普通图片下载/另存不是需求。** 本次新增两个可独立交付的能力：优先在预览中对一张由 Markdown 生成的图表右键，保存这张完整渲染结果；另行增加在排版后的内容上直接编辑 Markdown 的可选模式。图表导出不是整篇笔记截图，不夹带上下文，也不是保存本来就存在的 JPG/PNG 文件。

建议首期限定 **macOS**，同时覆盖直接下载版和 Mac App Store 版。iOS 继续正常读取相同 `.md` 和附件，不在本次增加移动端富文本编辑或长按图表导出。保留源码、分栏、纯预览和演示体验，不改变默认编辑方式，不要求用户迁移笔记。

[README_CN.md](../../README_CN.md) 和 [README.md](../../README.md) 目前明确解释“不做 Typora 式即时预览”。本次用户需求是新的产品方向，实施完成后更新该表述；不能在功能尚未通过验收时提前宣称支持完整 Typora 能力。

### 1.1 “所见即所得”的确切含义

普通段落、标题、粗体、斜体、删除线、行内代码和基础列表，在隐藏 Markdown 标记后的排版内容上直接输入、删除和选区操作；不要求用户每次点击文字都退回整段源码。这是首版必须达到的能力，仅给源码换字体、隐藏符号或增加一个预览窗不算完成。

首版采用**基础内容直接编辑，复杂内容显式编辑源码**的混合边界。表格、公式、Mermaid 等显示为保留原文的受保护块，提供“编辑此块源码”和“在源码中定位”；不承诺首版所有复杂语法都能像 Word 一样直接操作。边界应出现在设置帮助及公开说明中。

### 1.2 非目标

本次不重写整个编辑器，不引入 SwiftUI 编辑核心，不使用任意网页的 `contenteditable` 作为笔记编辑器，不做 HTML → Markdown 整篇反向转换，不改变 Markdown 方言，不改动文件格式、iCloud 存储协议或既有附件目录。本次也不包含协同编辑、完整富文本排版、普通图片下载/另存、图片裁剪/压缩编辑、批量图表导出、整篇长图以及 Liquid Glass 全套重设计。

## 2. 当前实现约束

| 现有事实 | 对本次设计的约束 |
| --- | --- |
| [ARCHITECTURE.md](../../ARCHITECTURE.md) 定义 AppKit 主编辑器、WKWebView 预览和独立 iOS target | 原生编辑核心与网页预览保持分工；新增文件不能误入移动端编译目标 |
| [Views/EditTextView.swift](../../Views/EditTextView.swift) 使用 `storageNote` 标识文本缓冲区归属 | 选中笔记不等于缓冲区所有者；不得把富文本显示字符串传给既有整篇保存接口 |
| [Controllers/AppDelegate.swift](../../Controllers/AppDelegate.swift) 与 [Controllers/MainWindowController.swift](../../Controllers/MainWindowController.swift) 在退出/关窗时刷新内容；窗口还按 first responder 是否为 `EditTextView` 分配 UndoManager | 新编辑模式必须接入生命周期和撤销路由，不能假定新 `NSTextView` 会自动得到笔记撤销栈 |
| [Helpers/FileSystemEventManager.swift](../../Helpers/FileSystemEventManager.swift) 的外部修改处理会备份 `editArea.string`、重载并清除 undo | 富文本接入后必须备份权威 Markdown，而不是投影或旧源码缓冲；现有流程不等于三方合并 |
| [Controllers/ViewController+Editor.swift](../../Controllers/ViewController+Editor.swift) 中 Prettier 由显式 `formatText()` 调用，本轮未找到 format-on-save 设置 | 不引入隐式保存格式化；新模式需补足格式化事务 undo 和同笔记 revision 校验 |
| [Business/Markdown.swift](../../Business/Markdown.swift) 的 `renderMarkdownHTML` 是渲染入口，并先运行 `protectMarkdownMath` | HTML 的 sourcepos 不能直接当作原始 Markdown 的列偏移；编辑定位必须针对原文建立映射 |
| [MiaoYan.xcodeproj/project.pbxproj](../../MiaoYan.xcodeproj/project.pbxproj) 的 macOS deployment target 为 11.5 | 首版以现有 TextKit 1 能力为基线；不为本功能擅自升级系统最低版本 |
| [MiaoYan-AppStore.entitlements](../../MiaoYan-AppStore.entitlements) 已有用户选择文件读写和网络客户端权限 | 保存走原生系统面板，不扩展成任意文件访问，不放宽 ATS |
| [Views/MPreviewView.swift](../../Views/MPreviewView.swift) 的 `willOpenMenu` 只过滤部分系统项，contextmenu 桥目前只处理选中文本 | 没有已确认的自定义单个渲染块导出；图表命中和 JS/菜单时序需先做 D0 验证 |
| [Extensions/MPreviewView+Export.swift](../../Extensions/MPreviewView+Export.swift) 的 `exportImage()` 导出整篇 PNG；Mermaid 渲染为内联 SVG | 必须新增单 Mermaid 导出；不能调用整篇截图，也不能把普通图片保存当作替代交付 |
| [Resources/DownView.bundle/js/diagram-handler.js](../../Resources/DownView.bundle/js/diagram-handler.js) 将 Mermaid 写为内联 SVG，PlantUML 写为远程 SVG `<img>` | 按渲染来源识别图表，而非只认 `<img>`/`src`；PlantUML 的内部 `<img>` 不等于用户的普通图片 |
| [vendor/MANIFEST.json](../../Resources/DownView.bundle/js/vendor/MANIFEST.json) 的 Mermaid/KaTeX 版本为 `unknown`，提供文件 hash | 先记录实际 vendored 产物，不照搬在线最新版 API，不为导出顺手升级渲染器 |
| [.gitignore](../../.gitignore) 忽略 `docs/` | 本方案放在可跟踪的 `specs/wysiwyg-and-rendered-block-export/`，避免文档只留在本机 |

## 3. 功能需求

### 3.1 所见即所得编辑

| ID | 首版需求与可观察行为 |
| --- | --- |
| W-01 | 在现有“编辑模式”设置中增加“所见即所得”，并提供菜单入口。原有用户设置保持不变；新用户仍使用既有默认值 |
| W-02 | 普通文字及支持的行内格式可直接编辑，工具命令作用于当前选区。输入 Markdown 常见起始语法可转换为对应样式；代码/受保护块内不触发这些输入规则 |
| W-03 | 标题、基础无序/有序/任务列表支持创建、编辑、换行、退格及缩进；任务勾选只修改对应 `[ ]` / `[x]`，不改写其他列表项 |
| W-04 | 已有图片以图片或明确占位符显示，宽度不超出编辑区；链接可查看和修改目标，点击编辑与主动打开链接分开。粘贴/拖入图片沿用笔记旁的 `i/` 附件约定 |
| W-05 | 复杂或不能可靠映射的语法保留原文，提供局部源码入口。跨受保护块的危险编辑必须先转到对应源码选区，不得丢弃或猜测序列化 |
| W-06 | 源码与所见即所得互切恢复同一笔记的选区和相近滚动位置。只切换不编辑时文件不变；已编辑时，未触及的原文片段保持不变 |
| W-07 | 中文/日文 IME、Emoji、组合字符、撤销/重做、连续输入和跨块选择均有确定行为；切换模式本身不产生编辑记录 |
| W-08 | 自动保存、显式保存、失焦、切换笔记、关窗、退出和版本恢复读取同一份权威 Markdown，不能用显示投影覆盖原文 |
| W-09 | 处理外部修改、文件移动/删除、Trash 和过期异步回调。发生冲突保留本地草稿和磁盘内容，由用户决定；不得把已删除笔记写回 |
| W-10 | 查找/替换、格式化、TOC、Wikilink、菜单和快捷操作要么支持当前模式，要么明确、安全地切到源码完成；不能把富文本的显示坐标当成源码坐标 |
| W-11 | 超出首版性能边界或解析失败时可无损回到源码模式；降级只作用于当前笔记，不暗中重置用户全局偏好 |

### 3.2 语法能力分层

| 语法/操作 | 首版直接编辑 | 保真与回退规则 |
| --- | --- | --- |
| 段落、H1–H6、粗体/斜体/删除线、行内代码 | 是 | 保留未编辑处原有定界符、空格、转义和换行；选区格式命令形成一次事务 |
| 普通引文、无序/有序/任务列表 | 是，首版交互验收覆盖至少三层嵌套 | 更复杂或存在歧义的结构转局部源码，不依靠整篇格式化修复 |
| 普通链接、图片 | 是，目标/alt/title 通过轻量面板编辑 | 参考式链接保留引用定义；修改共享定义前提示影响范围，首版可转源码 |
| 围栏代码块 | 代码内容可局部编辑；语言/围栏通过源码入口 | 不把代码当富文本解释；反引号冲突、嵌套围栏由原文编辑器处理 |
| GFM 表格 | 不做单元格富文本编辑 | 有可识别的块及源码入口；完整排版缩略图取决于技术验证，不能删掉表格原文 |
| LaTeX、Mermaid、PlantUML | 不直接拖拽编辑公式或图形 | 可复用既有渲染产物展示；未就绪时显示有名称的占位/源码卡，不阻塞打字 |
| Frontmatter | 不作为正文显示 | 提供源码定位，字节/换行保留；不因模式切换自动剥除文件中的 metadata |
| Wikilink、脚注、GitHub Alerts、raw HTML、未知扩展 | 不承诺完整富文本编辑 | 作为保留原文的结构处理；嵌入网页不得获得原生写文件权限 |

### 3.2.1 输入规则与粘贴语义

以下属于 W0/G0 的确定性操作样本，不由实现者自行猜测用户意图。源码模式沿用现有输入/粘贴行为；下表限定所见即所得模式。

| 操作 | 可见结果 | 原文/撤销合同 |
| --- | --- | --- |
| 段落起始键入 `# `、`- `、`1. `、`> ` | 在空格完成合法起始序列时转换为标题/列表/引文 | 形成一个可单独撤销的结构转换，撤销恢复用户输入的字面前缀，不丢字 |
| 键入成对合法 `*文字*` / `**文字**` | 闭合并形成有效结构后转为对应行内样式；未闭合前保留可见输入 | 转义的 `\*` 保持字面文本；代码/数学/受保护块内完全不触发 |
| 从外部粘贴普通文本 `*文字*` / `# 标题` | 默认作为字面文本，不靠文本外形自动导入 Markdown 结构 | 按上下文转义必要字符；提供显式“粘贴 Markdown”以插入语法；应用内专用 Markdown pasteboard 可保留原结构 |
| 普通段落 Enter / Shift+Enter | 新段落 / 同段明确换行 | 对应段落分隔 / 明确 Markdown hard break；操作只改相关块，格式化后仍保留同样换行语义 |
| 非空列表 Enter | 分拆为相邻列表项，光标在新项正文 | 保留列表类别和局部缩进风格，分拆为一次可撤销事务 |
| 空列表项 Enter / Shift+Tab | 退一级；最外层退出列表 / 退一级 | 至少三层嵌套的结构正确；不会把整段列表重排成新风格 |
| 块首 Backspace、跨列表项删除 | 合并可合并的相邻内容 | 不可可靠合并或跨受保护块时先转局部源码，不吞掉结构或内容 |

格式命令、输入规则、普通粘贴、显式 Markdown 粘贴都必须注明 transaction origin；不能对粘贴进来的代码样例启动与逐键输入相同的自动转换规则。

### 3.3 模式与操作路由

编辑布局用一个新的、单一所有者的状态表达：`source`、`split`、`wysiwyg` 三选一。预览、Presentation、Magic PPT 是临时阅读/演示状态，保存进入前的编辑布局用于返回。现有布尔状态通过兼容适配读取，不能同时增加几组可独立写入的真假开关。

| 用户动作 | 行为 |
| --- | --- |
| 设置或菜单选择所见即所得 | 提交当前输入组合，捕获权威原文和选区，完成映射后切换；失败留在原模式且不丢草稿 |
| `⌘3` 进入/退出预览 | 进入前安全提交，退出回到本次进入前的编辑布局，而非固定回源码 |
| `⌘\` 切换分栏 | 从所见即所得进入“源码 + 预览”，记住此前单栏布局；再次关闭分栏返回此前布局 |
| 进入演示或 PPT | 使用已提交的权威 Markdown；退出恢复原编辑布局 |
| 不支持的格式化/结构命令 | 先安全切源码并定位到原选区，再执行同一个命令；不支持定位则中止并解释 |
| 首次迁移偏好 | 新设置键不存在时按旧分栏偏好迁移；不改变已存在的预览/演示恢复规则 |
| 标题重命名、换笔记、关窗时仍在输入法组词 | 请求输入系统完成当前组合后再切换；无法完成则保留当前编辑和上下文，不自行取消或截断组词 |

不分配新的 `⌘0`–`⌘5` 快捷键。视觉沿用当前不透明侧栏和工具栏，只增加必要选中态、焦点态和帮助说明。

### 3.4 渲染块单独导出（最高优先级）

| ID | 需求与可观察行为 |
| --- | --- |
| D-01 | 普通预览和分栏预览里，在 Mermaid 图表的节点、线、文字或图表内空白处右键，出现“导出此图表…”；命中的是这一个完整图表，不是被点中的节点 |
| D-02 | 默认输出高清 PNG；Mermaid 同期提供可正确独立打开的 SVG 选项。PNG 是首发硬性能力，不能只交付 SVG 或整页截图；不把位图套进 SVG 容器冒充矢量 |
| D-03 | 导出完整布局边界及必要留白，包含长标签、箭头、边线和阴影；不受当前可见视口、滚动位置、预览缩放和分栏宽度的裁切影响 |
| D-04 | 输出保持捕获时的图表排版、文字、字体大小和主题；SVG 需携带必要样式/defs/引用，PNG 不缺中文字和 HTML 标签；不依赖原笔记页面的外部 CSS 才能正常显示 |
| D-05 | 等待命中块渲染、字体和图内资源真正就绪；错误块、加载中或零尺寸结果不能保存成空白/错误提示图片。等待有状态、超时和取消 |
| D-06 | 通过 `NSSavePanel` 选择位置和文件名，覆盖由系统确认；写入完成才提示成功；取消/失败不改笔记、附件、编辑模式、滚动或 dirty 状态 |
| D-07 | 目标绑定 displayedNote、预览文档代次、块身份和块渲染 revision；一页多图、刷新、切笔记和晚到回调不能导错图；导出操作没有笔记保存副作用 |
| D-08 | 原生右键授权与消息桥校验、静态资源隔离、尺寸/内存限制、旧系统和 Sandbox 都有验收；通过同一导出合同后续支持 PlantUML、块级公式，而不引入通用网页下载器 |

### 3.5 范围、格式和交互默认值

| 渲染内容 | 优先级 | PNG | SVG | 边界 |
| --- | --- | --- | --- | --- |
| Mermaid 内联 SVG | **P0，首要独立交付** | 必须，默认 2× | 首期支持通过独立打开验收的输出；不兼容时明确提示使用 PNG | 覆盖当前内置引擎已能渲染的主要图型；不是下载 `<img src>` |
| PlantUML 渲染图 | P1，复用导出管线的后续扩展 | 必须（P1 验收） | 原渲染产物是可取得的 SVG 时支持 | 依据 renderer 登记的块来源，不对普通 `<img>` 开放；不向新服务器发送源码 |
| LaTeX 块级公式 / KaTeX display block | P1，后续扩展 | 必须（P1 验收） | 不承诺 | 按一个完整 display block 导出，包含公式编号；不能假定 KaTeX 全部是 SVG |
| GFM 表格、语法高亮代码块、其他图表 | P2 候选，不阻塞上述交付 | 后续另定 | 不承诺 | 只有新增对应 renderer adapter 和验收后才开放 |
| 普通 Markdown 图片、本地/远程 PNG/JPEG/GIF、任意 SVG 图片 | **明确不做** | 不新增菜单 | 不新增菜单 | 原有系统菜单保持原样；不能用普通图片另存代替图表导出 |
| 任意 raw HTML、iframe、整个页面、行内公式 | 不纳入首期 | 不支持 | 不支持 | 不将此能力扩张成任意 DOM 截图/文件读取接口 |

首期优先级已经由用户确认；macOS 范围、PNG/SVG 细节以及 P1/P2 划分是本文建议。所见即所得不作为 Mermaid 导出的依赖，不能让核心图表需求等待编辑器重构。

右键主入口“导出此图表…”先进行只读就绪/布局预检，再打开原生保存面板；已就绪图表不增加额外确认页，尚在渲染时显示可取消的准备状态。面板默认 PNG、2×、跟随预览背景；SVG 选项在该块通过能力检查时可选。面板提供 1×/2×/3× 的 PNG 尺寸选择和明确像素尺寸，SVG 不显示无意义的倍数。目标、真实逻辑尺寸和格式能力在弹面板前绑定；未确认尺寸/能力不能提交保存。用户确认后重新校验预检身份/布局，匹配才冻结快照并编码写出，发生变化则取消并提示重新导出，不写与用户确认尺寸不符的文件。各等待阶段可取消，不能先默认写 Downloads 再询问。普通 `<img>` 不增加本功能入口。

文件名建议为“笔记名-mermaid-图序号.png”；后续图型替换类型名，图序号固定取捕获时在该笔记中的序号。清理路径分隔符和控制字符，扩展名由格式决定；不把整个图表源码或 URL token 放进名字。

默认输出保持捕获时的主题并包含对应背景，使暗色文字/线条与背景关系稳定；PNG 可选透明背景，保留前景色并提醒暗色主题透明输出的适用背景。首期不增加“只把底色强制变白”的伪换主题选项。导出倍数基于完整图表逻辑尺寸，不乘入当前屏幕 Retina 因子两次。

## 4. 技术设计与数据合同

### 4.1 方案比较与选择

| 方案 | 收益 | 代价/约束 | 结论 |
| --- | --- | --- | --- |
| 原生 AppKit 富文本投影 + Markdown 原文区间编辑 | 保持 AppKit、输入法和原生菜单；可按原文最小改动保存 | 必须解决源码映射、结构编辑、撤销和生命周期；不能承诺零成本兼容所有语法 | 推荐，通过技术验证后实施 |
| WKWebView + 结构化网页编辑器 | 编辑器生态成熟，复杂块交互可能更快 | 修改原生编辑核心路线；引入 JS 依赖、双向桥接和方言/序列化保真风险 | 本轮不采用；原生验证失败需单独修改 spec，不能偷偷替换 |
| 只做活动块源码 / 非活动块预览 | 最容易维持原文保真 | 用户点击正文仍会回源码，不能满足 W-02 的基础内容直接编辑 | 可用于复杂块，不冒充本功能已完成 |

采用现有 `NSTextStorage` / `NSLayoutManager` / `NSTextView` 的能力，不强制 TextKit 2。可以为新模式新增自包含的 AppKit view，但不把 `EditTextView`、`MPreviewView` 或主控制器迁到 SwiftUI。

### 4.2 唯一权威文本与事务

建议新增一个**单窗口、单笔记的 `MarkdownEditingSession`**，只在当前编辑上下文中持有原始 Markdown、所有者、修订号和源码选区；它不是全局笔记数据库，也不替换 `Storage`。源码文本视图和所见即所得视图都是该会话的编辑入口，后者的 attributed string/attachments 是可丢弃重建的显示投影。

会话活跃时，已提交 Markdown 是当前内存编辑的唯一权威；`Note.content` 是沿用现有模型的提交快照，磁盘文件是持久化结果。禁止源码视图、富文本视图、`Note.content` 三方互相定时覆盖。接入是局部提取受影响的提交入口，不趁机重写全项目存储服务。

建议的最小合同如下，类型名可在实施时调整，但语义不可省略：

```text
SessionIdentity = note instance identity + canonical file URL + generation
EditTransaction = identity + expectedRevision + ordered source patches
                  + expected old text per patch
                  + selectionBefore/After + undoGroup + origin
ApplyResult = accepted(newRevision, canonicalMarkdown) | rejected(reason)
```

patch 的范围使用已明确约定的原始 Markdown UTF-16 区间；原文 UTF-8、原文 UTF-16、投影 UTF-16 是三套不同坐标，parser 行/列也不能直接当作 Cocoa `NSRange`。固定 cmark 版本对 Tab/end-column 的精确语义需在 W0 用样本验证，不能靠推断写死。每次操作检查 revision、范围边界、已删除/退役状态和文件归属；旧 revision 结果不得套用到新笔记。同一操作的多个 patch 以不可变快照验证后原子应用，失败则全部不应用。

```text
原生输入/格式命令 → 当前会话的源码事务 → 新 revision
                                   ├→ 当前视图投影 + 源码选区
                                   ├→ Note.content 提交快照 → 既有 debounce / flush / 版本历史
                                   └→ 既有 renderMarkdownHTML → WKWebView 预览/导出
```

每次提交后，隐藏的源码缓冲区必须同步到同 revision 或明确标记失效；即使 owner 相同，旧 revision 也不能经整缓冲采集覆盖新会话。调用 `Note.save(content:)` 或等价的既有安全保存入口才能进入 debounce，单独赋值 `Note.content` 不表示已安排自动保存。

所有整体源码缓冲区赋值仍通过 `publishStorage(_:owner:)`。所有现有 `saveTextStorageContent(to:)` 调用点必须审计：它只能保存由源码视图真正持有的原文，不能读取富文本投影的 `.string`。切换/关窗/退出先通过统一会话提交入口同步已完成输入，再进入既有保存链。

### 4.3 无损解析与显示映射

使用现有 cmark-gfm AST 判断语义，另对**未经渲染预处理的原文**保留 token/range 和原始片段。不从 HTML 或 NSAttributedString 重新生成整篇 Markdown；frontmatter 剥离、Wikilink 转换和数学占位替换均会改变坐标，不能复用其输出偏移作为原文偏移。若不得不预处理解析输入，转换过程必须同时产生可逆偏移映射并通过测试。

源码到显示的映射需要定义被隐藏定界符的光标 affinity、图片 attachment 的完整源码跨度、空段落位置、跨块选择、CRLF、制表符、Emoji 和组合字符。复杂范围不能可靠映射时切换源码定位，而不是尝试“最佳猜测”后保存。

只切换模式不触发保存或格式化；无操作文件 hash 相等，普通局部编辑后的未修改区间逐字相等。当前 Prettier 是显式 Format 命令，不是保存自动格式化。显式 Prettier / Clean Typography 是独立、可撤销的格式化操作，其明确作用范围内的重排不属于“未编辑区间不变”的承诺；不能因为进入新模式或自动保存就额外调用格式化。Prettier 的内容级 undo 和同笔记新输入后的过期回调保护是本次需补齐的合同，不宣称已有。

### 4.4 输入、撤销和异步保护

AppKit UI 和会话事务只在主线程应用；后台解析/图片读取使用不可变快照并携带 identity/revision。解析结果返回时若 owner、revision 或 generation 不匹配，丢弃结果且不落盘。

接受每个字符事务后，同步推进足以处理下一次键入的局部映射/选区；完整解析和样式刷新可以异步，不能让后续输入等待 AST，也不能因完整映射仍是旧 revision 就拒绝用户连续输入。后台只保留最新待解析快照并合并重复工作，停止输入后必须最终收敛到最新原文。结构无法安全局部更新时在同一块提供可编辑源码回退，不丢弃已接受文本。W0 注入延迟/乱序解析回调，验证连续输入不漏字、不重复、不停更。

`hasMarkedText()` 为 true 时，不因解析、高亮或渲染重建正在组合的文本/属性；允许输入系统维护自己的组合区。后台可准备候选投影，但只能在组合完成后、revision 仍匹配时应用。模式/笔记切换不能用“取消输入法”代替提交。

同一笔记、同一会话跨源码/所见即所得切换使用同一份语义撤销历史；视图重排、主题变化、图片异步解码不登记 undo。换笔记必须隔离 undo，返回旧笔记时是否恢复历史沿用现有政策；不得撤销到其他笔记。失败持久化保持 dirty 状态和可重试草稿，不能显示“已保存”；草稿的保存期限和退出行为见下一节。

### 4.5 外部修改、删除与恢复

外部 watcher 通知与未提交输入相遇时，不能立即重载覆盖本地内容；既有备份旧 `editArea.string` 的路径改为备份会话权威 Markdown。无本地改动时可以更新会话；有改动时冻结覆盖，保留本地草稿和外部版本并提示选择。本期仅承诺进程存活期间的草稿保留，不新增跨重启恢复库，也不承诺强制退出/崩溃恢复。发生未解决冲突或写入失败时，换笔记、关闭窗口和正常退出必须停在可取消的前置阶段：重试成功后继续，或由用户明确“另存 Markdown 副本”“放弃本地修改”“取消当前操作”；不能到不可取消的 `applicationWillTerminate` 才处理。另存副本由系统面板选择位置，保留磁盘外部版本，不自动覆盖原路径。若未来要求重启恢复，另开持久恢复存储、入口与清理设计；不把它当本期隐含完成项。

文件移动/重命名使旧 URL 的在途任务失效；会话在确认同一 Note 所有者的新地址后重新绑定。删除/移入 Trash 后沿用 Note 退役机制：只读保留必要恢复内容，取消解析/图片/保存回调，禁止把原文件重建。版本恢复是显式整篇内容事务，清理旧投影并更新 revision；存在未解决本地冲突时同样先由用户处理草稿。

### 4.6 单渲染块导出的最小接口

建议新增 `RenderedBlockExportController` 管理一次操作，内部封装目标验证、静态渲染快照、PNG/SVG 编码和原生保存。按需要为 Mermaid、PlantUML、KaTeX 增加具体 adapter；P0 只实现 Mermaid，不提前建插件框架。

```text
RenderedBlockIdentity = displayedNote identity + preview generation
                        + renderer-owned blockID + render revision
RenderedBlockTarget = identity + kind + render state + source fingerprint
PreflightMetadata = identity + ready state + bounds + format capabilities
                    + theme/font/layout fingerprint
RenderedBlockSnapshot = identity + static SVG/HTML + resolved styles/resources
                        + complete layout bounds + captured theme
ExportRequest = requestID + target + destination + format + scale + background
ExportResult = saved(destination, actualDimensions) | cancelled | failed(reason)
```

图表身份由 app 控制的渲染流程登记，DOM class/id 仅用于命中，不是授权来源。当前 Mermaid 会按内容缓存同一 SVG 字符串，因此两张相同内容图不能仅凭 SVG 内部 ID 区分，必须绑定实际容器及其渲染来源。右键发生在子节点时向上寻找已登记的块，校验 `displayedNote` 和本次文档代次。原文替换、主题变化或重新发起单块 render 必须更新 revision，不能只在网页 navigation 时增加代次。同一次 render 从 pending 变成 ready 不另增 revision，否则等待中的正常导出会被误判过期。

```text
原生右键 → 校验一个 renderer-owned 图表
         → 只读预检：块 ready + 字体/资源 ready + 完整尺寸 + 格式能力
         → 保存面板（真实尺寸，默认 PNG 2×）
         → 点击保存 → 再验 identity/revision/布局与预检相同
         → 冻结静态快照；不相同则取消，绝不猜测新尺寸后写出
         → SVG: 打包可独立显示的静态 SVG
           PNG: 隔离渲染该块 → 完整边界栅格化 → PNG 编码
         → 用户选定地址原子写入 → 独立成功提示
```

预检、面板期间或最终快照冻结前，换笔记/刷新/块 revision 变化则取消旧操作并说明“图表已更新，请重新导出”，不能重新按索引取一个不同图。完成不可变快照后允许独立完成保存，不再读取当前笔记或主预览 DOM；文件名与结果仍对应原来那张图。

不调用现有 `exportImage()`：它会添加标题、调整整篇布局并滚到顶部。不直接调用 `toastExport`：它带有下载目录文案和模式恢复副作用。不调用 `ImagesProcessor.writeFile`：它写笔记附件。可提取无副作用的编码/原子写入逻辑，但不能让图表导出改动正文、预览位置或当前模式。

### 4.7 完整边界、SVG 与 PNG 策略

完整边界来自该渲染块的布局坐标，不是当前屏幕 `getBoundingClientRect()` 的可见交集。保留 SVG viewBox 的非零/负起点，并核对正文、箭头、stroke、marker、HTML label、阴影与实际溢出的并集。建议四周留白 16 个逻辑像素；如当前图已含 margin，统一测量以避免双重巨大留白。输出尺寸在保存面板中可见。

PNG 推荐使用**独立、受控的 WKWebView 导出宿主**展示捕获的单块静态内容，按完整逻辑尺寸设置画布后截图/编码，支持原图大于主预览视口。导出宿主只包含这一块和必要资源，不重排主预览、不从整页 PNG 猜测剪裁。`takeSnapshot` 对离屏/未附着窗口的行为、尺寸上限和渲染就绪必须在 D0 实测，不能假定隐藏 WebView 一定能捕获。公开 SDK 明确 snapshot rect 应位于 WKWebView bounds 内，因此必须先设置足够大的导出宿主，而不是对主预览传入超界 rect。`snapshotWidth` 的单位是 points，不是最终 PNG 像素；D0 必须校准 backing scale，最终解码 PNG 检查 1×/2×/3× 实际像素尺寸，不能照抄“宽度乘 2”当作高清证明。

SVG → canvas → PNG 可作为 D0 对照方案，但不能在含 `foreignObject`、中文字体、CSS 或嵌入资源时悄悄丢文字。若它只对简单 SVG 成立，不作为统一主路径。导出宿主方案如也不通过，就在 D0 阻断 PNG 发布并继续解决，不能退回整页截图或只交付 SVG 冒充完成。

独立 SVG 保留 viewBox、defs、marker、clipPath、渐变、ID 引用和必要计算后样式，移除页面导航/事件/脚本能力。不依赖原页面全局 class、CSS 变量和相对字体 URL。`foreignObject` 不能简单删除，否则 HTML label 会消失；必须在独立文件中验证显示，不能保证目标查看器兼容时明确推荐 PNG。PNG 的字体外观固定；SVG 跨系统字型差异需说明，不擅自嵌入无权分发的系统字体。

P1 的 KaTeX 将完整显示公式容器、必要 CSS/字体和编号作为静态 HTML 快照栅格化，不假装它有可导出的整式 SVG。PlantUML 的 `onload` 只证明显示成功，不证明原生端已取得字节。资源准备层优先使用渲染流程保留的可导出 SVG/像素产物；必要时仅资源准备层可重取同一个已登记的原渲染 URL，遵守原网络策略，不附加无关凭据、不向新服务发送源码。所有资源先静态化再交给禁网的导出宿主，失败明确报告，不能在 SVG 独立打开时偷偷重新请求服务器。

### 4.8 就绪、隔离和文件安全

Mermaid 的 ready 条件至少包含本块 render promise 成功、`data-mermaid-rendered="true"`、实际图形存在、有限且非零布局尺寸；`data-processed="true"` 在失败时也可能存在，不能单独作为成功依据；还需等待字体与图内图片/资源完成。只等 `WKNavigationDelegate.didFinish`、固定 sleep 或检测到一个 `<svg>` 都不够。失败状态与 pending 状态分开，不导出语法错误提示、占位图或半张图；后续渲染成功时可以重新启用入口。

导出宿主使用 app 管理的模板与最小资源集，不执行图表里的脚本/事件处理器，不导航、不注册通用文件操作桥、不加载任意 iframe/object，不因复制 SVG 引入额外远程请求；P1 在资源准备层重取已登记 PlantUML 产物的有限例外见 4.7，不能扩大为导出宿主网络权限。资源无法内联/授权取得时明确失败，不能静默缺字、缺图。优先复用已加载的本地渲染资源，不引入云端转换、shell、浏览器扩展或下载服务。

现有主预览 file read access 范围较宽（`/`），不能作为新宿主的权限依据；新宿主读取仅限 app 管理的导出目录及明确允许的资源。即使网页脚本知道 DOM 内容，仍不能伪造原生右键授权。桥接校验 main frame、preview identity、renderer 登记的块、一次性原生 token 和请求 ID；隔离 content world 不等于隔离 DOM。销毁宿主时解除 handler、取消工作并清理自建临时文件。

保存目标仅来自本次 `NSSavePanel`，系统授权范围和访问生命周期与异步写入绑定；不会接受网页指定目的地。先生成完整可验证数据再原子替换目标；写失败/磁盘满保持已有文件，取消不误报成功。文件名为不可信建议值，去掉控制符/路径组件并由真实格式确定扩展名。

日志通过 `AppDelegate.trackError(error, context:)`，记录导出阶段和失败类型，不记录图表源码、笔记正文、完整静态快照、URL token 或 Cookie。取消与用户关闭面板不作为故障告警。

## 5. 性能、兼容与体验预算

以下是**实施验收目标，不是已测结果**。技术验证记录机器型号、系统、构建配置、样本和 p95；不能用一次 Debug build 代替性能测量。

| 场景 | 首版预算/策略 |
| --- | --- |
| ≤200 KB、≤2,000 行的常规笔记进入所见即所得 | 首个可编辑画面 p95 ≤300 ms；超过 100 ms 提供轻量加载状态，不阻塞整个窗口 |
| 常规连续输入 | 同步主线程编辑处理 p95 ≤16 ms；派生样式更新 p95 ≤100 ms；IME 不等待解析完成 |
| >1 MiB、>5,000 行或单段 >64 KiB | 首版明确回退源码；不降低原有源码编辑能力 |
| 常规 Mermaid 导出（≤100 节点、≤2,000×2,000 逻辑像素） | 保存确认后 p95 ≤3 s，不计用户停留面板时间；主窗口仍可交互 |
| 静态快照/资源 | 序列化快照 ≤10 MiB，资源总量 ≤50 MiB，单次并发 1；过大在桥接/解码前拒绝 |
| PNG 完整画布 | ≤25 MP，单边 ≤16,384 px，像素缓冲预算 ≤128 MiB；按倍数计算后预检，超限提示降低倍数或选 SVG，不静默裁切/降清晰度 |
| 等待/取消 | 面板前本块渲染及字体/资源预检等待 10 s、保存确认后的编码/写入总时长 60 s；取消停止在途任务并清理自建临时文件 |
| macOS 兼容 | 11.5 API 基线与维护中的新系统分别验证；不将 macOS 12+ API 无保护带入旧系统 |

macOS 文案覆盖英文以及 es/ja/zh-Hans/zh-Hant。菜单增加 storyboard 条目及四份 ObjectID-keyed `Main.strings`，新提示增加四份 `Localizable.strings`；不能只补中文。键盘焦点、VoiceOver、暗色/亮色、缩放与 Retina 是验收项。预览图片/表格/iframe/video 继续 `max-width: 100%`，不引入横向溢出。

## 6. 验收矩阵

| 验收 ID | 场景与通过条件 | 关联需求 |
| --- | --- | --- |
| A-01 | 基础段落/格式/标题/列表直接编辑；输入/转义/普通与 Markdown 粘贴符合操作矩阵；三层列表分拆合并可 undo；不靠点击回源码冒充完成 | W-02、W-03 |
| A-02 | 包含 frontmatter、CRLF、Emoji、引用链接、表格、公式、图表、raw HTML 的笔记反复切模式 20 次，不编辑时文件 hash 不变 | W-05、W-06 |
| A-03 | 仅改一个词、一次任务勾选或一处链接，除对应源码区间之外内容不变；代码和受保护块不被意外格式化 | W-03、W-04、W-05、W-06 |
| A-04 | 中文/日文组词、候选选择、组合中菜单/换笔记、Emoji/组合音标正确；人为延迟/乱序解析下连续输入不漏字不重复，停下后投影收敛 | W-07 |
| A-05 | 编辑 → 切模式 → 撤销/重做仍作用于同一笔记；A/B 快速切换不共享撤销；样式刷新不产生记录 | W-06、W-07 |
| A-06 | 编辑 A → 预览 B → 所见即所得编辑 B → 显式保存/换笔记/退出，A/B 不串写；同一 B 的旧源码缓冲也不能覆盖新原文；待保存队列归属正确 | W-08 |
| A-07 | 外部变化/Trash/恢复遇到在途编辑：删除不复活、旧回调不落盘；未解决冲突/写失败时换笔记/关窗/正常退出必须重试、另存、明确放弃或取消，不静默丢草稿 | W-09 |
| A-08 | 查找/替换、TOC、Wikilink、格式化、附件粘贴和菜单正确路由；Prettier 请求中继续编辑同一笔记或 undo 后，旧结果拒绝应用；格式化可完整 undo/redo | W-04、W-10 |
| A-09 | 新旧设置迁移、空笔记/无选中笔记、超限文件和解析失败均正确；回退不丢内容，满足性能预算 | W-01、W-11 |
| A-10 | 同页至少三张 Mermaid 分别右键节点/边/文字/空白，输出仅是被选的完整一张；普通图片不增加本功能项；正常预览/分栏一致 | D-01、D-07 |
| A-11 | flowchart、sequence、class、state、ER、gantt、mindmap/ELK（以当前引擎实际支持为准）、中文长标签、HTML label 的 PNG 可在 Preview 打开；SVG 在独立页面打开无原文 CSS 依赖 | D-02、D-04 |
| A-12 | 宽/高超出视口的图、负 viewBox、箭头/阴影边缘不截断；改变滚动、缩放、分栏宽度后导出仍完整；1×/2×/3× 尺寸及背景符合约定 | D-03、D-04 |
| A-13 | 渲染未完成、语法错误、延迟字体、资源失败、零尺寸、超限画布不保存空白/半成品；预检完成后面板尺寸准确，确认时变更不能偷换尺寸/格式；取消面板/等待、覆盖、权限拒绝、磁盘满不留半文件、不改笔记 | D-05、D-06、D-08 |
| A-14 | A图打开面板后重渲染/换笔记，旧操作取消；冻结快照后保存仍只含A图；假 block id/token、子 frame、重放和恶意 SVG 不能触发任意读写/导航/新网络访问 | D-07、D-08 |
| A-15 | 11.5 API 基线、新系统实机、Sandbox、四种非英文文案、键盘/VoiceOver、暗亮主题和既有整篇 PNG/PDF/图表渲染均无回归 | W-01、W-10、D-01、D-06、D-08 |
| A-16 | P1：PlantUML 和块级公式各只输出命中块，PNG 包含中文/字体/公式编号；无法取得远程图形时明确失败；普通图片和行内公式不误识别 | D-02、D-04、D-05、D-08 |

## 7. 决策状态与发布门槛

**用户已确认：Mermaid 等渲染内容的单张保存最重要，普通图片另存不是需求。** 因此先独立交付 Mermaid PNG 和可用 SVG；不以 WYSIWYG、普通图片下载或通用渲染插件化作为前置。PlantUML/块级公式为下一步复用扩展，表格/代码块等后续另定。

建议 WYSIWYG 采用“macOS 可选原生编辑 + 复杂语法安全回退”。其技术验证必须同时证明基础内容直接编辑、无损映射、IME 和 undo 可用，才能进入全面实施；失败只阻止新编辑模式，不影响图表导出。不得偷偷换网页编辑器、提高最低系统版本或把源码高亮包装成完成。

Mermaid 首发门槛为 A-10–A-15；PNG 完整图形和中文/HTML label 保真属于阻断项，SVG 不兼容类型必须明确不支持而非生成坏文件。PlantUML/公式正式宣称支持前额外通过 A-16 及相同安全/尺寸测试。

源码仍为默认编辑模式。WYSIWYG 可先有明确试用开关，正式可选入口通过 A-01–A-09、A-15。关闭新模式不影响 `.md`；图表导出没有数据迁移需求。正式 release 必须按直接下载版/App Store 分别报告状态。

## 8. 官方技术依据

下列官方资料与本机公开 SDK 用于本轮技术核验；产品范围、预算和事务模型属于本方案设计，不是资料作出的保证。`WKSnapshotConfiguration` 已读取本机 SDK 头文件，在线正文因连接异常未完成读取，保留文档链接供实施时复查。

| 资料 | 核验用途 |
| --- | --- |
| [Apple — NSTextStorage](https://developer.apple.com/documentation/appkit/nstextstorage) | 字符/属性变化与 layout manager 的关系；文本存储需要串行访问 |
| [Apple — NSTextLayoutManager](https://developer.apple.com/documentation/appkit/nstextlayoutmanager) | TextKit 2 布局类 macOS 12.0 起可用，不能直接作为 11.5 唯一路径 |
| [Apple — hasMarkedText](https://developer.apple.com/documentation/appkit/nstextinputclient/hasmarkedtext()) | 使用原生输入协议识别正在进行的输入法组合 |
| [Apple — NSSavePanel](https://developer.apple.com/documentation/appkit/nssavepanel) | 原生文件保存交互与异步 sheet 入口 |
| [Apple — Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) | 用户选择 URL 的 sandbox 授权与访问生命周期 |
| [Apple — WKContentWorld](https://developer.apple.com/documentation/webkit/wkcontentworld) | 脚本作用域隔离不隔离 DOM，不能取代原生端验证 |
| [swift-cmark-gfm — pinned README](https://github.com/stackotter/swift-cmark-gfm/blob/7ec44e7384793e507cf046336aef68586719a24e/README.md) | 现有 1.0.2 依赖提供 C API 导入，不自带富文本编辑器或无损序列化层 |
| [Mermaid — Usage / API](https://mermaid.js.org/config/usage.html) | 单次 render 产出 SVG、字体加载与标签边界的关系；具体接口以仓库 vendored 产物验证为准 |
| [Mermaid — Config Schema](https://mermaid.js.org/config/schema-docs/config.html) | 主题、布局、HTML label 等导出保真因素；不把在线最新版配置直接套到未知版本 bundle |
| [KaTeX — Options](https://katex.org/docs/options.html) | 支持 HTML/MathML 输出，display block 导出不能假定是完整 SVG |
| [Apple — WKSnapshotConfiguration](https://developer.apple.com/documentation/webkit/wksnapshotconfiguration) | 本机公开头文件确认 rect 需在 view bounds 内，snapshotWidth 单位为 points；离屏可见性与最终像素尺寸仍需 D0 实测 |
