# Mdown 原生编辑器替换 Implementation Plan

> 状态更新（2026-10-14）：本文保留为研究阶段的准备清单；正式实施以 [新主 SPEC](../native-typora-editor/SPEC.md) 和 [新主 PLAN](../native-typora-editor/PLAN.md) 为准。新主文档的 N1 表示可选基础原生模式，N2 才是完整编辑链去 JS，避免沿用本文旧编号造成完成状态混淆。

> 执行说明：这是待技术验证的准备计划。实现时使用当前宿主实际提供的执行计划能力逐项推进；每个阶段先明确失败测试和通过门槛，不凭计划文字宣称功能存在。此文件不自动授权提交、推送、发布、安装外部工具或切换默认编辑模式。

**Goal:** 用本地 Swift/AppKit 编辑模型实现已定义的 Typora 编辑行为，逐阶段移除编辑链路 JS 依赖，并为剩余渲染依赖提供独立迁移门槛。

**Architecture:** Markdown 原文为持久化权威状态，原生会话记录文档 owner、revision、选择和事务历史，AppKit 投影根据原文范围派生可编辑视图。导出与图表渲染读取不可变快照；异步结果核对 owner、block 和 revision 后才发布。

**Tech Stack:** Swift、AppKit、CMarkGFM 1.0.2、TextKit 1 基线、XCTest、PDFKit/CoreGraphics。技术方案及取舍见 [NATIVE-DESIGN.md](NATIVE-DESIGN.md)。

本计划是补充研究，不另立与既有 W0/G0/W1/W2 竞争的执行路线。拟议 Native* 类型名仅用于说明职责，正式实现优先使用既有 `MarkdownEditingSession`、`MarkdownSourceMap`、`RichMarkdownTextView`；不要重复创建平行会话。原型先走现有 W0/G0，Task 2/3 的正式 session/source-map 接入在 G0 通过后进行。

基线：`main@b8110a942e27ae13ebe531b549a56e5a220f91ae`。实现前重新检查分支和 dirty changes，建立独立开发分支/工作区。当前研究资料位于 untracked `specs/typora-research/`；不覆盖其他修改。既有 [SPEC](../wysiwyg-and-rendered-block-export/SPEC.md) / [PLAN](../wysiwyg-and-rendered-block-export/PLAN.md) 的 D 线优先级仍保留，不把全编辑器替换设为单 Mermaid 导出的前置条件。

## 0. 两个明确的交付门槛

- **N1：编辑链路本地化。**正文模型、选区、IME、输入规则、撤销、模式切换、保存、高亮/格式化关键调用不再需要 JS；渲染插件不得拥有正文。
- **N2：剩余渲染本地化。**公式、Mermaid/PlantUML、演示、HTML 预览/导出等分别通过语法、视觉、离线与性能验收后移除剩余 JS。

N1 不能宣称“整应用零 JS”，N2 不能通过仅删除资源文件宣称完成。具体已存在依赖与源文件入口见 [MDOWN-MIGRATION.md](MDOWN-MIGRATION.md)。

## Task 1：冻结对照与行为合同

**Files：**本研究目录 `fixtures/`、`PARITY.md`；不修改业务代码。

1. 先实际复现当前 Vditor `setValue` 第二参数错配、同 owner 隐藏 source 的保存覆盖和格式化旧 revision 风险，建立失败用例与当前基线；不把静态风险直接记作已复现。
2. 用来源、签名、版本均已核验的官方 Typora 打开任务专用样例，记录样本 SHA-256 和环境。
3. 执行 16 个行为用例，填入 source、selection、focus、undo/redo、截图与导出结果；marked-text 场景使用真实输入法，不以插入最终中文代替。
4. 在当前 Mdown 上执行相同固定场景，记录已有/缺失/不一致项。
5. 锁定首期可验收的行为集合：段落、标题、基本行内格式、简单列表、源码/渲染态切换、保存与撤销；表格与特殊块另设阶段。

