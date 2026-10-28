# Typora JS 编辑模型与原生重建要件

状态：2026-10-14，静态定义与调用跟踪；未运行输入法、编辑或模式切换场景。目标 SHA-256：`745d737c75397a1424e6211a8a9523349ecae5267f39e4a516790ac7f9cfeee8`。本文给出行为职责和证据位置，不把恢复的 JS 引入 Mdown。

## 1. Bundle 形式与坐标

`appsrc/main.js` 是 **SystemJS Builder SFX**：86 个 `registerDynamic` 模块，入口 `a`；不是首轮报告所称 webpack。`page-dist` 是另一组页面 bundle，不能由它推断 main.js 的形式。

下表“注册偏移”是原文件的 **UTF-8 byte offset**，从 `registerDynamic` 的 `r` 起算；若从 `$__System.` 起算会早 10 bytes。函数级位置也统一为 UTF-8 byte offset。Python 的字符索引、UTF-16 code unit、grapheme 是不同坐标；本文件有 1,634 个增补 Unicode codepoint，不能声称字符索引约等于 UTF-16。

| 模块 | 注册偏移 | 查实角色 |
|---|---:|---|
| `a` | 1637691 | 入口，挂载 editor/getMarkdown |
| `5f` | 1568876 | Editor 装配、输入事件、reset、syncChange/applyChange |
| `13` | 1204510 | Node、NodeMap、类型、pool 与关系恢复 |
| `19` | 879142 | MarkParser，整篇/块级 parseFrom 与 renderHtmlWithBlockMeta |
| `12` | 24901 | Node.toMark / NodeMap.toMark |
| `14` | 35745 | Node 到 HTML |
| `1a` | 43440 | 节点拆分、breakOn 等结构动作 |
| `1b` | 1136192 | UndoManager、快照聚合、命令执行与 JSON 历史 |
| `32` / `1d` | 521064 / 830158 | Selection 与 Rangy |
| `49` / `20` | 397741 / 943931 | SourceView 与 CodeMirror |
| `18` / `1c` / `15` / `17` | 78906 / 1108725 / 1126689 / 1154884 | fence、数学、图表、HTML 块 |
| `58` / `57` / `59` / `55` | 728647 / 650274 / 668845 / 633247 | 表格、删除、输入/粘贴、缩进 |
| `3d` / `36` | 272681 / 190837 | File 内容主控与 unsupported/Oversize 状态 |

完整索引在本机 `research/editor-model/modules_index.json`，聚焦报告为 `finding-report.md`、`NOTES.md`；本文已修正中间笔记的坐标与同步条件误读。`research/js-final-anchors.json` 是父会话对关键定义重新核验的 byte offset 和短摘录。

## 2. 文档结构与显示身份

模型的基本关系为属性 bag、`before/after` 双向链与 `parent/children` 树。Node 分配递增 `n...` ID，pool 建立 ID 到节点的关系；DOM `[cid]` 与模型 ID 相连。NodeMap 保存结构、引用集合和恢复关系，并非只包一份 HTML。

块级类型包含 paragraph、heading、blockquote、fences、hr、def_link、def_footnote、table、raw_edit、meta_block、math_block、html_block、list、toc、iframe；子节点含 list_item、table_row、table_cell、alert_title。行内类型含强调、代码、引用链接、脚注、图片、数学等。类型存在不代表每一种语法的完整运行支持已经验收。

加载路径：File 读取内容 → `Node.parseFrom` → Editor.reset → 块模型生成带 metadata 的 HTML → 挂入 `#write`。macOS 内容可从原生 Document 取得，其他宿主存在 fs 路径。

定义锚点：

- `Node.parseFrom`：module 19，byte `899801`，创建 raw_edit 节点并解析；另有 prototype parseFrom 处理已有块。
- `renderHtmlWithBlockMeta`：module 19，byte `927648`，按节点类型和子树生成视图。
- Node pool：module 13，byte `1205732` 附近。
- `NodeMap.restoreFromJson`：module 13，byte `1218764`，读取 blocks 与 before/after 关系重连。

父子、兄弟、稳定块身份分别服务结构操作、选择和局部刷新。Mdown 可以使用自己的稳定 block ID 与原文区间，无需复制 Typora 的 CID 格式。

## 3. Markdown 不是从任意 DOM 直接保存

`Editor.getMarkdown` 位于 module 5f，byte `1629386`：源码模式读取 CodeMirror；渲染编辑模式调用 `nodeMap.toMark()`，再通过 `warpContentWithOption` 处理换行/末尾换行。

`Node.toMark` 位于 module 12，byte `25080`，按节点内容生成 Markdown、根据 File.useCRLF 连接，并清理内部哨兵。该模块还有列表、表格对齐等序列化逻辑。File.sync 则先把活动块/CodeMirror 编辑值同步回模型，再产出 Markdown 并交给原生 content。

