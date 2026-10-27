# Mdown 原生 Typora 式编辑器 Implementation Plan

> 执行说明：按照 [SPEC.md](SPEC.md) 的合同分阶段实施；后续编码使用当前宿主实际可用的执行计划能力。每个任务先证明失败、实现最小路径、回归并记录证据。本文件不自动授权提交、推送、发布、安装工具或更改权限。

**Goal:** 将 Mdown 的 Markdown 输入、选择、结构编辑、撤销、代码高亮、格式化与保存迁到 Swift/AppKit，最终移除 Vditor、Highlightr 和 Prettier 编辑依赖，按固定场景对齐 Typora 行为。

**Architecture:** 未预处理的 MarkdownEditingSession 原文与 source transactions 为权威；source/rich 视图共用身份、revision、selection 和语义历史。TextKit 1 负责系统文字输入和显示，后台解析/渲染/导出读取不可变快照；Note 保存与版本服务继续复用。

**Tech Stack:** Swift 6、AppKit/TextKit 1、macOS 11.5、CMarkGFM 1.0.2、XCTest、PDFKit/CoreGraphics、现有只读 renderer。没有 JS 编辑后端替代路线；TextKit 2、外部 parser 与全 renderer 原生化不自动加入。

基线：`main@b8110a942e27ae13ebe531b549a56e5a220f91ae`，`/Volumes/external/Projects/Mdown`。本轮仅编写规格。执行前重查 HEAD、dirty changes、实际依赖和运行状态，保护现有 `specs/typora-research/`；不直推 main/master，不覆盖他人修改。

## 1. 阶段图、顺序与交付门

```text
T00 基线与固定corpus
 ├─ T01 当前Vditor/保存风险复现、窄修复
 ├─ T02~T04 source patch/map/原生投影原型 → G0
 │    ├─ 失败：记录最小复现、保留当前已验证source；继续独立D线
 │    └─ 通过：T05会话正式化 → T06历史 → T07~T09保存/生命周期/外部版本
 │              → T10布局接入 → T11正文/行内 → T12列表/输入 → T13剪贴板
 │              → T14命令/预览意图 → N1
 │              → T15代码/高亮、T16表格、T17复杂块、T18formatter
 │              → T19focus/typewriter/系统服务 → T20snapshot导出
 │              → T21全面回归 → T22退依赖 → T23行为对齐/文档 → N2/P-Gate
 └─ 既有D线：核验RenderedBlockExportController → 单Mermaid独立交付

R2 全renderer原生化：独立后续计划，不纳入本次N2退编辑依赖门
```

顺序约束：G0 是可丢弃原型，不将未通过的投影接到正式保存。T05正式源码会话可先稳定，rich正式接入在T10后。N1是可选基础原生模式，N2才包括table、native highlighter/formatter和最终去依赖。任意G0/N1困难不阻塞旧D线；同一project/host改动由集成人串行写。

实施先保护现有数据，再做新交互。T01是已有明确风险的复现/窄修复，不以它为契机改整个文件系统。每任务代码改动>100行或高风险必须先具有效测试/复现；表中的真实IME、视觉和Sandbox不能用单元测试替代。

## 2. 统一执行与证据规则

每张任务卡按下列步骤执行；具体失败断言和退出门写在卡内：

1. 读取列出的源文件/合同，核验本阶段依赖与dirty changes。
2. 创建最小失败测试或可重复UI输入；运行并确认它因目标行为失败，不是因fixture/target接线错误。
3. 只实现该卡所需路径，注册新增文件；不借任务重写Note/Storage/全部菜单。
4. 跑本卡窄测试；有UI/IME/导出时执行实际应用路径，再记录source、selection、文件或测量结果。
5. 检查owner/revision/错误与取消；记录pass/partial/blocked，不留静默fallback、空catch或假通过。
6. 对已有PR/开发分支形成可审查diff；commit/push仍依当前授权，不能因计划自动执行。

验收记录建议放 `specs/native-typora-editor/validation/<阶段>/`，使用自编测试输入，不保存用户正文、私人路径、token或系统字体资源。若含大型录像/二进制产物只记录受控本机路径与SHA，不把依赖产物/恢复Typora代码引入repo。

## 3. 任务卡

### T00 — 基线、语法与行为 corpus

**依赖：**无。**需求：**NE-03,NE-31,NE-35。**验收：**AC-02,AC-19,AC-21。

**Files：**读 `AGENTS.md`、`ARCHITECTURE.md`、`Package.swift`、两个Package.resolved、pbxproj、scheme；新增 `MdownTests/Fixtures/NativeEditor/` 与 `specs/native-typora-editor/validation/BASELINE.md`（执行时）。复用研究fixtures，保持原始hash不动。

- 记录baseline macOS build/tests及已有失败，不顺手修无关项；既有源码/Vditor/preview模式均实际打开。
- corpus涵盖UTF8 BOM、LF/CRLF/混合行尾、无末尾换行、tabs、组合重音/emoji、metadata/ref/footnote、三层list、table含pipe/code、nested fence、错误math/diagram、HTML/unknown、200KiB/2k行和1/10MiB压力样本。
- 官方Typora基准核验来源、签名、版本/构建、font/theme/window/locale/IME。当前Antibiotics副本仅静态定位，未建立官方身份；不自动下载/启动新样本。
- 固定按键/选择/复制/模式/undo/export输入序列，输出是source/selection/viewstate和文件，不仅截图。
- 记录当前Vditor的plain/Markdown paste、table导航、字符输入与已有Prettier golden作为迁移baseline；标未知不强造期望。

**退出门：**样例hash和步骤固定、baseline失败有位置与根因或待证假设；官方样本缺失不阻止原生原型，但AC-21不能计pass。

### T01 — 复现并隔离当前 Vditor 与保存桥风险

**依赖：**T00。**需求：**NE-16,NE-17,NE-18,NE-36。**验收：**AC-07,AC-09。

**Modify：**`Resources/DownView.bundle/editor.html:146`、`Views/VditorEditView.swift:108/164/188`；仅必要的 `Controllers/ViewController+Action.swift:1618`、`Controllers/MainWindowController.swift:265`、`Controllers/AppDelegate.swift:157`。**Test：**扩展 `MdownTests/VditorIntegrationTests.swift`，新增 `MdownTests/VditorBridgeContractTests.swift`；扩展 `MdownTests/EditorStorageOwnershipTests.swift`、`MdownTests/NoteSaveDebounceTests.swift`。

