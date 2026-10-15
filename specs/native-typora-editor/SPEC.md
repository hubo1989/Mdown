# Mdown 原生 Typora 式编辑器 — 实现 Spec

状态：实施规格草案，2026-10-14。本文中的“必须”是本次实施的验收合同，不表示能力已存在。任务、文件责任和阶段验证见 [PLAN.md](PLAN.md)。本轮仅生成文档，不修改业务实现、删除依赖、提交或发布。

基线：`/Volumes/external/Projects/Mdown`，`main@b8110a942e27ae13ebe531b549a56e5a220f91ae`；当前已有未跟踪的 `specs/typora-research/` 为此前研究成果。执行前重新核验 HEAD、分支和既有修改。

## 1. 目标、范围与规格关系

### 1.1 最终目标

用 Swift/AppKit 实现 Typora 式 Markdown 编辑：直接编辑排版后的正文，支持标记显隐、结构输入、表格、复杂块源码编辑、选区和语义撤销；正文的编辑、解析映射、输入规则、代码高亮、格式化与保存不依赖 JavaScript。

最终移除 macOS 编辑链的 Vditor、Highlightr、Prettier/PrettierMarkdown 及其专属资源。保留现有 Note/Storage、原生 cmark-gfm、Wikilink、版本管理、附件约定、源码/分栏/预览/演示布局。公式、图表和导出 renderer 在明确边界内可继续使用本地 WebKit/JS，不拥有正文、不承接文字输入。

**“Typora 体验一致”指版本固定、场景可重复的用户可见行为一致。** 不要求复制私有源码、DOM、CID 命名、许可证、同步 RPC 或像素相同的 Mdown 整套窗口。未观测或不兼容的功能必须列入差异矩阵，不能以静态反编译推成已实现。

### 1.2 交付层次

| 交付点 | 必须达到 | 可保留/明确限制 |
|---|---|---|
| G0 原生可行性验证 | TextKit 1 原型证明正文直接编辑、无损 source map、IME、跨块选择、撤销和延迟解析收敛 | 不接默认编辑面、不删除依赖 |
| N1 原生基础模式 | 会话接入全部保存/生命周期；基础语法、图片/链接、源码切换、查找与命令可用 | 可选模式；复杂表格/扩展在此阶段可显式局部源码；不是完整同等性 |
| N2 编辑链去 JS | 表格/代码/复杂块交互、原生高亮/格式化、focus/typewriter/系统服务达标；三条编辑依赖移除 | 只读图表/公式/演示/导出 renderer 可保留 |
| P-Gate 行为对齐 | 已声明支持集合有官方 Typora 对照、当前 Mdown 结果与明确差异；输入/保存/导出验收通过 | 未测功能不算通过，不笼统宣传“全功能完全一致” |
| R2 全渲染去 JS | 每个剩余 renderer 有独立原生替代并通过语法/视觉/导出验收 | 后续扩展，不属于本次编辑链退依赖的默认范围 |

基础阶段局部源码回退只是阶段边界，不能把表格长期不可编辑、普通正文点击回源码包装成最终完成。

### 1.3 与既有规格的关系

本 Spec 是 macOS 编辑器替换主合同，更新并扩展 [旧 W 线 SPEC](../wysiwyg-and-rendered-block-export/SPEC.md) 的原生路线；没有改变旧 [PLAN](../wysiwyg-and-rendered-block-export/PLAN.md) 的 TextKit 1、macOS 11.5、原文保护及 W0/G0 门槛。

旧规格的 **D 线：单 Mermaid PNG/SVG 优先、普通图片另存非目标**继续有效；图表导出已有代码需要核验，不能再按“尚无实现”重复新建。D 线不以本次全编辑替换为前置。发生冲突时：保存安全/源码保真采用本文具体合同；独立渲染块导出的格式、尺寸、安全和优先级仍采用旧 D 合同。

### 1.4 非目标

本次不改 iOS UI、不共享 AppKit 编辑类到 iOS、不重写数据库/云同步、不引入 SwiftUI 编辑核心、不抬高最低系统版本、不改变现有 Markdown 文件/附件目录、不新增遥测或网络服务、不默认安装 Pandoc/Java/新解析器。不做协作编辑、Word 式布局、任意 HTML 执行、许可证功能复刻或整个侧栏视觉重设计。

进程内草稿和正常退出保护必须实现；跨重启/崩溃恢复库是单独设计，不能从 Typora 的快照字段推成本期隐含功能。

## 2. 当前基线与已知实施阻塞

| 事实/入口 | 对实现的约束 |
|---|---|
| [EditTextView](../../Views/EditTextView.swift) 是 NSTextView；CustomTextStorage 是 delegate extension | source 模式可复用；不能把隐藏标记样式当作无损投影完成 |
| [VditorEditView](../../Views/VditorEditView.swift) 是已接入的 WKWebView 编辑器 | 当前不是只有源码编辑；替换需覆盖 host、mode、消息和所有保存入口 |
| editor.html 把 setValue 第二参数当回调，随包合同实际是 clearStack boolean | 实施前运行复现并补真实 input→save 回归；这是 wrapper 错配，不是 Vditor 本体缺乏 IME |
| 原生 buffer 只做 owner URL 校验；Cmd+S/close/terminate 仍会采隐藏 source | 同 owner 的旧 revision 必须拒绝；仅补跨笔记 guard 不够 |
| Vditor 先改 Note.content，再等 0.5 s，Note 又有 1.5 s debounce | 新会话只有 Note 既有保存调度；不继续两套正文/dirty 定时器 |
| Highlightr 2.3.0、Prettier 0.2.1 有编辑 JS 路径 | Vditor 删除不等于编辑链本地化；必须分别替换全部间接调用 |
| CMarkGFM 1.0.2 为原生 C API | 可做语义解析；经 math/frontmatter/Wikilink 预处理的 HTML sourcepos 不是原文选择坐标 |
| 原生 Note 已有 dirty/flush/原子写入/退役机制 | 保留并扩展必要的结果与 revision 接口，不另造保存服务 |
| mode raw value 已是 source/split/wysiwyg；⌘3 标签为 Toggle Preview，当前代码与标签有漂移 | 保留偏好值，统一布局和临时阅读状态；不得新占 ⌘0–⌘5 |
| 旧 Spec 标 main@668e367“未实施”，当前已经接 Vditor 和块导出 | 以实际 HEAD 为准，复用现有组件，不把历史文档当运行事实 |