因此三个职责需要分开：原文 parser、块模型 editor、Markdown serializer。当前跟踪未发现 markdown-it/mdurl/StateCore 等标记，实际 parseFrom 定义在自有 MarkParser 模块；不靠词频认定它用了 markdown-it，也不以有限负搜索证明整个软件永远不含该库。

**Mdown 设计取舍：**即使 Typora 的结构序列化会正规化原文，Mdown 既有 SPEC 要求更严格的最小 source patch 与无操作 hash 不变。建议保留原始 slice/定界符与显示映射，仅修改对应范围；这是 Mdown 的无损合同，不能假称 Typora 已逐字节满足它。

## 4. 选择与源码定位需要多种坐标

module 32 的 Selection.buildUndo 会依据上下文生成不同快照：

- 普通块：cursor、id、start/end；块内 offset 来自 Rangy bookmark。
- 跨块：startId/endId 与对应的选区信息。
- CodeMirror：块 id、pos、selections。
- 整篇源码模式：pos、inSourceMode。

SourceView（module 49）进入源码模式时沿 before/parent 累加块的 `ahead`，再按类型修正定位：fences 使用 CodeMirror 行列；math/html 需要编辑面偏移；table cell 用前置格匹配；引用定义和 metadata 各有规则。回到渲染态则按节点行数查块，再定位字符、table cell 或进入 raw block 编辑面。

源码到 DOM 的映射不是统一的一个 offset；ahead、cursorDiff 和所有语法的标定算法尚未逐行展开。原生模型需显式区分 source UTF-8、source UTF-16、display UTF-16、块内坐标与 grapheme 边界，不能直接复用 HTML `data-sourcepos` 或现有 `.count` 修正。

`md-expand` 从操作上下文看是标记/编辑展开态，不能通用地定义成“文档折叠块”。后续标记显隐、点击 affinity 和跨块拖选仍需官方基准实机对照。

## 5. IME 有专门事件路线

module 5f 查实的事件锚点：

| 定义/注册 | UTF-8 byte offset | 观察 |
|---|---:|---|
| keydown 的 `229 !=` 条件 | 1596631 | 组合输入相关 keycode 分流，不进入同一套普通快捷键处理 |
| compositionend 注册 | 1602805 | 结束后按模型/DOM 状态处理刷新和 ADD 快照 |
| compositionstart 注册 | 1602828 | 预备当前节点并设置 IME 状态 |
| beforeinput 注册 | 1602890 | 区分 composition、paste/drop 与普通 replacement/delete |

具体 handler 中有 compositionstart 的 prepNode/isIME、compositionend 的 useIMEKeyboard、模型/DOM 漂移恢复、延迟 brush 与 ADD snapshot；beforeinput 对 deleteCompositionText/deleteByComposition 做专门处理，并对含换行的 composition 有短时锁定。

这些是实现存在的证据，不能宣称其在所有输入法上正确。**原生要件：**marked text 优先，候选 Enter/Tab 不被块导航抢走；组合期间不重建 textStorage 或重排当前选区；组合提交、取消与撤销各有真实 IME 测试。程序化插入最终中文不覆盖候选组合路径。

## 6. 输入与结构动作

普通 Enter 的路径进入 pressReturn，再按段落、引用、列表、表格、fences 等分发；插入和删除由 UserOp 门面接结构操作与历史。Backspace 需要判断块内、块首和跨块选区，再生成 replace/合并等事务。Tab 可以分派 CodeMirror 缩进、list indent、table navigation 或普通 tab。

主要模块边界已定位：删除 57、输入/粘贴 59、缩进 55、表格 58、结构拆分 1a。尚未将所有分支对应到可见操作结果，不在本轮锁死每个快捷键行为；详见 fixtures 中的 compare_in_typora。

**实现建议：**统一 EditTransaction，验证原文范围和 revision 后原子处理；格式、拆/合块和跨表格动作一次历史登记。不要让每个 block 子视图分别修改全文，也不要把 DOM 在输入后的样子当作唯一原文来源。

## 7. 撤销是结构命令，不只字符栈

module 1b 的命令保存 undo/redo 操作、source/date、cursorOnly/discardable 等信息。已观察的操作原语包括 cursor、fences-pos、replace、insert、remove、wrap、unwrap、attr、reload、initSrc、sync；replace/insert 等可携节点 JSON，重放时恢复结构和选区。

关键锚点：

- JSON 历史保存：byte `1136775`。
- register 中的 redo 分支和变更计数：byte `1137759` 附近。
- 历史权重超过 160 时裁剪：byte `1138500` 附近，reload 的权重在 busy mode 更高。
- undo 源码模式路由：byte `1139690`。
- addSnap：byte `1150108`；聚合条件 byte `1150214`，需 source 等于同一 `cid#flag`、距离 date 小于 3,000 ms，且 flag 不是 REPLACE。不能说所有动作都按三秒合并。