- 先运行setMarkdown→用户edit→vditorChange→Note.content→实际磁盘flush，证明setter callback错配；按随包clearStack boolean API修复，loading flag用有界真实完成逻辑，非固定长sleep。
- 测A→B load/pending ready/晚消息，捕获owner/generation；早期补note identity字段，不能所有消息套currentNote。
- 单独复现同owner旧source在Cmd+S/close/quit的回写，以及Vditor外层0.5s未置dirty的空窗；最小临时adapter只从active editing backend获取/flush，不引入新session/transition状态机。若正文风险已复现，允许对这几个生命周期入口作必要窄修复，不能为避免返工而留下丢数据路径。
- 该临时adapter明确标记为T05~T08待替换接口，T08由正式session/TransitionCoordinator收敛并删除临时分支；不可让两套保存逻辑长期并存。
- 把资源存在测试与真实输入/save测试分开；必须显式setup/fail，不能VC缺失直接return计通过。

**退出门：**明确症状有运行证据；修复回归证明source/Vditor不串写、不丢最后输入。现有selector/default/renderer不改变。此阶段不宣称原生化。

### T02 — source patch 与 Unicode 不变量原型

**依赖：**T00，可与T01并行。**需求：**NE-02,NE-03,NE-04,NE-16。**验收：**AC-02,AC-04最小。

**Create：**`Business/MarkdownEditTransaction.swift`、`Helpers/MarkdownSourceMap.swift` 的独立原型（不接Note）；必要测试宿主。**Test：**`MdownTests/MarkdownEditTransactionTests.swift`、`MdownTests/MarkdownSourceMapTests.swift`。

- 依据SPEC值类型定义identity、source range、patch原子校验；多patch以同base、descending顺序应用。
- red cases：越界/重叠/旧expectedText/staleRevision/不同generation/同位置多insert；全部拒绝且source/selection/history无变化。
- UTF8/UTF16/grapheme/CRLF转换，禁止source patch切在代理对；用户字符删除按composed sequence边界，parser token操作另有显式规则。
- 使用真实UTF8 bytes/NSString范围交叉oracle，不能拿函数返回值互相断言。

**退出门：**原子性、Unicode、无操作hash和未改范围保持不变；所有失败有显式拒绝类型。组件不读用户库/renderer。

### T03 — lossless parse 与 display/source 原型

**依赖：**T02。**需求：**NE-03,NE-04,NE-05,NE-12,NE-27。**验收：**AC-01,AC-02,AC-04最小。

**Create：**`Helpers/LosslessMarkdownParser.swift`、`Helpers/MarkdownProjectionBuilder.swift`（原型）。**Test：**`MdownTests/LosslessMarkdownParserTests.swift`、`MdownTests/MarkdownProjectionTests.swift`、`MdownTests/MarkdownRoundTripTests.swift`。

- pinned cmark sourcepos/tab/end-column先用fixtures实测；原文未经preview stripping/protect替换，扩展保护必须同时生成逆映射。
- 保存token/source slices和delimiter，语义AST只是派生；frontmatter/ref/footnote留原文，不抽走权威source。
- segment含text/hidden marker/link target/code/attachment/metadata ranges，定义affinity、空块、跨格式选择、object replacement排除。
- tests：只改`**AB**`中B不删delimiter；escaped/unclosed marker保留；table/unknown保护；parse不确定→局部source而非错误whole serializer。
- 注入200/500ms/乱序parse，字符操作同步推进局部map，不让旧完整AST阻止下一字符。

**退出门：**映射可逆、片段无损且最新projection最终收敛；全部语法支持表和pending范围清楚，不宣称全CommonMark无损已通过。

### T04 — TextKit 1 / IME / undo 可行性门 G0

**依赖：**T02,T03。**需求：**NE-05,NE-06,NE-08基础原语,NE-13,NE-14,NE-15,NE-27,NE-30；NE-31在此仅API兼容探针。**验收：**AC-01~AC-05原型、AC-06三层list拆合原型；AC-19仅200KiB/2k性能和11.5 API可用性，不含Sandbox/iOS集成。

**Create：**`Views/RichMarkdownTextView.swift` 的隔离验证面；`Business/MarkdownEditorHistory.swift`最小原型。**Test：**`MdownTests/RichMarkdownEditingTests.swift`、`MdownTests/MarkdownCompositionTests.swift`；实机记录 `validation/G0/`。

原型用纯内存source/transaction协调对象，不访问Note/Storage；类型可先位于test宿主或隔离实验target。T05通过G0后收敛到正式MarkdownEditingSession，删除一次性协调对象，不能让原型与正式会话并行拥有source。

- 正文/heading/emphasis/task/一个image placeholder/受保护code可直接编辑，hidden marker不会每点击全段回source。
- 设置CompositionDraft，真实中文/日文start/update/commit/cancel，在inline边界/list/code内及菜单/切mode请求，保证未提交组合不whole-replace/改attributes。
- 使用AppKit input protocol与delegate；不把调用insertText(finalChinese)当IME验证，不调用discardMarkedText掩盖失败。
- 跨块鼠标/键盘选择、affinity和原文inverse transaction；基础Enter/Backspace/Tab及三层list拆合原型、同source/rich history完整undo/redo，完整混合语法矩阵留T12。
- 最小table（2×2）和code子编辑面探针：段落连续划选至code/table的source selection、first responder、IME与history可协调，证明单TextKit投影或独立grid可行；不要求此时完成行列操作。这项架构决定要记录，T16据此收敛实现。
- 200KiB/2k行的首帧/typing/style p95，录机器/配置；验证11.5 API可用性，无未保护TextKit2能力。真实Sandbox文件授权/iOS读取与全压力集留T20/T21，不在隔离原型冒充已测。

**G0通过：**相关AC逐项证据，真实IME和持续typing收敛；没有丢字/source漂移/history串写。**失败：**最小复现+trace，原型不挂默认保存；改模型/投影或缩小阶段边界需明确Spec变更，不偷偷换JS内核。