**Gate：**官方基准身份、输入序列和期望结果完整；未知条目保留 pending，不自动通过。固定性能场景应先测当前基线再设预算。

## Task 2：建立原生文档会话与 owner 合同

**依赖：**既有 W0/G0 原型通过（Task 3/4 的可丢弃验证可先进行，正式接入仍按 W1）。

**正式类型优先：**`Business/MarkdownEditingSession.swift`；`NativeEditorDocument/NativeEditorSession` 只是职责名，必要辅助对象不要再成为独立权威状态。

**拟新增测试：**`MiaoYanTests/NativeEditorSessionTests.swift`。具体接入现有 `EditTextView` 与保存服务，按迁移文档核验的入口修改。

1. 先写失败测试：note A buffer 在选择 note B 后仍只能保存到 A；A 的后台结果在 B 激活后不得发布；已删除 note 不能被延迟回调复活。
2. 定义 noteID、editorSessionID、revision、source、selection、mode 和 newline policy；构建显式 replacement transaction。
3. 实现一次 publish/commit 入口，拒绝旧 revision、跨 owner 与无效 range；不绕过现有 buffer-owner 保存约束。
4. 为模式切换、外部磁盘更新和生命周期 flush 写回归测试，不引入新的正文副本作为权威。将 Vditor、Cmd+S、关窗、退出、duplicate、watcher、版本恢复、preview checkbox 和 formatter 结果全部路由 session/revision；不得再无条件采同 owner 的隐藏旧 source。

**Gate：**跨笔记 owner、旧结果、文件删除/外部修改的失败路径有有效测试；基础源码编辑行为仍可使用。

## Task 3：原文、解析结构与坐标映射

**正式类型优先：**`Helpers/MarkdownSourceMap.swift`；原文结构辅助模型按 W0 原型结果命名，`NativeMarkdownModel` 暂指角色，不创建第二套 parser/权威正文。

**拟新增测试：**`MiaoYanTests/NativeMarkdownSourceMapTests.swift`、`MiaoYanTests/NativeMarkdownRoundTripTests.swift`。

模型测试的判据应来自原文操作与不变量，不机械重演 parser 实现。至少验证以下独立 oracle：无编辑字节摘要、Unicode 边界、编辑范围之外的原文保持不变、undo 后回到原始 source 和 selection；用固定 fixtures 再补组合输入与跨块替换的小样本。

1. 写失败测试：UTF-8/UTF-16/grapheme 范围转换，family emoji、组合重音、混排与 CRLF。
2. 明确原生 parser 的 source position、扩展语法与原文丢失范围；AST 与 source slice 并存。
3. 用显示 segment 表达文字、delimiter、block marker、链接 destination、code 和 attachment，定义双向 caret/selection 映射。
4. 验证无编辑打开/关闭/模式切换后原始字节摘要不变化；编辑一块只修改相应源码范围。
5. 覆盖 frontmatter、引用定义、脚注、raw HTML 与 nested fence 保护范围。

**Gate：**不能用 HTML→Markdown 常规回转补 source map；标记隐藏和跨范围编辑必须有明确映射，不依赖 JS fallback。

## Task 4：TextKit 原生投影技术验证

**正式类型优先：**`Views/RichMarkdownTextView.swift`；投影辅助服务只承担原文范围到显示的派生转换，`NativeMarkdownProjection` 为暂定角色。

**拟新增测试：**`MiaoYanTests/NativeMarkdownProjectionTests.swift`；IME/系统选区另做实机验证。

1. 原型只覆盖 paragraph、heading、bold/emphasis/link/inline code；未做本轮 UI redesign。
2. 验证源码范围映射到显示 textStorage 后，标记显隐、caret、点击和跨格式拖选稳定。
3. 实际操作拼音组合、候选取消/确认、连续 marked-text 更新与多 Unicode 字符；组合期间不重建 current storage 或更新组合区属性。
4. 验证系统复制/粘贴、辅助功能阅读、按词/行移动和 scrolling，不因自绘或隐藏字符破坏系统行为。
5. 使用既有 TextKit 1 / macOS 11.5 基线；必要时评估兼容实现，不默认抬高版本。既有 W0 的 200 KB/2,000 行与预算也须测量，本研究的 1 MB/10 MB 压力项仅作补充。