详细路径与证据见 [迁移核验](../typora-research/MDOWN-MIGRATION.md)、[编辑模型](../typora-research/EDITOR-MODEL.md)、[原生研究](../typora-research/NATIVE.md)、[导出研究](../typora-research/EXPORT.md)。当前 Typora 样本签名 Authority 为 Antibiotics，官方发行身份未验证；正式对照必须另核验官方原包。Hopper 伪代码仍阻塞，但原生函数存在已有 ARM64 静态证据；这不阻止独立原型，也不证明运行同等性。

## 3. 需求编号与交付责任

| ID | 必须满足的合同 | 最迟门槛 |
|---|---|---|
| NE-01 | 保留 source/split/wysiwyg 偏好和旧用户默认；wysiwyg 最终路由原生视图 | N1 |
| NE-02 | 一个权威 MarkdownEditingSession，view/Note/renderer 不互相定时覆盖正文 | N1 |
| NE-03 | 无编辑模式往返字节一致；保留 BOM、CRLF/LF、末尾换行、metadata 与未修改片段 | G0/N1 |
| NE-04 | 原文 UTF-8、原文 UTF-16、显示 UTF-16、grapheme 转换明确并验证 | G0 |
| NE-05 | 正文和行内标记显示/隐藏、caret affinity 可逆；基础内容点击后仍直接编辑 | G0/N1 |
| NE-06 | 段落、H1–H6、强调、删除线、行内 code、普通链接直接编辑 | N1 |
| NE-07 | 三层列表/引用、任务勾选、拆分/合并/缩进不改写其他原文 | N1 |
| NE-08 | Enter、Backspace、Delete、Tab、跨块替换使用同一结构事务 | N1/N2 |
| NE-09 | GFM 表格单元格与行列操作、导航、对齐、转义和撤销 | N2 |
| NE-10 | fence 内用原生文本编辑；语言/定界符处理、原生代码高亮可用 | N2 |
| NE-11 | 数学/图表/HTML 等复杂块源码编辑与只读渲染分离，错误仍可保存 | N1/N2 |
| NE-12 | frontmatter、引用定义、脚注、Wikilink、Alerts、未知语法原文保留 | N1 |
| NE-13 | 真正中文/日文组合输入不被解析/样式/快捷键打断；转换期间可安全离开或留在原上下文 | G0/N1 |
| NE-14 | 键盘/鼠标/多块选择与源码定位稳定；不能切断代理对/组合字符 | G0/N2 |
| NE-15 | 同笔记跨 source/rich 同一语义 undo/redo；视图变化不登记编辑 | G0/N1 |
| NE-16 | identity/generation/revision 防跨 owner、同 owner 旧结果和退役笔记写回 | N1 |
| NE-17 | commit 进入 Note.save；dirty 与 persistedRevision 分离；实际写成功才报告保存 | N1 |
| NE-18 | Cmd+S、失焦、切笔记、close/terminate 前提交/flush；失败/冲突可取消离开 | N1 |
| NE-19 | watcher 外部版本与本地 dirty 相遇时保留双方、不自动覆盖 | N1 |
| NE-20 | rename/move/Trash/恢复和同 URL 新 Note 实例有明确 rebind/失效规则 | N1 |
| NE-21 | plain/Markdown/HTML 粘贴与复制分开，代码/URL/metadata 保护 | N1 |
| NE-22 | 附件与上传结果绑定捕获的 owner/位置；失败/迟到不污染正文 | N1 |
| NE-23 | 查找/替换作用于权威 source，结果映射显示或安全定位源码 | N1 |
| NE-24 | 格式、TOC、Wikilink、快捷模板和菜单走活动会话命令 | N1/N2 |
| NE-25 | 原生 Markdown Formatter 替代 Prettier，显式、可撤销、幂等、拒绝过期结果 | N2 |
| NE-26 | 原生 token 高亮替代 Highlightr，不改变正文/组合输入 | N2 |
| NE-27 | 输入先更新必要局部映射；后台 parse 合并、取消旧任务、最终收敛 | G0/N2 |
| NE-28 | JS renderer 不提供全文写入；交互意图只能经原生 identity/revision 校验成命令 | N1/N2 |
| NE-29 | 预览/演示/导出读同一不可变 snapshot，单块导出独立，资源失败明确 | N1/N2 |
| NE-30 | 性能预算、压力回退、内存/主线程无长时全篇处理有测量 | G0/P-Gate |
| NE-31 | macOS 11.5、直接下载/App Store、iOS 文件读取兼容 | N2/P-Gate |
| NE-32 | 字体/主题/缩放、VoiceOver、系统拼写和键盘焦点可用 | N1/N2 |
| NE-33 | 中文/英文及 es/ja/zh-Hant 文案和现有快捷键不漂移 | N1/P-Gate |
| NE-34 | 退依赖证明包含源码调用、工程链接、产物资源和运行路径 | N2 |
| NE-35 | Typora 对照、固定 corpus、需求→测试→证据映射完整 | P-Gate |
| NE-36 | 可选模式渐进替换，停止/回退不删除笔记、不丢草稿 | N1/N2 |
| NE-37 | 原生 typewriter/focus 模式与滚动锚点，切换不改正文/undo | N2 |
| NE-38 | 字数/拼写/自动替换/缩放走原生服务，code/math 不误变换 | N2 |

## 4. 用户可见行为与语法分层

### 4.1 布局、模式与标记展开

编辑布局保持 `source / split / wysiwyg`；reading state 单独为 normal/preview/presentation/PPT，进入阅读前记住编辑布局。⌘3 依现有菜单语义进入/退出纯预览；不再兼做“源码↔富文本”开关。新原生编辑入口复用 WYSIWYG 设置和菜单路由，向用户说明该版本用原生后端；若改变实际旧行为，需在 release notes 解释，不改快捷键占用。