### T05 — 正式 MarkdownEditingSession 与源码接入

**依赖：**G0，T01。**需求：**NE-02,NE-16,NE-17,NE-22,NE-27。**验收：**AC-04,AC-07,AC-22。

**Create：**`Business/MarkdownEditingSession.swift`（API见SPEC）。**Modify：**`Views/EditTextView.swift:52/989/994`、`Controllers/ViewController.swift:1308`；`Business/Types.swift`仅新增必要session引用。**Test：**`MdownTests/MarkdownEditingSessionTests.swift`、扩展Owner tests。

- 先source模式接入，不显示rich；session保存raw source/revision/selection，Note仅commit snapshot。
- 编辑apply/noChange/reject遵守SPEC，改revision但不回退；same-owner旧buffer加storageRevision，publish标明当前rev，失效buffer不能whole-save。
- rebind/retire改变generation，兼容不同Note实例同URL测试通过明确重载/协调，不删除legacy允许行为测试骗通过。
- latest parse+attachment job snapshot进统一接口，不各存第二套source。

**退出门：**源码/分栏真实输入、owner/revision测试、旧buffer拒绝，无新save timer。示例失败断言见本Plan §5。

### T06 — 单一语义 UndoManager 与 composition 正式化

**依赖：**T05。**需求：**NE-13,NE-14,NE-15。**验收：**AC-03,AC-05。

**Modify/Create：**正式 `Business/MarkdownEditorHistory.swift`；`Views/EditTextView.swift:552`、`Views/RichMarkdownTextView.swift`、`Controllers/MainWindowController.swift:151`。**Test：**`MdownTests/MarkdownEditorHistoryTests.swift`、`MdownTests/MarkdownCompositionTests.swift`。

- source/rich/text subeditor路由同session Note.undoManager；view自动undo与session不得重复登记。
- snapshot before/after、inverse patches、redo截断；composition一次group，format/paste/table单独group。
- caret movement/selection change结束typing group；聚合时间策略固定记录，不盲抄Typora3s或Vditor800ms。
- parse/theme/render刷新history数不变；undo生成新revision，旧async task失效。

**退出门：**完整source/structure/selection回到起点并redo；切Note隔离、组合中命令延后，不能以canUndo布尔代替。

### T07 — Note commit、write outcome 与 dirty revision

**依赖：**T05,T06。**需求：**NE-17,NE-18,NE-20。**验收：**AC-07,AC-08,AC-09,AC-22。

**Modify：**`Business/Note.swift:557/565/592/602/626/683`、`Business/Storage.swift:1303`；即时save的 `Controllers/ViewController+Editor.swift:1047/1075`、`Helpers/ClipboardManager.swift:65/92/119` 一并接commit/outcome。**Test：**扩展 `MdownTests/NoteSaveDebounceTests.swift`，新增 `MdownTests/EditorCommitPersistenceTests.swift`。

- 最小新增save result/captured identity/generation/revision/digest与pendingWrite关联；只有当前完整三元组及正文摘要匹配的实际写成功才能清dirty。同URL重绑定后数字revision相同也必须拒绝旧完成。
- 使用Note既有debounce1.5s与即时dirty登记；新增最小patch/COW commit接口，增量更新Note已提交文本镜像，不在每字调用中整篇unLoad/扫描/重新构造attributed buffer。完整编码/FileWrapper在定时或flush捕获source snapshot后生成；兼容save(content:)转发当前协调层，不能新增外层timer或等timer才标dirty。
- 测分配/输入延迟与真实source mirror，不能只以COW推断无开销；压力时保持source可编辑，不能让Note/版本/预览读旧正文来换性能。
- UTF8 BOM/CRLF/no-final-newline通过FileWrapper再读实际文件；若BOM丢失，局部修document options或byte encoding path，不伪装只测memory通过。
- 删除/retire/缺失文件/rename race保留原子保护；保存版本/Wikilink只跟真实成功内容。现有导航/面板/恢复前快照另作local recovery trigger，保留政策且使用captured session source/revision，不冒充保存成功、不清dirty。
- `Note.save(globalStorage:)`当前Void丢弃即时write结果，需保持兼容入口并转发可观察outcome或新增result-returning API；所有已提交内容命令用可验证结果，不能只改debounced分支。

**退出门：**后台/模拟在途写rev1后rev2到达仍dirty；磁盘内容和persisted digest正确；失败不toast Saved、重试可以成功、不复活删除文件。

### T08 — 离开前 TransitionCoordinator

**依赖：**T07。**需求：**NE-13,NE-18,NE-36。**验收：**AC-03,AC-07,AC-09。

**Create：**`Controllers/EditingTransitionCoordinator.swift`。**Modify：**`Controllers/ViewController+Action.swift:1618/555/234/787`、`Controllers/ViewController+Editor.swift:1669/1692`、`Controllers/MainWindowController.swift:237/265`、`Controllers/AppDelegate.swift:157`、`Views/NotesTableView.swift:392/415`、`Controllers/ViewController+Data.swift:409/425`。**Test：**`MdownTests/EditingTransitionTests.swift`、扩展Note save/Owner tests。

- 抽active session finish-composition/commit/flush统一入口；Cmd+S/duplicate/失焦不采hidden buffer。
- close/quit的可取消前置（windowShouldClose/applicationShouldTerminate或等价公开AppKit）处理pending；willClose/willTerminate只最后兜底，不等到无法取消才提示。
- failed/conflicted提供Retry/Save Copy/Discard/Cancel并等待结果；Save Copy来自系统panel，确认成功后才允许相应离开。
- inject failure与CompositionDraft，note selection暂不切/close返回取消；Discard仅当前会话显式草稿，不删磁盘。

**退出门：**同owner/跨owner+0.5s旧空窗回归，最后输入不丢，失败可停留/另存、正常退出可取消；不新增跨重启恢复库。

### T09 — watcher、rename、Trash、版本恢复与异步附件

**依赖：**T08。**需求：**NE-16,NE-19,NE-20,NE-22。**验收：**AC-08,AC-09,AC-10。