源码模式交给 CodeMirror undo/redo，SourceView.show 还会 `clearHistory`（module 49，byte `403245`）。这证明样本有两套历史/切换边界，不等于它实现了跨模式统一历史。Mdown 既有 SPEC 要求跨视图语义 undo，不应直接照搬 clearHistory。

历史持久化由 JS 生成，原生 DocumentSnap 接收 nodeMap、undoRedo、srcHist 等备份，详见 [NATIVE.md](NATIVE.md)。原生会话重建需统一历史 owner、selection before/after 与原文事务，避免 AppKit undo 与模型历史重复登记。

## 8. 复杂块有独立编辑面与延迟渲染

- Fences（18）：按 cid 管理 CodeMirror 实例，change 把 code text 写回模型，删除/离开前有 sync/cleanup。包含懒渲染与 IntersectionObserver 路径；没有测量性能收益。
- MathBlock（1c）：进入编辑态建立 stex CodeMirror，`md-rawblock-on-edit` 表示 raw block 正在编辑；离开后同步原文再转渲染容器，并登记位置/历史。
- Diagrams（15）：读取主题变量、处理 preview 与 Mermaid 导出主题；vendor renderer 的完整调用与图种兼容未展开。
- HTMLBlock（17）：单独源码/预览入口；其执行/沙箱策略未在本轮完整审计。
- TableEdit（58）：单元格身份、行列关系与导航，与普通段落选区有不同规则。

Mdown 的 block renderer 应只接受不可变源码和 revision，不拥有文档；错误渲染也必须可返回原文编辑。所有语言、公式和图表语法兼容是单独的 corpus，不由“有模块”自动通过。

## 9. 多窗口增量与全量同步

`Editor.syncChange` 位于 byte `1632068`：过滤 fences 类型，macOS 把命令 JSON 交给 `document.syncChangeIfNeeded`；回调为真时调度 `scheduleFullContentSync`。全量调度使用 500 ms 延迟，**不是失败才调度**。

`Editor.applyChange` 位于 byte `1632431`：空输入或活动窗口时退出；其他窗口逐条 exeCommand，需要时 refresh。payload 可携 html/allHtml/cmChanges/tex/srcChanges/content 等 sync 子内容。该 JS 路径与原生 `Document.syncChange:` 的非活动窗口广播相互印证。

建议在 Mdown 用 revision 驱动会话、视图与预览，不照搬无 revision 的跨进程命令串；错误的旧 parse/render/formatting 结果必须拒绝发布。

## 10. 三类阈值不能混为一谈

| 机制 | 样本静态条件 | 作用/限制 |
|---|---|---|
| File.MAX_FILE_SIZE | `2e6`，byte `273524`；比较 JS string.length | UTF-16 code unit 数，不是 2 MB；超过阈值进入 unsupported/Oversize |
| tryEnterOversize | byte `204524`；强制标志或 length 超限，mac 未保存新文档有豁免 | 显示占位，返回空渲染内容；相关 save/sync/计数/快照路径受 unsupported 门控 |
| tryEnterBusyMode | byte `1574015` | 使用 IME 或 mac：文本超 35,000；其他超 60,000；另有模型节点/HTML 长度和 img/svg/CodeMirror 加权条件 |
| undo 裁剪 | 权重超过 160 | 缩短历史，不是正文拒载或 renderer 模式 |
| Library list oversize | 列表抓取上限相关 | 侧栏文件列表状态，与编辑器大文档机制无关 |

busy mode 入口会改变 contenteditable 和 brush interval（500/200 ms），并依据 busyModeSource 决定退出；它不是简单停止实时统计。HTML 条件包括模型节点大于 10,000、HTML 长度及附件权重。运行时输入和退出效果尚未测量。

`doEnterOversize` 位于 byte `204250`，仅 Node 宿主且非广播时调用 document.addSnap。macOS 广播 `File.tryEnterOversize('', true, true)` 的第三参数标识广播来源，见原生证据。

Mdown 可以采用延迟渲染/增量 parse 维持大文档原文可编辑；不应无测量地复制拒载阈值或清空投影，也不能把 unsupported 路径写成正常降级编辑已通过。

## 11. 仍需补证据

- 原文片段、Node.storeToJson 全字段、inline parse 规则和哨兵所有注入点。
- ahead/cursorDiff 的精确标定、跨块方向与双向光标 affinity。
- paste HTML/Markdown/plaintext 全路径和 CJK 候选实际效果。
- busy mode 的全部退出条件、定时器竞争与实际输入体验。
- 图表/MathJax vendor 的完整支持、错误和资源就绪合同。
- 官方原包在同样输入序列下的文本、选区、历史、视觉与性能结果。

这些缺口作为 PARITY 的待测项；本轮不宣称整个 main.js 已完全理解或本地版本已实现。