正文点击后保持排版状态可输入。支持显式局部“显示 Markdown 标记/编辑块源码”，在支持范围内不把整段一律退回源码。标记展开的默认细节由官方 Typora 逐项操作记录锁定；Mdown 的最小原文保护和跨模式统一历史优先于样本的内部实现。

切模式：完成组合→保存当前会话选择/滚动锚→派生目标视图→映射成功后显示；失败留原上下文。只切模式不改 revision、dirty 或历史。源码回退限定当前笔记/块，不暗改全局模式偏好。

预览宿主明确复用现有 `Views/MPreviewView.swift`：分栏右侧是 `previewScrollView.documentView` 中的 MPreviewView，纯预览也使用该实例/既有加载路径；Vditor 位于左侧 editorContainer，只替换左侧 rich backend。分栏保持“原生 source + 只读预览”，本期不另建 MarkdownPreviewView。MPreviewView 原有 task 交互按有限原生 intent 接入，不能让删除 Vditor 顺带删除预览宿主。

### 4.2 语法能力

| 语法 | N1 | N2 最终编辑边界 |
|---|---|---|
| 段落/H1–H6/强调/删除线/inline code | 显示文字直接编辑 | 保持；完整跨样式选择、组合输入与命令 |
| list/quote/task | 至少三层直接编辑 | 混合嵌套、跨项合并/退级、paste 和结构选择 |
| inline link/image | 显示及原生 alt/title/目标面板 | 目标与显示分离、附件失效占位、跨模式定位 |
| reference link/footnote | 保留原文、定位定义；不静默复制定义 | 编辑正文及定义的明确入口；共享定义修改说明影响；不内联改写全文 |
| GFM table | 排版投影/局部源码回退 | 单元格直接编辑、行列增删/移动、alignment、跨 cell 选择/粘贴 |
| fence | 原生局部源码编辑 | 原生高亮、语言/围栏属性、escaping 和退出块快捷键 |
| block/inline math、Mermaid、PlantUML | 原生源码入口 + 已登记只读渲染/错误状态 | 同一原文会话内切源码/渲染，错误/超时不阻止打字和保存；不拖拽改图形模型 |
| frontmatter | 文件保留、正文不展示，源码定位 | 原生 metadata 编辑可选；不得剥掉文件头或移动定义 |
| Wikilink/Alerts/raw HTML/未知扩展 | 可识别展示或受保护源码，不执行网页写入 | 明确支持/回退边界；无需承诺任意 HTML 变 Word 文档 |

N2 的“不直接拖拽数学/图表”符合 Markdown 编辑边界，不以截图代替原文编辑。未知语法必须保持可打开、可源码编辑、可保存。

### 4.3 输入动作合同

| 动作 | 原生结果与事务边界 |
|---|---|
| 空段起始输入 `# `、`- `、`1. `、`> ` | 合法前缀完成才结构转换；撤销恢复完整字面前缀，不吞字 |
| 闭合强调/inline code | 合法且非转义时投影样式；未闭合保持可见输入；URL/code/math 区不触发普通规则 |
| 段落 Enter / Shift+Enter | 新段落 / 显式 hard break；只改局部 source |
| heading 末尾 Enter | 后继普通段落；标题内分裂保留左右正文，精确行为补 Typora 样本 |
| 非空列表 Enter / 空项 Enter | 分项 / 退一级或退出最外层；不全列表重新编号/格式化 |
| Tab / Shift+Tab | list 缩进/退级，code 原生缩进，table 格导航；IME 先处理候选；普通段依现有 tab 设置 |
| 块首 Backspace/Delete | 可安全合并/退级；跨未知块先局部 source 定位，保留全部文字 |
| table Tab / Shift+Tab | 下一/前一单元格，末格追加行须纳入单次结构事务 |
| table Enter / Shift+Enter / ⌘Enter | 默认下一行同列 / 单元格 hard break / 添加行；必须在官方样本核验并记录有意差异 |
| fence 末行 ⌘Enter | 在块后创建段落并退出；code 内 Enter 不触发 Markdown 结构规则 |
| 跨块选区替换 | 验证完整映射后一次事务；不可安全映射先显示同 source 选区，不执行猜测删除 |

输入动作经同一 command adapter，不能普通 typing、toolbar、菜单分别生成不兼容正文。结构转换与输入本体可做相邻逻辑 undo group；不会把整个输入前缀只当“样式刷新”。

### 4.4 复制/粘贴与附件

外部普通 paste 按字面文本，必要时转义防意外 Markdown 结构；显式“粘贴 Markdown”按语法插入。应用内可用专用 Markdown pasteboard 保留结构。HTML paste 仅在显式富结构检测下转换，沿用 HtmlToMarkdown 的门槛；在 code 中保持 plain。默认 Copy 输出可见文本，另有 Copy Markdown；不把隐藏链接目标混入用户未请求的文本。

图片和文件引用沿用笔记旁 `i/`、`files/` 约定，附件写入成功后才插入 source 引用。上传 job 捕获 identity、block/source anchor 和 requestID；同会话中 anchor 有可追踪位置变换时可安全插入，否则取消/要求重试；不能把任何 revision 变化一律当“插当前 selection”。离开/删笔记后的结果不发布，不重建退役文件。

## 5. 权威原文、事务与并发合同

### 5.1 状态归属

`MarkdownEditingSession` 在窗口编辑上下文持有原文和语义历史。当前支持单窗口单活动笔记，复用既有 Note；不默认新增共享多窗口数据库。将来允许同文件多会话时需有共享 revision 协调，不能照搬无版本命令广播。

| 状态 | 所有者 |
|---|---|
| 原始 source、newline/encoding policy、revision、选择 | MarkdownEditingSession |
| 组合中的临时 marked text | 活动 AppKit input view + 会话 CompositionDraft |
| parsed tree/token/source ranges | 可丢弃的 immutable parse snapshot |
| display attributed string/attachments/layout | projection，不能整篇回写 Note |
| Note.content | 会话已提交原文快照；沿用 Note dirty/debounce/flush |
| 磁盘正文 | Note 既有原子写入结果，记录实际 persisted revision/digest |
| 图表/公式/preview/export | snapshot consumer，不能成为正文权威 |