**Modify：**`Helpers/FileSystemEventManager.swift:246~302`、`Business/Storage.swift:682/915`、`Business/Note.swift:211/229/519`、`Controllers/ViewController+Action.swift:234/284/787/807/1285`、`Controllers/ViewController+Editor.swift:1669/1692`、`Views/EditTextView.swift:504/505`、`Business/NoteVersionManager.swift:19`、`Controllers/VersionHistoryViewController.swift:482`、`Helpers/ClipboardManager.swift:44/178/413~443`。**Test：**`MdownTests/EditorFileConflictTests.swift`、`MdownTests/EditorAttachmentTransactionTests.swift`、`MdownTests/EditorVersionSnapshotTests.swift`；保留现有retire测试。

- watcher备份取session source；无dirty reload更新base/generation，dirty保留磁盘外部和本地两份，不直接清history/refill覆盖。
- rename/move/sameURLnewInstance重绑定身份；upload job保持request与source anchor，不按返回时currentNote/selection插。
- block anchor删除/映射不明结果取消；自建附件孤立清理沿用可恢复路径，无任意删除。
- 导航离开(`EditTextView.fill:505`)、打开version panel(`Action:1285`)、恢复前(`VersionHistory:489`)均捕获session提交原文，沿用force/dedup等原政策；注明local recovery trigger，与真实写盘保存版本区分。version restore通过显式replacement transaction与transition conflict前置，重新parse/历史策略明确。
- fileName/SaveTitle/Move/Note.move/overwrite成功后统一rebind generation，失败不先改URL；改名期间有composition/dirty/冲突按T08前置处理，不允许绕开coordinator直接moveItem。

**退出门：**外部modify/delete/rename+slowparse/upload/restore确定结果，不串note、不复活、无silent overwrite。

### T10 — 正式 Rich view host 与布局兼容

**依赖：**T09。**需求：**NE-01,NE-18,NE-32,NE-33,NE-36。**验收：**AC-16,AC-17基本。

**Modify：**`Controllers/ViewController.swift:93/1104/1279`、`Controllers/ViewController+Editor.swift:473/510/538/575/668/797/1470/1542`、`Controllers/ViewController+Layout.swift:269`、`Business/Types.swift:182/189`、`Helpers/UserDefaultsManagement.swift:855/893`、`Controllers/GeneralPrefsViewController.swift:313`、`Resources/Localization/Base.lproj/Main.storyboard`、四份 `Resources/Localization/{es,ja,zh-Hans,zh-Hant}.lproj/Main.strings` 与所需Localizable.strings。**Test：**`MdownTests/NativeEditorModeMigrationTests.swift`。

- native rich显式可选backend，共用layout source/split/wysiwyg；禁止并行两个backend publish正文。右侧split与纯preview明确保留 `Views/MPreviewView.swift`，接入 `Controllers/ViewController+Editor.swift:1131/1151` 的previewScrollView.documentView；只替换左侧Vditor编辑面，不新建平行预览类。
- raw pref不变，新用户source默认、legacy split迁移；失败仅当前note回source不写全局pref。
- ⌘3与Toggle Preview标签统一纯preview行为，wysiwyg独立菜单/设置；preview/presentation/PPT退出回saved layout；⌘0–5不新占。
- storyboard outlets/actions原样forward，不重排侧栏；theme/font/selection滚动锚在当前session映射恢复。

**退出门：**模式组合无白屏/零宽、无Note重复save，无选中/Trash/只读上下文可用状态正确；Vditor仍开发期legacy未删。

### T11 — 普通正文、行内格式与链接

**依赖：**T10。**需求：**NE-05,NE-06,NE-12,NE-14。**验收：**AC-01,AC-02,AC-05。

**Modify：**`Views/RichMarkdownTextView.swift`、`Helpers/MarkdownProjectionBuilder.swift`、`Helpers/MarkdownSourceMap.swift`、`Business/MarkdownEditTransaction.swift`。**Test：**`MdownTests/RichMarkdownEditingTests.swift`、`MdownTests/MarkdownInlineEditingTests.swift`。

- 段落/H1~H6/strong/em/del/code直接文字编辑；hidden marker affinity、未闭合/escape/softbreak的projection规则。
- inline styles用sourcepatch创建/移除delimiter，保护未选范围；link label与target独立，target编辑安全scheme，modifier+open与click-edit区分。
- reference/footnote共享定义保留原位，显式定位/编辑影响范围；未知raw syntax可编辑source，不删除。

**退出门：**真实点击/input/delete/format +source bytes与selection准确，不只snapshot属性断言；文字点击不全段切source。

### T12 — 输入规则、list/quote、跨块结构

**依赖：**T11。**需求：**NE-07,NE-08,NE-13,NE-21。**验收：**AC-03,AC-05,AC-06。

**Create：**`Helpers/MarkdownInputRules.swift`；必要 `Business/MarkdownBlockModel.swift`（派生，不权威source）。**Modify：**rich/command adapter最小连接。**Test：**`MdownTests/MarkdownInputRulesTests.swift`、`MdownTests/MarkdownListEditingTests.swift`。

- empty paragraph prefix转换、一键undo回literal；组合输入/粘贴/code/math不触发typingrule。
- Enter拆item、空项退级、Tab/ShiftTab、quote mixed list三层、task精确span toggle。
- Backspace/Delete/跨块replace生成原子sourcepatch；不确定结构安全source定位，不靠whole serialization修错。

**退出门：**输入矩阵全样本、至少三层mixed结构、边界undo/redo与停止输入收敛通过。

### T13 — 剪贴板、图片/文件附件与局部 raw 源码

**依赖：**T12,T09。**需求：**NE-10,NE-11,NE-21,NE-22。**验收：**AC-10,AC-12基本、AC-13。

**Create：**按需求 `Views/MarkdownRawBlockEditor.swift`（NSTextView）、`Helpers/MarkdownClipboardAdapter.swift`。**Modify：**`Helpers/HtmlToMarkdown.swift`、`Helpers/ClipboardManager.swift`、rich。**Test：**`MdownTests/MarkdownClipboardTests.swift`、`MdownTests/MarkdownRawBlockEditingTests.swift`。

- Copy Visible / Copy Markdown / Paste Plain / Paste Markdown明确；rich HTML转换仅现有结构门槛，code字面保留。
- picture placeholder/alt/title/paste drop sourceanchor与附件i/约定；failure不插空引用。
- native code/math/diagram局部source共享session/undo，不创建另一全文编辑器；source编辑后renderererror仍保留输入。