**Gate：**IME、双向选择映射、无损源码和系统编辑行为均通过后继续；失败时保留最小复现，改模型或评估其他原生 block 投影，不直接启用默认模式。

## Task 5：事务与撤销恢复

**拟新增：**`Business/NativeEditorTransaction.swift`、`Business/NativeEditorHistory.swift`。

**拟新增测试：**`MiaoYanTests/NativeEditorHistoryTests.swift`。

1. 先写输入/删除分组、选区移动断组、组合提交、格式操作、新编辑清 redo 的失败测试。
2. 决定 NSTextView/UndoManager 与模型事务的单一注册归属，禁止一项动作产生两套重复历史。
3. 实现结构、source、selection before/after 的原子撤销；跨模式历史策略依 Task 1 合同。
4. 区分磁盘版本备份与编辑会话状态，测试切换 note、关闭窗口与临时 dirty buffer；既有 SPEC 只承诺进程内草稿与正常生命周期处理。跨重启/崩溃恢复仅记录需求，不自动加入本期实现；如要采用须另行明确数据格式、目录、清理和恢复合同。

**Gate：**从一组动作完整 undo 到原始文件，再 redo 到目标 source/structure/selection；不以单纯 NSUndoManager.canUndo 作为覆盖。

## Task 6：列表、表格和结构输入规则

**拟新增：**`Helpers/NativeMarkdownInputRules.swift`、`Business/NativeMarkdownTable.swift`。

**拟新增测试：**`MiaoYanTests/NativeMarkdownInputRulesTests.swift`、`MiaoYanTests/NativeMarkdownTableTests.swift`。

1. 对 Enter/Backspace/Delete/Tab/Shift-Tab 建立原文与结构结果测试，IME 组合态优先。
2. 实现段落拆分/合并、标题后 Enter、list/quote 续项和退出，保护 code/URL/frontmatter。
3. 实现 table cell navigation、行列增删/移动、alignment 和 pipe 转义；所有结构操作一次事务。
4. 验证跨块/跨 cell 选择、粘贴与撤销，不能让每个原生子控件独立覆盖全文。

**Gate：**功能按 PARITY 锁定后的行为验证；更改行为标为 Mdown 设计取舍，不假称 Typora 已观测。

## Task 7：高亮与格式化关键链路本地化

**拟新增：**`Helpers/NativeCodeHighlighter.swift`、`Helpers/NativeMarkdownFormatter.swift`。

**拟新增测试：**`MiaoYanTests/NativeCodeHighlighterTests.swift`、`MiaoYanTests/NativeMarkdownFormatterTests.swift`。

1. 列出当前关键代码语言与 Markdown 格式化命令所用 JS 依赖及调用点。
2. 用原生 token/range 输出高亮，保留所有 code source bytes，不修改 marked text 或正文 owner。
3. 格式化作为显式可撤销命令；规定支持语法和保护范围，无须在 typing 中持续正规化。
4. 对中文、emoji、原文保护区、列表/表格/fence 写 golden source-diff 测试；未支持语言保留可编辑纯文本降级。
5. 只有验证原生替代和所有 callsite 退出后，才移除对应依赖、JSCore 调用与资源。

**Gate：**构建和代码路径检查都能证明基础编辑关键链路不再调用 JS；未覆盖格式化语法如实列出，不用隐藏 fallback 制造 N1 完成。

## Task 8：特殊块渲染与导出隔离

**拟新增：**`Business/NativeRenderedBlock.swift`、`Helpers/NativeRenderedBlockService.swift`、`Business/NativeExportSnapshot.swift`。

**拟新增测试：**`MiaoYanTests/NativeRenderedBlockTests.swift`、`MiaoYanTests/NativeExportSnapshotTests.swift`。