`selectedNote`、`EditTextView.note` 和 `storageNote` 的角色继续区分。为旧 source buffer 增加 revision metadata；整体发布仍通过 publishStorage，保存入口必须核对 revision 或从 session 读取原文。

### 5.2 最小值类型合同（拟新增，非现存 API）

以下类型确定输入输出语义；实现可拆文件但不可删验证字段。NSRange 仅用于明确的 source UTF-16，不与 parser byte 或 display range 混用。

```swift
import Foundation

struct EditingIdentity: Equatable {
    let ownerToken: UUID
    let canonicalURL: URL
    let generation: UInt64
}

struct MarkdownSelection: Equatable {
    let anchorUTF16: Int
    let focusUTF16: Int
    let affinity: Affinity

    enum Affinity: Equatable {
        case upstream
        case downstream
    }
}

struct SourcePatch: Equatable {
    let rangeUTF16: NSRange
    let expectedText: String
    let replacement: String
}

enum EditOrigin: String {
    case typing, composition, delete, structure, format, paste
    case attachment, source, previewIntent, restore, externalReload
}

struct EditTransaction {
    let identity: EditingIdentity
    let expectedRevision: UInt64
    let patches: [SourcePatch]
    let selectionBefore: MarkdownSelection
    let selectionAfter: MarkdownSelection
    let origin: EditOrigin
    let undoGroupID: UUID
}

struct EditingSnapshot {
    let identity: EditingIdentity
    let revision: UInt64
    let markdown: String
    let selection: MarkdownSelection
}

enum EditRejection: Equatable {
    case ownerChanged, generationChanged, staleRevision, retired
    case readOnly, compositionActive, invalidRange, overlappingPatches
    case expectedTextMismatch, ambiguousProjection
}

enum EditApplyResult {
    case accepted(EditingSnapshot)
    case noChange(EditingSnapshot)
    case rejected(EditRejection)
}
```

最小会话API供实施与测试对齐（拟定签名）：`MarkdownEditingSession(identity:markdown:selection:isReadOnly:)` 建立revision=0的基线，`snapshot` 返回EditingSnapshot，`apply(_ transaction:) -> EditApplyResult` 执行原子更新。Note、磁盘写和renderer不注入到range纯逻辑，测试无需用户库。正式对Note的commit/flush由协调层接入；不得仅为满足测试而绕过实际Note结果。

事务 patch 都以同一个不可变 base revision 计坐标。先验证 identity/generation、读写/退役状态、revision、范围、边界、expectedText 与互不重叠，再按从后到前应用；任一项失败全不应用，历史/dirty/selection 不变。同位置多个插入必须先合并为单 patch，不能依数组偶然顺序生成不同结果。

当前文件被重新加载为另一 Note 实例时，兼容 legacy 同 URL 行为采用明确 `rebind`：确认 canonical file identity 后提升 generation、使旧任务失效，再发布当前 revision；不在任意回调里仅凭 URL 相等继续写。移动/重命名同样走 rebind，文件删除走 retire。

实际正文变化提升 revision；无变化返回 noChange，不添加 undo、不启动 save。undo/redo 也是新 revision 的反向/正向 source transaction，不把 revision 倒退以接受旧异步结果。模式、字体、滚动单独是 view/render generation，不提升正文 revision。

source editing adapter不是额外全文定时diff服务：使用NSTextView输入/替换range捕获source patches，整体加载/恢复是带明确origin的replacement。rich adapter将display range映射source，两个adapter在同一main-actor事务应用后刷新当前view；程序化刷新必须与用户输入区分，防textDidChange再次登记save/undo。

### 5.3 组合输入是会话内临时草稿

marked text 存在时原生输入系统维护临时内容/候选；CompositionDraft 保存基 revision、source anchor、replacement 范围和临时 selection。临时 textStorage 变化不是多个持久化 transaction，不从它回转整篇 source。

提交组合时把最终字符串和选区一次转换成合法 source patch；取消组合恢复基文本；同一时刻不允许后台属性/parse 重建当前组合区。组合期间来自其他入口的正文操作需延后、取消或留原上下文，不在 stale 映射上套新 patch。输入候选按键先交 NSTextInputClient，不硬复制 JS 229 逻辑。

切模式、改名、换笔记、关闭、显式保存请求输入系统完成组合，并等待实际提交结果；无法完成则保留当前上下文。不能用 discardMarkedText、清空 selection 或 wholesale storage assignment 冒充正常完成。

### 5.4 语义历史

复用每笔记 UndoManager，把 source inverse patches、selection before/after 和命令名作为语义记录。source 和 rich 使用同一历史；防止 NSTextView 内置字符 undo 与 session 同时登记同一动作。主题/parse/render/scroll 不登记历史。

连续输入聚合仅同 identity、同语义类型、相邻范围、无选择/结构边界且未超时；IME 提交、paste、format、table structure 各为明确 group。初始聚合策略可参考 Typora 的条件，但三秒不是未经实测的硬合同；G0 记录与调整策略，最终在 parity matrix 固定值和差异。新编辑截断 redo。进程内 note 历史隔离并沿用现有切换政策；不新增历史跨重启持久化。

## 6. 原生解析、映射与投影

### 6.1 保真解析

以原始、未经过 preview 预处理的 Markdown 为输入。CMarkGFM 做 CommonMark/GFM 语义，额外 lossless lexical ranges 保留定界符、空白、换行、引用定义和扩展。数学/frontmatter/Wikilink/Alerts 若需预处理，必须同时产可逆 source map；不拿 renderMarkdownHTML 的 HTML 位置代替它。

文件初读记录 source 字节摘要、UTF-8 BOM、LF/CRLF/混合行尾、末尾换行。只浏览不改不写盘。混合行尾只修改对应范围；新增行使用当前邻域/既有 policy，不一次性正规化全文。旧 Note 对非 UTF-8 文件的读写转换属于已有兼容路径：原生 rich 初期仅对验证无损的 UTF-8（含 BOM）开放；其他编码沿用 source 并说明，不暗换编码。UTF-8 BOM 或 FileWrapper 管线无法保真时必须在正式 rich 接入前修复局部编码接口。