**退出门：**clipboard内容和文件副作用有实际检查，latejob/anchor删除/IME均不串write。

### T14 — 命令 adapter、find/TOC/Wikilink与 preview intent

**依赖：**T13。**需求：**NE-23,NE-24,NE-28。**验收：**AC-14。

**Create：**`Helpers/MarkdownEditorCommandAdapter.swift`。**Modify：**`Helpers/EditorMenuManager.swift:11/20/157`、`Helpers/TextFormatter.swift:27`、`Controllers/ViewController+Action.swift`、`Controllers/ViewController+Editor.swift:1047/1075`、`Views/EditTextView.swift:438`、`Views/MPreviewHandlers.swift:17/32`、`Resources/DownView.bundle/js/common.js:121/145`；只动自有JS不改vendor。

**Test：**`MdownTests/MarkdownCommandRoutingTests.swift`、`MdownTests/PreviewEditIntentTests.swift`。

- 所有content命令列registry：作用active session或安全source定位；不同坐标不直接调用TextFormatter旧NSRange。
- find/replace-all以source匹配并映射结果，一次可撤销事务；ref/metadata等不可见范围明确定位source。
- preview checkbox消息含displayed identity/render generation/revision/block与预期state，native验证后生成toggleTask；不接受full Markdown/mutable ranges任意消息。不能安全定位时readonly提示，不删原有能力无说明。
- 过期preview、伪造container/rawHTML、子frame不能写当前note。

**N1门：**AC-01~10、14、16、22适用集，基本compat/UI通过，正式可选native基础；公开说明table/特殊扩展暂局部source，不声称N2/零JS。

### T15 — native fenced code 与 Highlightr 替代

**依赖：**N1。**需求：**NE-10,NE-26,NE-30。**验收：**AC-12,AC-20前置。

**Create：**`Helpers/NativeCodeHighlighter.swift`；按模块拆可有native tokenizer。**Modify：**`Helpers/NotesTextProcessor.swift:121/150/165`、`Helpers/CodeBlockHighlighter.swift:46/54`、`Helpers/MarkdownRuleHighlighter.swift:377/383`、`Helpers/CustomTextStorage.swift:75/129/215`、`Views/EditTextView.swift:1140`、`Controllers/ViewController+Editor.swift:1034`。

**Test：**`MdownTests/NativeCodeHighlighterTests.swift`+各语言fixtures。

- 首批语言依SPEC corpus；source string完全不变、ranges只在current snapshot；unknown plaintext code，不fake autodetection。
- comments/strings/nested fence/escape/Unicode/verylongline容错；markedtext不attributes改组词区。等待结果时保留基础code font/background，只在精确patch映射且未词法失效区域暂留旧token；改动/映射不明区域用plaincode样式，绝不对新文字套旧offset或whole-reset导致闪烁。
- 语言更换/界定符面板产生source事务；backticks冲突保真，⌘Enter退出块；高亮后台超时保持可编辑plain。
- 移除调用先做behavior/性能comparison，包删除等T22；别只删import让基础code样式替代全部功能。

**退出门：**each declared language golden与rawbyte/offset测试，source与rich实际highlight/IME正确；所有Highlightr直接/间接caller已改native。

### T16 — native GFM 表格

**依赖：**N1,T15的子编辑/命令边界。**需求：**NE-09,NE-14,NE-15。**验收：**AC-11。

**Create：**`Business/MarkdownTableModel.swift`、`Views/MarkdownTableEditor.swift`（仅G0确认需要独立grid时）；parser/projection extensions。**Test：**`MdownTests/MarkdownTableEditingTests.swift`。

- 模型保存cell source range、escaped pipe、alignment、row/col及stable IDs；不将`code|pipe`误拆。
- cell input/IME、Tab/ShiftTab/Enter/softbreak/⌘Enter与末格addrow锁定操作样本。
- row/colinsert/delete/move/alignment一项事务；跨cell选区/paste类型明确，list/fence外层source上下文不丢。
- grid若有独立input control，统一firstresponder/sessionhistory/跨块selection和copy，不能每格一套文档。

**退出门：**表格完整直接编辑与源码往返，不以table截图/局部source回退算N2；真实IME和wholeundo恢复布局/原文。

### T17 — 数学、图表、HTML 与异步 renderer bridge

**依赖：**N1,T15,T16。**需求：**NE-11,NE-12,NE-28,NE-29。**验收：**AC-13,AC-18。

**Create：**`Helpers/MarkdownBlockRenderAdapter.swift`；有限native snapshot/value对象。**Modify：**raweditor、现有renderer服务/自有入口；避免改vendor。

**Test：**`MdownTests/MarkdownRenderedBlockStateTests.swift`。

- math/fence/HTML source editor是native；renderer收到snapshot与theme/font/size generation。
- readonly preview/error状态可回source；invalidformula/diagram永不丢源码、改save/undo。
- oldrevision/block删除/theme渲染后返回只丢结果；current ready/cache键明确。
- native块导出用已绑定source snapshot按需供给：同fingerprint ready artifact直接复用；仅source态/屏外未激活/无cache时隔离只读renderer宿主生成本块静态SVG/HTML+尺寸/能力，完成预检后交现有RenderedBlockExportController，不读取当前主预览DOM、不滚动/展开编辑面。请求受旧D的identity/资源/取消/尺寸约束，错误图不输出。
- renderer无编辑message/任意path桥；intent校验走T14，不收任意Markdown。
- raw HTML不执行编辑侧脚本/文件桥；无法静态展示就源卡，不扩任意网页。

**退出门：**隔离权限/状态和特殊块editing按corpus过；不宣称vendor全部语法parity。

### T18 — NativeMarkdownFormatter 替代 Prettier

**依赖：**N1,T15,T16。**需求：**NE-15,NE-16,NE-25。**验收：**AC-15,AC-20前置。

**Create：**`Helpers/NativeMarkdownFormatter.swift`。**Modify：**`Controllers/ViewController.swift:43`、`Controllers/ViewController+Editor.swift:3/13/29/912/949/978/1021/1425`、`Views/EditTextView.swift:385`、`Helpers/EditorMenuManager.swift:157`，保持formatText selector；实施前重新搜索全部formatter callsite，不假设paste/分栏存在隐式format。