1. Renderer 只接受 immutable block input，不注册编辑事件、不写回 source。
2. 以 noteID、blockID、revision、主题/尺寸/renderer version 约束缓存与异步发布，覆写旧结果必须拒绝。
3. 代码、公式、Mermaid/PlantUML、HTML 块分别定义 source/edit/render/error 状态；错误与超时不阻止保存。
4. 将导出 prepare/资源就绪/保存成功或失败封装为 job；snapshot revision 在导出期间保持不变。
5. 继续独立 D 线：单 Mermaid PNG/SVG 完整、无裁切和缺字优先，不等待全部编辑体验完成。

**Gate：**编辑不依赖 Renderer 成功；取消、失败、资源未就绪有显式终态，图表导出有实际文件检查。

## Task 9：剩余 JS renderer 逐项替换

**Files：**具体目录和现有 callsites 以 [MDOWN-MIGRATION.md](MDOWN-MIGRATION.md) 为准；每个 renderer 的新增文件由其通过原型后的设计决定。

1. 分别清点公式、Mermaid 图种、PlantUML、演示、HTML 和所有 export 脚本，不把它们混称“JS 编辑器”。
2. 对每一类建立支持语法、布局、字体、尺寸、offline/error 和性能 corpus；不宣称 Mermaid 全语法已经有原生替代。
3. 在 App Store sandbox、直接下载版和当前最低系统版本验证可行性；外部工具需要单独授权与依赖说明。
4. 先运行平行结果比较，保留可恢复旧路径；只有兼容和视觉门槛通过才移除依赖资源。
5. 对 PDF 搜索/复制、链接、outline、页码等语义做独立检查；只看图片文件不够。

**Gate：**应用 runtime 关键路径和 bundle inventory 两侧都证实移除；N2 完成需逐项证明，不接受模型自报或文件删除作为结果。

## Task 10：集成、验证与默认模式切换

**Files：**现有 editor host、菜单与模式切换、保存服务、`MiaoYan.xcodeproj/project.pbxproj`、项目文档；具体源文件入口按迁移文档核验后执行。

1. 新源文件和测试手工加入 pbxproj 的四个位置；同一阶段单人更新 project/host，避免并行写冲突。
2. 先用显式可选模式接入新原生会话，旧源码、分栏、预览、演示继续正常读同一 Markdown。
3. 跑对应纯模型测试，再执行 macOS build、IME 实机与 PARITY 样例。只有新增问题或改动需要时才扩大检查。
4. 对 SwiftLint/swift-format、App Store sandbox、iCloud/symlink/Trash、跨 note owner 和外部修改做相关回归。
5. 默认模式切换、彻底删除旧路径与发布各自需要具体 reviewable 结果和相应授权；研究文档不代替授权。

建议的实际命令：

```bash
xcodebuild -project MiaoYan.xcodeproj -scheme MiaoYan -configuration Debug build
xcodebuild test -project MiaoYan.xcodeproj -scheme MiaoYan -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
swiftlint lint --strict
swift-format lint --recursive . --strict
```

测试筛选参数按已注册的真实 test target/name 执行；未创建的测试不能写成已通过。移动端行为本轮不改变；若公共文件格式或附件语义变化，必须另补 iOS build 与真实读取验证。

## 11. 完成声明需要的证据

- Task 1 的官方基准与操作结果，包含实际状态而非 pending。
- 原文往返和 owner/IME/history/range 的有效测试及通过日志。
- 新模式的实机视觉、输入法与选择/撤销对照。
- 各 JS 依赖的“最后 callsite、原生替代、资源移除、构建与运行”记录。
- 固定样例的性能结果；无预算或没有实测不能称性能一致。
- 图表和 PDF 导出文件的实际完整性与语义检查。
- 已知差异、支持语法边界和失败回退记录。

本轮只完成这些步骤的准备，不声称原型、替换或产品验收已经执行。