参考定义/footnote/list/fence 改动可能影响远处语义；增量失效范围扩展到相关父块及依赖引用，解析不确定时完整后台重解析，但不能让后续 typing 等待它。

### 6.2 source/display 映射

每段 segment 包含 source UTF-16 range、display UTF-16 range、kind（text/delimiter/blockMarker/linkTarget/code/attachment/metadata）、可编辑策略与 block identity。source byte、parser line/column→UTF-16 转换须检验 tabs/end-column 及 CRLF，不把 Swift String.count 直接用为 NSRange。

隐藏 marker 两边共享 caret 时按 affinity 确定插入侧；backward/forward delete 不误删另一 delimiter。跨块 selection、图片占位、空块和 inline code 都要有可逆定位；不支持的范围先安全展开局部 source。attachment 的 object replacement character 永不保存进 Markdown。

优先采用单一主 NSTextView 的属性/附件投影，尽量保留同一文本输入客户端与连续选区。独立 table 网格、code 子编辑器只作为 G0 的有条件备选，不能假设多个 NSView 天然共享 TextKit 选区。

若采用独立子 View，G0 必须证明一个 source selection owner 能把主文字区与子控件 Range 转换为统一的 anchor/focus，协调跨 View 的选区高亮、Shift/鼠标连续扩选、复制、删除/替换、焦点转移与同一 UndoManager。组合输入期间不能转移 input client；切入/切出子编辑面须先完成或保留组合，再映射选区。无法证明跨段落→code→table 操作连续时，该架构不得接入 N2，不能以每个子 View 内部测试通过代替。

投影形式和失败回退由 G0 实际结果裁决，不提前承诺独立网格可行；无论采用哪种形式都不增加新的正文权威。

### 6.3 即时局部更新与后台调度

每个接受的 patch 同步推进必要的 source map 和 caret，下一次输入可立即处理。完整 parse/样式在后台用 immutable snapshot 执行，一次 running、一个 latest pending；取消旧任务并丢弃旧结果，停止输入后必须收敛至最新 revision。

mapping 当前 revision 不完整时，在同块可编辑 source fallback 接受文字并保持原文，不能拒掉用户连续输入。组合区的 display mutation queue 在 composition 完成且 revision 匹配后应用。后台任务不读活跃 NSMutableAttributedString，不在 main thread 扫全文或运行大 code parser。

原生C parser若不支持执行中取消，cancel仅使其结果不可发布；同一会话不得无限创建并发parse来躲避旧任务。运行任务完成后只取latest pending；大文档需要分块预算或回source，不以Task.cancel等同底层CPU任务已停。