**Test：**`MdownTests/NativeMarkdownFormatterTests.swift`、`MdownTests/MarkdownFormattingRevisionTests.swift`。

- redcases：format期间同note继续typing/undo、cancel、switchnote，旧结果不能publish；Formatter结果用source patches+history，不directwhole textStorage replace。
- 实现SPEC `mdown-preserve-v1`规则与完整golden profile；受保护sourcebytes不动、semantics等价、f(f(x))==f(x)。TypographyCleaner继续独立命令。
- 用旧Prettier baseline逐条记录intentionaldifferences与支持限制；regex仅做保守lexicalrange，不能整篇substring替换破坏code/ref。
- format不是savehook，failed/cancel报告明确，保留cursor/scroll映射和undo。

**退出门：**声明的全部profile规则+schema/corpus验证，rawprotected/ref完整，旧revision实机竞争不覆盖；所有Prettiercallers已native。

### T19 — focus/typewriter、系统服务与可访问性

**依赖：**T15~T18。**需求：**NE-32,NE-33,NE-37,NE-38。**验收：**AC-17。

**Modify：**`Views/RichMarkdownTextView.swift`、`Controllers/ViewController+Editor.swift`、`Controllers/EditorPrefsViewController.swift`/`Controllers/GeneralPrefsViewController.swift`必要设置、`Helpers/UserDefaultsManagement.swift`、`Resources/Localization/Base.lproj/Main.storyboard`及 `Resources/Localization/{es,ja,zh-Hans,zh-Hant}.lproj/` 对应文案。

**Test：**`MdownTests/NativeEditorViewStateTests.swift`；实机keyboard/VoiceOver。

- native caret行滚动居中、focus非活动块降噪、mode/zoom保持anchor，不改变revision/dirty/history。
- NSSpellChecker/automaticreplacement按protectedsourcekind分流，不改code/math/URL；markedtext不抢候选。
- font/line spacing/codefont/Retina/darklight/theme与现有preferences一致，图片/table限制宽度，长code局部scroll。
- Englishfallback+es/ja/zhHans/zhHant菜单ObjectIDs齐全，不更换整个侧栏材质/图标体系。

**退出门：**系统服务/scroll/UI差异有实际记录；newsettings不占⌘0~5，不破坏原生search/title焦点。

### T20 — snapshot 预览/演示/导出兼容

**依赖：**T17,T18,T19；D线已有门独立核验。**需求：**NE-28,NE-29,NE-31。**验收：**AC-18。

**Modify：**`Business/Markdown.swift:344`仅必要parse选项、`Views/MPreviewView.swift:803/885/1113`、`Extensions/MPreviewView+Export.swift:703`、`Helpers/PdfExportController.swift:52`、`Helpers/RenderedBlockExportController.swift:434`。

**Test：**扩展现有Html/Mermaid/RenderedBlock tests，`MdownTests/NativeEditorExportSnapshotTests.swift`。

- export/preview/presentation/PPT读session snapshot，不读取hiddenview或当前切换后note；job固定owner/revision/config。
- resource ready/failed/timeout/cancelled+字体/图片明确；0sizes/错误块不误成功；writeerror/cancel不改正文模式。
- PDF中文emoji/复制搜索/link/outline/headerfooter/pageboundary实际产物检查；单MermaidPNG/SVG沿D线，不用整页截图替代。验证native图表仅source态、屏外无artifact、主preview尚未创建三种入口都按T17隔离供给；预检期间源码/主题变化取消旧操作，冻结后独立保存，主editor selection/scroll/mode/hash不变。
- iOS读取同样Markdown/i/links/frontmatter回归；如共享resource/target触及，额外mobilebuild与simulator读取。

**退出门：**导出/渲染在新editor下无回归；保留JS用途列表透明，不把两条renderer与editor混算。

### T21 — 全面行为、压力、兼容与 Sandbox 门

**依赖：**T15~T20，N1回归。**需求：**NE-03~NE-38适用集。**验收：**AC-01~AC-19,AC-22。

**Files：**所有新增/扩展tests、`validation/N2-pre-removal/`；不为绿灯修改无关业务语义。

- 全unit+macOSbuild+strictlint；真实source/rich/mode/IME/undo多note步骤，每项有source/hash/selection/actualfiles。
- 200KiB/2k预算+1/10MiBsourcepressure+largecode/manyattachments、trace与memory；失败有minrepro，不盲重试/无限加timeout。
- 当前新系统实机、11.5API与可用测试机、正确签名Sandbox保存/取消/覆盖/授权失效；unsignedtest不算Sandbox行为证据。
- owner/conflict/退役/写错误/失焦/quit全故障矩阵；typingparse disorder完整回归。

**退出门：**数据/IME/undo/输出保真阻断全部解决；未知设备标明partial，不能公开声称全兼容。AC-21官方parity独立继续。

### T22 — 移除 Vditor、Highlightr、Prettier

**依赖：**T21。**需求：**NE-25,NE-26,NE-34,NE-36。**验收：**AC-20。

**Remove（核实最后引用后）：**`Views/VditorEditView.swift`、`Resources/DownView.bundle/editor.html`、`Resources/DownView.bundle/vditor/`专属目录；替换 `MdownTests/VditorIntegrationTests.swift`为native contract tests。

**Modify：**`Package.swift:13/16`、`Package.resolved`、`Mdown.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`、pbxproj的framework/packageproduct/remote refs、所有已改imports/calls；只清本任务依赖。

- baseline inventory与rg检查所有三依赖 direct/indirect references，确认remainingpreviewresources不是Vditor专属重复包。
- classicpbxproj全4处removeVditor源/旧test，清Highlightr/Prettierlink/product/ref，包括旧孤立实体；保留CMarkGFM/KeyboardShortcuts/Sparkle，无无关pin升级。
- fresh DerivedData构建产物验证不含Vditor/editorHTML/Highlightr_Highlightr/PrettierJS；源码编辑关键paths不调用JS/JSCore。
- 不能因为系统WebKit链接JSCore而判本任务失败，也不能只看resource不存在算成功；跑真实typing/format/highlight/save/IME与导出回归。
- legacybackend值兼容迁移到native，safe source永久保留；同次diff里保留已实现测试，不删除断言绕过失败。

**N2门：**原生behavior已覆盖，三编辑依赖的源码/工程/产物/运行证据齐全；保留renderer清单明确披露。

### T23 — Typora 行为对照、文档与最终 P-Gate

**依赖：**N2，官方baseline可用。**需求：**NE-31,NE-33,NE-35,NE-36。**验收：**AC-21 +全部适用AC。

**Modify：**`README.md`、`README_CN.md`、`ARCHITECTURE.md:89`、`DEPENDENCIES.md:17/20`、`AGENTS.md`必要owner/IME规则、旧W Spec/Plan链接、`skills/mdown/`产品说明（确有变更才改）。

- officialTypora同输入source/selection/view/undo逐项对比，marker/table/rawcode/typewriter/IME具体差异记录。
- Mdown intentionaldifferences（最小原文patch、跨模式统一undo、无拒载置空）明示，不偷偷降低验收。
- nontestedunsupported unknown不计pass；“完全一致”营销限定支持版本/集合，不把nativeeditor说整应用零JS。
- 更新旧计划历史状态/新合同链接，D线继续其独立验收，不覆盖原产品优先级。
- 全release检查是独立授权流程，当前计划到reviewable通过结果为止。

**退出门（P-Gate）：**NE→task→AC→实际证据全部覆盖；blocked/partial风险有明确位置/影响/下一步；没有owner/IME/丢文档阻断。最终发布按直接下载/App Store分别报告，未授权不tag/送审。

## 4. 文件与集成责任

| 领域 | 新增/修改核心文件 | 避免事项 |
|---|---|---|
| model/map/history | MarkdownEditingSession、EditTransaction、History、SourceMap、LosslessParser | 不读preview处理后位置、不另存全局权威正文 |
| native view/input | RichMarkdownTextView、RawBlockEditor、TableEditor、ProjectionBuilder/InputRules | 不迁SwiftUI、不同时让多个view独立undo正文 |
| host/lifecycle | ViewController系列、TransitionCoordinator、MainWindowController、AppDelegate | 保留storyboardselector/outlet，mainthread同步apply |
| storage/async | Note/Storage/watchers/versions/ClipboardManager | 不重写库协议、不跨owner/revision、i/保持 |
| deps/tools | nativehighlight/formatter + package/pbxproj | 不升级无关pin、不删整DownViewbundle |
| renderer/export | existingpreview/blockexport/PDF +有限snapshotadapter | D先验收，JS只读/intent有限，禁任意正文写 |
| localize/test/docs | 经典pbxproj目标、4种非英文、sharedscheme、文档 | 文件存在非已编译，tests不静默return |

每个新增Swift/test注册4处：PBXBuildFile、PBXFileReference、group children、正确target Sources。Fixture注册为test bundle Resources并验证Bundle查找，不能只放文件夹。实际删除资源前read/inventory；旧build产物不代表新HEAD产物，使用新DerivedData验证。

package refs注意根Package.resolved与Xcodeworkspace resolved已有其他pin差异：保持非任务package原值，不能为“统一”升级Sparkle或整个dependency graph。具体IDs在实施前再次rg，而不是永久硬编码本Plan行号。

上述新增文件/测试是责任边界，原型收敛时允许合并同职责文件，不以文件数量作为完成标准；保留每个行为测试与纯逻辑/运行验证的区别。不要为符合计划名称造空类、stub renderer或复制一份session。

## 5. 关键可执行测试规格示例

以下是拟议API的测试oracle，随正式文件注册后运行；当前没有该类型，不声称已编译。其目的固定行为，不把实现写进测试。

```swift
import XCTest
@testable import Mdown

final class MarkdownEditingSessionTests: XCTestCase {
    @MainActor
    func testOldRevisionDoesNotOverwriteNewText() {
        let identity = EditingIdentity(
            ownerToken: UUID(),
            canonicalURL: URL(fileURLWithPath: "/tmp/session.md"),
            generation: 1
        )
        let before = MarkdownSelection(anchorUTF16: 1, focusUTF16: 1, affinity: .downstream)
        let session = MarkdownEditingSession(
            identity: identity, markdown: "AB", selection: before, isReadOnly: false
        )
        let transaction = EditTransaction(
            identity: identity, expectedRevision: 0,
            patches: [SourcePatch(rangeUTF16: NSRange(location: 1, length: 1), expectedText: "B", replacement: "C")],
            selectionBefore: before, selectionAfter: before,
            origin: .typing, undoGroupID: UUID()
        )
        guard case .accepted(let accepted) = session.apply(transaction) else {
            return XCTFail("当前revision的有效编辑必须成功")
        }
        XCTAssertEqual(accepted.markdown, "AC")
        let stale = EditTransaction(
            identity: identity, expectedRevision: 0,
            patches: [SourcePatch(rangeUTF16: NSRange(location: 0, length: 2), expectedText: "AB", replacement: "旧格式化结果")],
            selectionBefore: before, selectionAfter: before,
            origin: .format, undoGroupID: UUID()
        )
        guard case .rejected(.staleRevision) = session.apply(stale) else {
            return XCTFail("旧formatter结果必须拒绝")
        }
        XCTAssertEqual(session.snapshot.markdown, "AC")
        XCTAssertEqual(session.snapshot.revision, accepted.revision)
    }
}
```

至少另有以下独立失败用例，不用上述一条代替：