最终输入法实现的AppKit依据：[setMarkedText](https://developer.apple.com/documentation/appkit/nstextinputclient/setmarkedtext(_:selectedrange:replacementrange:))、[insertText](https://developer.apple.com/documentation/appkit/nstextinputclient/inserttext(_:replacementrange:))、[hasMarkedText](https://developer.apple.com/documentation/appkit/nstextinputclient/hasmarkedtext())与[shouldChangeText](https://developer.apple.com/documentation/appkit/nstextview/shouldchangetext(inranges:replacementstrings:))。上下文文档只证明接口语义，真实组合/选区/性能仍须G0；CMarkGFM source位置以pinned版本和实际fixtures为准。

## 7. 保存、冲突与生命周期

### 7.1 单一提交/保存路径

所有正文入口→session.apply→Note.save(content: sourceSnapshot)→原有 debounce/executeSave。删掉新路径外层独立 save timer；Note.content 赋值不等于 dirty 或保存成功。新增 write outcome 至少包含 captured identity/generation/revision、成功/失败、实际内容 digest；新 revision 或rebind已到来时旧写完成不能清掉新 dirty。只写必要的 Note 接口，不重写整个存储。

这里的 Note.save 路径表达保存语义，不要求每次按键都重新生成、unLoad 或扫描整篇 NSMutableAttributedString。协调层可新增最小的增量 commit 接口，把已验证 patches 应用于 Note 的已提交文本镜像，并立即登记 pending `(ownerToken, generation, revision)` 和 dirty；完整编码/FileWrapper 在既有 debounce 触发或显式 flush 时从捕获的不可变 source snapshot 生成。旧 save(content:) 保持兼容，不能让 legacy 调用绕过当前 session。

pending 更新仍使用 Note 原有 1.5 秒调度，不新建外层 timer；不得为减少拷贝而等到 timer 才设置 dirty、把 Note.content 留成旧版本，或让版本/预览读取未提交草稿。旧 write outcome 清 dirty 必须与当前完整 identity/generation/revision 三元组和内容摘要匹配；重绑定后的同 URL、同数字 revision 也不得误匹配。具体增量/COW方案在 T07 用分配与输入延迟实测，不仅推断“Swift String 会便宜复制”。

flush结果必须区分saved、noChanges、failed、retired/conflicted等已知状态，UI据此判断是否允许离开。保存语义不因本轮升级为跨文件事务；批量flush仍逐Note收集真实结果，失败Note保留dirty和owner，其他已成功Note不回滚。

Cmd+S 从 session 当前原文提交并 flush；成功 toast 仅所有必要 flush 实际成功时。preview/presentation/PPT/HTML/PDF/diagram 导出读取同一 committed snapshot，不采隐藏 source。

版本记录区分两种来源：实际写盘成功后建立的保存版本，以及现有导航离开/打开版本面板/恢复前建立的本地恢复快照。保留现有恢复能力，二者内容均来自当前会话的已提交原文；恢复快照不表示写盘成功、不清dirty。NoteVersionManager最小增加captured source/revision和trigger接口，沿用既有目录/去重/清理；不新增独立崩溃恢复库。

### 7.2 离开前协调

增加统一 `EditingTransitionCoordinator`，用于换笔记、改名/移出当前文件、close 和正常 quit；在可取消阶段运行，而非仅 applicationWillTerminate/windowWillClose 最后兜底。

顺序：完成 composition→提交当前编辑→检查外部冲突/失败→flush→成功后离开。失败选择为重试、另存 Markdown 副本、明确放弃、取消操作；已有磁盘原文件不自动覆盖。“另存副本”后何时继续离开明确展示；不是用 try? 吞掉失败。失焦可尝试 flush，但不能替用户放弃草稿，也不强制弹不可取消退出。

进程内草稿保留至冲突已解决或用户明确放弃。crash/强制 kill 无保证，本期不新增恢复目录；未来如做需另 Spec。

### 7.3 文件事件

watcher 的无本地改动 reload 用 session 全量替换 transaction、更新磁盘基线和 generation；有本地 dirty/CompositionDraft 时保留双方并阻止自动覆盖。记录 last successful disk digest，可用于识别自己写入事件；不宣称有三方自动合并。

rename/move 更新 canonical URL 并提升 generation，任务捕获的旧身份全部失效。Trash/删除后 session 不再写、取消在途 parse/upload/save；保留现有 retire/缺失文件拒写。版本恢复是显式 source replacement，有确认/冲突前置和 history policy，不直接 fill 旧 view。

## 8. 代码高亮、格式化与系统命令

### 8.1 原生高亮

`NativeCodeHighlighter` 输出 source UTF-16 token ranges 与样式类别，不输出被正规化的新正文。首批必须支持仓库现用 Markdown/fence 场景及 Swift、Objective-C/C/C++、JavaScript/TypeScript、Python、JSON、HTML/CSS、Shell、SQL、YAML；为每一类登记 corpus/支持 token 边界。不承诺完整编译器语义或 Highlightr 所有语言零差异，未知语言使用明确的 plain code 样式，文字与编辑行为完全保留。

Highlightr 的 code、language detection、HTML 标签间接入口全部退出后才删除包。代码编辑不能因高亮错误/大块而不可用；最长行/注释/string 容错有边界，后台结果按 revision 发布。

等待高亮期间保留 code 的基础字体、段落与背景；能经当前 patches 精确变换、且不涉及词法失效区域的旧 token 样式可暂留，修改区域或映射不明区域先用基础 code 样式，不把旧 offset 的高亮套到新文字。marked-text 区不更新属性。新结果只在 identity/revision/主题配置匹配时一次更新相关范围，不通过清空全文样式制造闪烁，也不提升正文 revision 或登记 undo。

### 8.2 原生 Markdown 格式化

替换 Prettier 的是显式 NativeMarkdownFormatter，不是 TypographyCleaner。当前源码调用清单为 `Controllers/ViewController.swift:43` 持有 worker、`Controllers/ViewController+Editor.swift:13/21/36` 创建/调用 Prettier、`:912/949` 的显式格式入口，以及 `Views/EditTextView.swift:385`、`Helpers/EditorMenuManager.swift:157`、`Controllers/ViewController+Editor.swift:1425` 的菜单/工具栏转发。当前定点搜索没有发现 HTML paste 或分栏切换直接调用 Prettier；实施和退依赖前再次检查全 callsite，不能将未知路径写成已存在。

定义与实现锁定 formatter profile：空白/空行、缩进、list continuation、table alignment 和既有方言；prose wrapping 默认 preserve。受保护 code/math/frontmatter/raw HTML/link destination/reference 值不得被普通排版规则改写。

formatter 是 parse-aware source patch，不 HTML round-trip。初始 profile `mdown-preserve-v1`：保留原有合法 list marker/编号、fence定界符/语言、标题写法和prose换行；新建普通list缩进2空格，已存在合法缩进不整篇强制替换；仅在显式Format中把受支持table单元格边缘统一为1空格、对齐线最少3字符并保留colon；受保护块字节不动。空行/尾空格仅在确认非hard break、非code/HTML/metadata后处理，规则必须列入golden corpus；不能把未定义规则交给实现者随意格式化。

保持语义等价，第二次 format 结果相同；未知语法不理解时保持原文并报告范围，不默默删除。测试 comparison corpus 包含旧 Prettier 的固定输入/输出，差异登记为有意变化，不能在删包后才发现功能退化。

提交 snapshot revision，与当前不同则拒绝结果且提示重试；取消不写正文；完整一次 format 可 undo/redo，菜单名称与 public selector 保持兼容。不增加 format-on-save。

### 8.3 命令、查找与原生服务

command adapter 接 toolbar、First Responder、TextFormatter、templates、TOC/Wikilink、preview task intent。每个命令要么转换为 source transaction，要么“提交→转 source 并定位→执行同语义”；映射不成立则中止，不改隐藏 view。

find/replace 在权威 source 上，结果投影到 display；不能直接把 rich 的文字位置用为源码位置。用户选择“可见文本查找”时结果仍具 source anchor。replace-all 一个原子事务、可撤销。

字数与 spell/auto replacement 读快照，marked text 时不抢候选；code/math/URL 区自动替换关闭或遵循 source policy。typewriter 按 native caret 的可见行居中，focus 对当前块降噪，均只改 view state，布局改变有稳定滚动锚。

## 9. renderer 与导出边界

renderer input：session identity、blockID、source revision、render configuration generation、source/fingerprint、size/font/theme。结果：ready artifact 或明确 error/timeout/cancelled。代码 renderer 已原生；公式/Mermaid/PlantUML 可保留原服务，但 input/undo/source patch 全在原生局部编辑面。

保留 JS 的交互只能发送已登记块的有限 intent，例如 toggleTask；必须由原生校验 displayed identity、revision、block/source span 再生成原生命令。不得接收任意全文/任意 source replacement。若 intent 不能安全定位，preview 控件保持只读并引导活动原生编辑面，不继续旧 checkbox 按全局 Note 与序号写。

导出 job 固定 source snapshot 和格式/资源状态，准备/取消/失败不改正文/模式/undo；必要 UI 恢复不由独立 job 操纵。图片/字体/公式/图表等待显式结果，固定 sleep/didFinish/存在SVG不是成功证明。

整文 PDF 检查中文/emoji、可搜索复制、链接/outline、页码/页眉页脚、分页；单 Mermaid PNG/SVG 沿用旧 D 门槛，复用已存在 RenderedBlockExportController。

native rich 的单块导出供给不依赖主预览 DOM 或可见视口：用户通过某个已登记 block 的原生菜单/键盘动作发起，协调层捕获该块 source snapshot 与身份/配置。已有同 fingerprint 的 ready artifact 可复用；仅源码态、屏外未渲染或缓存未就绪时，由 MarkdownBlockRenderAdapter 按需在隔离的只读渲染宿主加载现有本地 renderer，显式等待本块、字体与资源完成，再产生已有 RenderedBlockSnapshot 所需的静态 SVG/HTML、完整尺寸和能力。不是把原文当最终静态 SVG 传给现有 exporter，也不强迫展开、滚动主编辑面或修改全局模式。

按旧 D 合同先完成只读预检，再显示保存面板；最终冻结前 source/block/config 已变化则取消，冻结后 exporter 仅使用静态快照独立完成。失败/超时不生成错误图；请求取消后关闭本任务渲染宿主、清理本任务产物，不能清空共享缓存。表格/普通图片不因这条数据路径自动扩入导出范围。需新宿主时仿照既有公开 AppKit/WKWebView 能力并做可见性/字体验证，不假定无头 WebKit 一定能产出有效图形。

Pandoc 仍是可选高级导出依赖，不自动安装；如改 Process 必须并行 drain stdout/stderr、退出码、超时和取消。

R2 全 renderer 原生化必须另建语法/布局/字体/尺寸/离线 corpus，尤其 Mermaid/PlantUML 全图种与 raw HTML；仅移除文件不能宣称实现等价。

## 10. 兼容、视觉与性能

| 场景 | 拟定验收预算/策略，不是已测结果 |
|---|---|
| ≤200 KiB、≤2,000 行进入 native rich | p95 首个可编辑画面 ≤300 ms；超过100 ms 显示轻量状态，不阻塞窗口 |
| 同步输入处理 | p95 ≤16 ms；派生样式 p95 ≤100 ms；IME 不等待完整 parse |
| 延迟/乱序 parse | 注入200/500 ms；连续输入不漏/不重，停下后最新投影 p95 ≤1 s 收敛 |
| >1 MiB、>5,000 行或单段>64 KiB | N1 明确回 source；不复制 Typora 清空正文/拒载；N2 再按实测扩大rich范围 |
| 1/10 MiB压力、块密集 | source 可编辑/保存，renderer受限；记录内存/输入/撤销/切模式，不在未测时保证rich全性能 |
| Undo 内存 | 用明确的内存/历史限制与测量，不复制160权重；不得裁掉当前 dirty 原文或跨note历史 |
| macOS | TextKit1/11.5 API基线 + 当前新系统；无法实测11.5时列未验证，不能宣称覆盖 |
| App Store | 原生系统面板与现有授权；不扩 ATS、任意文件权限或私有 WebKit API |

不以“没有 JS”“原生字体”替代性能和视觉测量。保留 Mdown 既有配色、字体设置、侧栏和菜单，native rich 的行距、marker、caret、列表/表格间距可对照 Typora 操作结果；不改整套视觉基线。图/表/video/iframe 最大宽度100%，不引入横向整体溢出；长 code 横向策略局限 code 面。

VoiceOver 能读正文、结构和控件状态，键盘可达任务、链接、table、raw block入口；focus/mode changes 不抢 title/search 焦点。文案新增 English fallback 与 es/ja/zh-Hans/zh-Hant；菜单的 storyboard ObjectID 本地化同时补齐。

## 11. 接口与依赖退役

正式组件：`Business/MarkdownEditingSession.swift`、`Business/MarkdownEditTransaction.swift`、`Business/MarkdownEditorHistory.swift`、`Helpers/MarkdownSourceMap.swift`、`Helpers/LosslessMarkdownParser.swift`、`Helpers/MarkdownProjectionBuilder.swift`、`Views/RichMarkdownTextView.swift`、`Helpers/MarkdownEditorCommandAdapter.swift`、`Controllers/EditingTransitionCoordinator.swift`、`Helpers/NativeCodeHighlighter.swift`、`Helpers/NativeMarkdownFormatter.swift`。辅助 table/raw editor 按原型需要增加，不新建平行全局状态。

修改 host、mode、生命周期、watcher、attachments、preview intent 与 formatter/highlighter 的接线范围见 PLAN。新 Swift/test 文件必须注册经典 pbxproj 四处，renderer 资源不能误删或误加到 iOS。

N2 退役检查：

1. Vditor view、message handler、editor.html 与专属 vditor 资源退出；保留布局 raw value和public storyboard selectors。
2. Highlightr/Prettier imports、instances、直接/间接调用退出；Package.swift、两个 Package.resolved、pbxproj build/product/package refs清理，只动本任务包，不顺手升级其他pin。
3. 不删除 preview 的独立 highlight/Mermaid/KaTeX/Reveal资源；保留JS清单明确标为renderer用途。
4. 新构建产物和真实typing/format/highlight/save路径证明没有编辑JS调用；Apple WebKit自身JSCore依赖不等于业务编辑仍使用JS，不能用otool单一框架名判定。
5. 旧 Vditor 测试替换为native行为测试，不能只删断言后通过；原生退依赖验收同时检查行为与产物。

source是永久兼容路径；选择native rich发生失败可无损回source。稳定门通过前Vditor仅作为开发期明确的legacy backend，不与native同时发布正文。N2最后移除后回退到source或上一已授权构建，不重新安装依赖或回滚用户文件。

## 12. 验收矩阵与完成定义

所有验收初始 `not-run`，测试存在、工具成功或模型自报不计pass。每项记录版本、输入、source前后、selection/undo、实际输出或测量，以及遗留差异。

| 验收ID | 场景/明确通过条件 | 需求 |
|---|---|---|
| AC-01 | 基础正文点击直接编辑、inline命令/marker affinity、heading split；不是纯样式隐藏 | NE-05,NE-06,NE-08 |
| AC-02 | CRLF/BOM/no-final-newline/frontmatter/ref/unknown，20次无操作模式切换hash不变；局部改一词未改片段相同 | NE-03,NE-04,NE-12 |
| AC-03 | 拼音/日文候选start/update/commit/cancel、块边界/表格/code、组合期间切换；不吞字/不重排候选 | NE-13,NE-14 |
| AC-04 | 延迟与乱序parse期间连续输入不漏重；stale结果丢弃、最新projection收敛 | NE-04,NE-16,NE-27,NE-30 |
| AC-05 | typing→格式→分块→切source/rich→undo至原文再redo，结构/selection恢复；换note不共享历史 | NE-08,NE-14,NE-15 |
| AC-06 | 三层list/quote/task，Enter/Tab/退级/跨项删除、plain/Markdown paste与转义一次事务 | NE-07,NE-08,NE-21 |
| AC-07 | A编辑→preview B→rich B→Cmd+S/关窗/退出；同owner旧source/formatter/upload均不能回写 | NE-02,NE-16,NE-17,NE-18 |
| AC-08 | note消失/Trash/重命名/同URL新实例/版本恢复；旧generation失效，不复活删除文件 | NE-16,NE-19,NE-20 |
| AC-09 | 写失败/dirty外部修改期间换笔记、close/quit：重试/另存/放弃/取消有结果；失败不报保存 | NE-17,NE-18,NE-19 |
| AC-10 | 原生paste/drag image/link、文件失败/切note/原anchor删；引用和i/文件归属正确 | NE-21,NE-22 |
| AC-11 | table cell输入、IME、Tab/ShiftTab/Enter/softbreak、行列移动、pipe/code/links，操作完整undo | NE-09,NE-13,NE-14 |
| AC-12 | native code editor、嵌套fence/string/Unicode/超长块、高亮token原文不变；等待时保留有效code样式、改动区不套旧offset、marked区不改属性，未知语言可编辑 | NE-10,NE-26,NE-30 |
| AC-13 | math/diagram/source-render/errors、旧revision/主题结果拒绝，错误块不阻塞编辑保存 | NE-11,NE-16,NE-28 |
| AC-14 | finder/replace-all、TOC/Wikilink/templates/toolbar/FirstResponder只改当前session；preview task intent不串write | NE-23,NE-24,NE-28 |
| AC-15 | formatter profile golden、语义与保护区不变、幂等/完整undo，运行中继续input/undo/cancel拒旧结果 | NE-15,NE-16,NE-25 |
| AC-16 | source/rich/split/preview/presentation/PPT退出回原布局，legacy pref迁移、空note/Trash/降级正确 | NE-01,NE-18,NE-36 |
| AC-17 | font/theme/zoom/focus/typewriter、spell/code替换、VoiceOver/键盘，切换不改dirty/history | NE-32,NE-33,NE-37,NE-38 |
| AC-18 | snapshot HTML/PDF/单块PNG-SVG、CJK copy/search/link/outline、资源timeout/cancel/写失败；native图表仅source态/屏外无cache/未创建主preview仍可隔离供给，编辑scroll/selection/hash不变 | NE-28,NE-29 |
| AC-19 | 200KiB/2000行预算与1/10MiB压力、trace/内存、旧系统API与实际Sandbox/iOS读取 | NE-30,NE-31 |
| AC-20 | 源码callsite/工程/产物/实机证明三依赖移除，renderer允许列表不被误删 | NE-26,NE-25,NE-34 |
| AC-21 | 官方Typora场景结果逐项登记，intentional差异与unknown不计同等性；所有支持项目有证据 | NE-35 |
| AC-22 | 每一来源commit/版本snapshot来自同一session，无新保存定时器；增量mirror即时dirty，旧generation同数字revision写结果不能清新dirty，exit风险与rollback实测 | NE-02,NE-17,NE-18,NE-36 |

**G0：**AC-01–AC-05的段落/行内/跨块与history原型、AC-06的三层list拆合原型通过；NE-08此时只验证基础结构原语，混合语法完整集由T12完成。增加段落→code→最小table子视图的selection/focus/IME探针，证明可选投影架构无需N2整体重写。AC-19在此仅采用200KiB/2k行性能和macOS11.5 API可用性，Sandbox授权/iOS读取/全压力集留T20/T21；不接主保存路径。

**N1：**AC-01–AC-10、AC-14、AC-16、AC-22与兼容基本集通过，可选原生模式。**N2：**AC-11–AC-20补齐，AC-01–AC-10回归，无编辑JS依赖。**P-Gate：**全部适用AC与NE覆盖，AC-21明确对照和差异；无owner/IME/丢内容/输出错误阻断。R2不计入N2，但renderer保留必须披露。

Mdown 的 source/保存无损/跨模式历史合同强于当前Typora静态样本的内部行为时，以本Spec为准并登记有意差异；不为了“完全一样”复制清历史、拒载置空或宽文件授权。

## 13. 证据、文档与发布

复用 [研究 fixtures](../typora-research/fixtures/README.md)；实现阶段新增model/IME/table/lifecycle/format/highlight corpus和实际记录，原始研究样例保持不变。不使用用户私密笔记；官方包获取/启动/输入均在实施授权范围内安排，本轮不执行。

基线build/tests、阶段XCTest、实机IME/UI、文件/导出检查、性能trace、Sandbox和旧系统覆盖分别报告。不能绿色build代替实机；缺环境/设备明确未验证。新source超过100行或行为风险高，先有失败测试/可复现输入再实施。

更新产品README、ARCHITECTURE、DEPENDENCIES与必要的agent guide，使其描述最终实现；旧“未实施W线”加新主规格链接和历史状态，不篡改D要求。营销不得把N1说成N2或把N2说成整应用零JS。source仍为默认，native rich最终替代现有wysiwyg选择，改默认另需具体决定。

最终所有代码经开发分支、review与相关检查；本Spec/Plan不授权commit/push/merge/tag/App Store或直接下载发布。完成状态以对应门的实际证据为准。