| 测试名 | 固定输入/结果 |
|---|---|
| testRejectsOverlappingPatchesAtomically | `ABCDE` 两个交叠range；source仍ABCDE、history/selection无变化 |
| testRejectsExpectedTextMismatch | range合法但expected old错误；整个事务拒绝 |
| testUTF16RangeDoesNotSplitEmoji | `A🙂B`删除emoji完整range；半代理range拒绝 |
| testNoOperationPreservesCRLFAndBOM | 固定实际bytes，模式20次无edit前后hash相等 |
| testSameOwnerStaleBufferCannotSave | source rev0/rich rev1，Cmd+S取sessionrev1，不旧source |
| testWriteRevisionOneCannotClearRevisionTwoDirty | captured write v1后接受v2，v1成功时v2仍needsSave |
| testWriteFromOldGenerationCannotClearSameRevisionDirty | 同URLrebind后新的generation/revision与旧数字相同，旧write结果仍拒绝，pending/source/dirty不变 |
| testHighlightDelayKeepsValidCodeStyleAndRejectsStaleTokens | 注入慢高亮+typing/IME，未改可映射token保持，改动区plain，marked区属性不变；旧offset结果不应用 |
| testNativeMermaidExportWithoutPreviewDOM | 只有native源码块、无主preview/readycache时仍按需渲染静态快照，取消或revision变化不写文件，不动editor scroll/selection/hash |
| testCompositionCommitsOnceAndUndoRestoresSelection | 真实AppKit composition宿主+候选；submit一次history，undosource/selection恢复 |
| testParseCallbacksOutOfOrderDoNotDropInput | 500ms旧parse/200ms新parse乱序，连续typing后最新map收敛 |
| testRetiredOwnerRejectsLateAttachment | retire后lateupload不save或重建磁盘，source/新owner不变 |
| testPreviewIntentUsesDisplayedRevision | previewA旧gen消息不toggle当前B，valid任务source精确span |
| testFormatterPreservesProtectedBytesAndIsIdempotent | code/math/ref/frontmatter/rawHTML前后字节相同、format两次一样 |
| testUndoAcrossSourceAndRichIsSingleHistory | 同session跨view动作undotooriginal后redo；viewstate更新不入栈 |
| testSelectionAcrossParagraphCodeAndTableUsesOneSourceRange | 固定段落→code→2×2table，连续shift/拖选跨子view；映射后的anchor/focus与已知source UTF16区间相同，替换/undo恢复source及方向；不能只测每个子view内部selection |
| testRecoverySnapshotCapturesDirtySessionWithoutClaimingDiskSuccess | dirty会话导航/面板/恢复前snapshot来自当前revision，磁盘未写时dirty不清且trigger明确 |

IME候选、selection/navigation、真实source buffer保存必须通过实际AppKit/运行路径；不能用纯字符串算法test冒充。

## 6. 验证命令与实际覆盖

所有命令在Mdown根执行，先窄后宽。本次写文档不运行build/tests；新增测试名在target注册后才能执行。

```bash
# 基线现场
git rev-parse HEAD
git status --short --branch

# 示例窄测试：正式类创建并注册后
xcodebuild test -project Mdown.xcodeproj -scheme Mdown \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MdownTests/MarkdownEditingSessionTests

# 正式macOS阶段门
xcodebuild -project Mdown.xcodeproj -scheme Mdown \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project Mdown.xcodeproj -scheme Mdown \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
swiftlint lint --strict
swift-format lint --recursive . --strict

# 共享格式/资源/target变更时iOS回归
xcodebuild -project Mdown.xcodeproj -scheme MdownMobile \
  -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build

# 退编辑依赖：检查结果需分类，不能把全部renderer当编辑依赖
rg -n 'Vditor|vditorChange|Highlightr|Prettier|PrettierMarkdown' \
  Business Controllers Helpers Views Package.swift Mdown.xcodeproj/project.pbxproj
```

`CODE_SIGNING_ALLOWED=NO`是既有本机单测TeamID问题处理，不证明Sandbox权限。实机测试用project run技能/实际launch方式，保持正确task进程归属；不能为了规划擅自跑release/archive脚本。已安装CLI不足/无设备/依赖需fetch时，记录阻塞与获准路径，不改全局工具配置。

验证层分开：pure model tests、AppKit integration、真实IME/UI、Note磁盘回归、renderer/export文件验证、性能trace、签名Sandbox/旧系统、iOSreader。输出结果必须与source/hash、filename/dimensions/text/link等断言一起保存，不靠“file存在/模型goal_reached”判完成。

## 7. 需求追踪、并行边界与回退

| 任务 | 需求 | 验收 |
|---|---|---|
| T00,T01 | NE-03,NE-16~18,NE-31,NE-35,NE-36 | AC-02,07,09,19,21 |
| T02~T04/G0 | NE-02~06,NE-08基础原语,NE-12~16,NE-27,NE-30；NE-31仅API探针 | AC-01~05原型,AC-06三层list原型,AC-19性能/API子集 |
| T05~T09 | NE-02,NE-13~22,NE-27,NE-36 | AC-03~10,22 |
| T10~T14/N1 | NE-01,NE-05~08,NE-10~14,NE-18,NE-21~24,NE-28,NE-32,NE-33,NE-36 | AC-01~06,10,12基本,13,14,16,17 |
| T15~T20 | NE-09~12,NE-14~16,NE-25~33,NE-37,NE-38 | AC-11~19,20前置 |
| T21~T23/N2/P | 全部NE适用集，NE-34/35重点 | 全部AC适用集，AC-20/21重点 |

并行仅限独立原型/纯逻辑tests、code tokenizer与formatter corpus、只读review；同一session/source map/view/project file不能多人同时写。host/mode/lifecycle/renderer交叉由一名集成人串行合并。D线与W原型可并行；不占D所需导出文件长期重构。

回退按阶段：G0失败不接业务；N1开关关闭先完成composition/commit并安全回source；N2去依赖后source继续可用，不自动重新启用JS或回滚用户文件；format/highlight不支持语法保留原文。dirty/writefail/conflict永不通过丢草稿换模式解决。出现重复失败无新证据，停止扩大修改并报告位置、假设与下一项验证。

## 8. 工期与本轮完成定义

这是多阶段编辑核心项目，不能在G0前承诺确定工期。T00/T01是窄baseline和现有风险；G0决定投影方案是否成立；session/lifecycle、table、formatter/highlighter、parity各有独立成本。每门通过后按实际结果估后续，不以静态源码规模估体验完成度。

本轮完成仅指两份Spec/Plan可读、路径/合同互相一致、每个需求有任务与验收、既有优先级/兼容约束保留、未知列明；业务是否完成必须以后续代码、失败→通过tests、真实UI和文件验证判定。实现阶段记录commit/PR只是流程结果，不等于功能通过；提交/发布仍受当前用户授权约束。
