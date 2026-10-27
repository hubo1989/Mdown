# T13 — 剪贴板、附件与局部 raw 源码

日期：2026-10-20；阻塞修复复验：2026-10-21。实现基线：T12 `e1e0423`。

**当前状态：T13 实机验收通过（2026-10-21）。全量 485/485；中文输入、真实 Finder 粘贴、保存失败/恢复写入、raw 撤销/重做、图片属性弹窗打开经维护者手工或实机验证；拖放修复版的 Finder PNG/TXT 真实拖入、附件字节、重开渲染与磁盘稳定已复验通过。图片属性修改保存的完整人工矩阵仍保留为未验证范围，不阻塞 T13 退出门。**
本轮未提交、推送或创建 PR。T12 的真实中文 IME 验收仍沿用其记录中的未验证边界。

## 实现范围

- Copy Visible / Copy Markdown / Paste Plain / Paste Markdown：普通复制的文本类型是可见文字，内部 Markdown 类型保留源码；显式复制 Markdown 同时提供源码文本。
- 普通外部文本粘贴转义 Markdown 语法；显式 Markdown 和内部类型保留语法。HTML 仅经现有 `HtmlToMarkdown.convertIfStructured` 门槛转换；代码、数学、元数据和 raw HTML 上下文保持字面文本。
- 粘贴作为单条历史事务，支持跨块替换；转义字符仍可继续编辑。通过实际编辑范围和字素边界计算 patch，避免重复文字、Unicode 或 CRLF 导致的错位。
- 文件粘贴/拖放走异步附件写入：图片保存在笔记旁 `i/`，其他文件保存在 `files/`，采用 UUID 名称；先写文件，再插引用。只接受单个本地常规文件或图片数据，上限 100 MiB，拒绝附件目录的符号链接跳转。
- 请求捕获笔记身份和 source anchor；前方编辑移动锚点，覆盖/删除锚点、切换笔记、隐藏编辑器、撤销/重做或装载使旧请求失效。完成时复核笔记路径、代次、删除状态、可编辑状态与 marked text；拒绝时清理本次新写的附件，不恢复已删除的笔记。
- 图片以 alt 或占位显示，整条引用作为原子片段；上下文菜单可修改 alt、URL、title。转义符用于源码而不泄漏到 alt 显示，重复编辑不叠加转义，非法 scheme 和 URL 控制字符被拒绝。
- code/math/diagram/raw HTML 直接在同一个 `RichMarkdownTextView` 的局部源码片段编辑，共用历史；未闭合、未知语言和错误图表源码保留。没有新增第二个全文编辑器，也没有新增网络请求。
- 组合输入提交的历史基于 source，撤销/重做保留其他块的隐藏 marker；原生 `undo:` / `redo:` responder 使用同一历史。marked 期间不重铺投影或字体属性。
- 新菜单与提示补齐 es、ja、zh-Hans、zh-Hant；新 Swift 文件已登记 Xcode 工程的文件引用、分组、BuildFile 与 Sources 四处。

## 自动化结果

| 检查 | 本轮结果 |
|---|---|
| 11 个相关套件 | **204 tests，0 failures** |
| 最新实机问题修复后的全量套件（2026-10-21） | **485 tests，0 failures**，包含 Mermaid、KaTeX 运行测试 |
| 阻塞修复相关三个套件 | **40/40**：EditingTransition 18、EditorCommitPersistence 13、HtmlManager 9 |
| `MarkdownClipboardTests` | **28/28**，包括真实 NSPasteboard 文件 URL、PNG/普通文件字节、host→Note→磁盘保存、失败无引用、异步身份/锚点/IME 拒绝、目录边界、图片属性与转义、完整拖放回调与落点写入 |
| `MarkdownRawBlockEditingTests` | **8/8**，包括错误图表、未知 fence、数学/raw HTML、Unicode/CRLF、组合提交/取消、source 撤销与 responder 路由 |
| macOS Debug build | **BUILD SUCCEEDED** |
| 改动的 12 个 Swift 文件：SwiftLint / swift-format `--strict` | **0 violations / 无诊断** |
| 阻塞修复后全部 15 个改动 Swift 文件 | **SwiftLint 0 violations / swift-format 无诊断** |
| 最新实机问题修复后全部 16 个改动 Swift 文件 | **SwiftLint 0 violations / swift-format 无诊断** |
| pbxproj 和四份本地化：`plutil -lint` | **全部 OK** |
| `git diff --check` | **通过** |

其余九套件：`HtmlToMarkdownTests` 27、`LosslessMarkdownParserTests` 14、`MarkdownCompositionTests` 9、`MarkdownEditorHistoryTests` 14、`MarkdownInlineEditingTests` 17、`MarkdownInputRulesTests` 15、`MarkdownListEditingTests` 38、`MarkdownProjectionTests` 18、`RichMarkdownEditingTests` 20。

RED→GREEN：先复现粘贴/复制/source 历史问题，再修复；扩展用例继续发现图片数据判定、目录路径比较、CRLF 和转义字符编辑回归。另有原生 undo/redo selector 缺失与图片 alt 转义显示的独立失败用例，均已在最终轮通过。

本机临时证据（不随仓库提交，可能被系统清理）：

- 最终测试：`/tmp/mdown-t13-final-targeted3.log`。
- 最终 xcresult：`/tmp/mdown-t13-derived/Logs/Test/Test-MiaoYan-2026.10.20_21-14-39-+0800.xcresult`。
- 构建/静态检查：`/tmp/mdown-t13-build-final.log`、`/tmp/mdown-t13-lint-final.log`、`/tmp/mdown-t13-format-final.log`。
- 失败复现：`/tmp/mdown-t13-red.log`、`/tmp/mdown-t13-literal-red.log`、`/tmp/mdown-t13-responder-red.log`、`/tmp/mdown-t13-image-alt-red.log`。

## 复跑命令

所有命令从仓库根执行。包缓存路径是本机已有缓存，可按环境替换。本机使用 deployment 12.0 和关闭签名进行验证，未改变工程部署版本或发布设置。

```bash
build_args=(
  -project MiaoYan.xcodeproj -scheme MiaoYan -configuration Debug
  -destination 'platform=macOS' -derivedDataPath /tmp/mdown-t13-derived
  -clonedSourcePackagesDirPath /Volumes/external/Xcode/DerivedData/MiaoYan-fhxdsphupblimyboczgovvhrqrjb/SourcePackages
  -disableAutomaticPackageResolution -skipPackageUpdates
  CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0
  SYMROOT=/tmp/mdown-t13-derived/Build/Products
  OBJROOT=/tmp/mdown-t13-derived/Build/Intermediates.noindex
)
suites=(
  MarkdownClipboardTests MarkdownRawBlockEditingTests MarkdownCompositionTests
  MarkdownProjectionTests MarkdownListEditingTests MarkdownInlineEditingTests
  LosslessMarkdownParserTests MarkdownInputRulesTests MarkdownEditorHistoryTests
  RichMarkdownEditingTests HtmlToMarkdownTests
)
test_args=()
for suite in "${suites[@]}"; do
  test_args+=("-only-testing:MiaoYanTests/$suite")
done
xcodebuild test "${build_args[@]}" "${test_args[@]}"
xcodebuild build "${build_args[@]}"
```

## 2026-10-20 的阻塞记录（后续复核见下）

1. **全量测试未完成。** 第一轮在既有 `HtmlManagerTests.testPreviewCurrencyGuardPreservesNumericMath` 读外部卷资源时停滞；进程采样显示阻塞于文件 `open()`。把当前源文件复制到本机临时目录后重跑，可通过该处，但既有 `EditingTransitionTests` 的权限失败场景触发 `Note.performDiskWrite` 保存失败弹窗；采样显示主线程停在 `NSAlert.runModal`（`Business/Note.swift:848`）。已停止本任务的测试进程，没有修改这些无关测试或把选中套件结果称为全量通过。证据：`/tmp/mdown-t13-full.log`、`/tmp/mdown-t13-tests.sample.txt`、`/tmp/mdown-t13-full-isolated.log`、`/tmp/mdown-t13-isolated.sample.txt`。T12 的历史全量结果不能代替本轮结果。
2. **实机窗口访问受阻。** 已构建并启动独立临时 smoke app 与测试库；CUA 对该 app、Finder 和已安装 app 均返回 `cgWindowNotFound`，无法取得可操作窗口。未操作用户正在运行的已安装 Mdown。独立 smoke 进程已停止；没有获得 T13 的视觉验收证据。
3. **待补实机项目。** 外部应用复制到四种剪贴板操作、真实 Finder 文件/图片拖放落点与失败提示、图片属性弹窗布局及键盘操作、局部 raw 编辑与原生撤销菜单、真实中文 IME 候选窗下的提交/取消/切换与异步附件返回。AppKit 输入协议单测不等于真实候选窗验收。

## 保留的边界

- 一次仅接受一个文件；多文件粘贴/拖放返回拒绝，不插入部分结果。
- 撤销成功插入只撤销引用，保留附件文件以供恢复；尚未插入的失败/过期请求只清理其自己新建的文件。
- native 路径使用本地附件；未改既有 legacy PicGo/PicList 上传通道。
- raw 源码 fallback 保留编辑输入；renderer 桥接、渲染错误视觉与更完整的高亮属于后续 T15/T17，当前测试没有证明 renderer 视觉结果。
- 窗口访问恢复且全量测试通过后，继续补真实候选窗、Finder 拖放、剪贴板及图片弹窗的完整实机矩阵，再评估 T13 退出门。

## 23:40 阻塞复核

- CUA 按完整路径 `/Applications/Orca.app`、`/Applications/Mdown.app` 已能读取真实窗口的 AX 状态；此前的 `cgWindowNotFound` 当前未复现，无需据此修改系统权限。Orca 的 bundle ID 同时匹配主应用与 Terminal Host，需用完整路径消歧。窗口恢复不代表 T13 功能已完成实机验收，本次未编辑用户笔记。
- 原先卡住的 `HtmlManagerTests.testPreviewCurrencyGuardPreservesNumericMath` 在原工作区单独复跑 **1/1 通过**，日志 `/tmp/mdown-t13-blocker-resource-check.log`。文件读取阻塞的底层原因仍未确定，不能直接认定为外部卷权限问题。该用例可改为读取已打包的 `DownView.bundle/js/common.js`，避免依赖编译时源码路径；检查 Swift 源码契约的其他测试仍需单独处理。
- 模态弹窗的确定性来源仍是 `Note.performDiskWrite` catch 中另行排队的 `MiaoYanAlert.show`；`EditingTransitionTests` 虽注入了 `EditingTransitionPresenting`，却没有隔离这条底层提示路径。建议将保存错误提示抽为默认使用系统 UI 的可注入接口，测试记录错误而不打开窗口，并断言实际写失败、dirty 保留和 Retry/Save Copy/Discard/Cancel 行为；不能通过全局屏蔽错误或跳过失败测试解决。
- 本次仅诊断和更新记录，未修改保存逻辑或测试基础设施，未复跑全量套件。

## 2026-10-21 阻塞修复与复验

### 改动

- `Note.saveErrorPresenter` 是每个 Note 独立的错误提示接口；默认实现保留原有主线程异步系统提示，catch 继续记录错误并返回失败。测试只替换自身 Note 的提示，不使用全局测试模式、不跳过磁盘失败，也不改变生产保存或 dirty 语义。
- `EditingTransitionTests` 在创建 Note 时注入记录错误的提示实现。新回归用例实际将临时目录设为只读，断言写入结果 `.failed`、系统权限错误、草稿仍 dirty、磁盘原文未变；让出主线程后没有新增模态窗口，再恢复权限验证重试成功落盘和 dirty 清除。现有 Retry/Save Copy/Discard/Cancel 场景全部通过。
- `HtmlManagerTests` 的 currency guard 用例改读 host app 已打包的 `DownView.bundle/js/common.js`，不再使用 `#filePath` 打开外部卷源码。

### 验证

- 相关三个套件 **40/40**；随后原工作区直接全量 **480/480，0 failures**。原先受环境限制的 Mermaid 两用例、KaTeX 一用例此次也通过。
- 独立 Debug build **BUILD SUCCEEDED**；全部改动的 15 个 Swift 文件严格 SwiftLint / swift-format 检查通过，`git diff --check` 通过。
- 全量命令使用上文 `build_args`，执行 `xcodebuild test "${build_args[@]}"`，没有 `-only-testing`、`-skip-testing` 或复制源目录运行。

证据：`/tmp/mdown-t13-blocker-fix-targeted.log`、`/tmp/mdown-t13-blocker-fix-full.log`、`/tmp/mdown-t13-blocker-fix-build.log`、`/tmp/mdown-t13-blocker-fix-lint.log`、`/tmp/mdown-t13-blocker-fix-format.log`；全量 xcresult：`/tmp/mdown-t13-derived/Logs/Test/Test-MiaoYan-2026.10.21_00-11-43-+0800.xcresult`。

### 实机

使用最新 Debug 构建的独立副本 `/tmp/mdown-t13-smoke/MdownT13Smoke.app`（单独 bundle ID `com.mdown.t13.smoke`、临时库），未编辑已安装 Mdown 的用户笔记：

1. CUA 以完整路径读取独立应用真实 AX 树与截图，窗口访问正常。
2. 测试库权限改为 `0500`，在 native 正文粘贴 ` save-error-check`。真实“保存失败”提示显示目录无写权限；用 `cmp` 确认磁盘仍等于编辑前原文，AX 正文保留草稿。
3. 恢复权限 `0755`，关闭先前多次保存排队的提示并保存，读取磁盘确认新文字已成功写入，Markdown marker 与 raw 块保留。
4. 在 unknown fenced code 的 `**literal**` 后粘贴字面文本，真实 ⌘Z / ⇧⌘Z 成功撤销/重做局部源码编辑，其他块未变化。
5. 撤销测试文字并保存，`cmp` 确认与实机操作前副本逐字节相同；目录权限恢复 `0755`；本任务独立应用已退出。

本轮观察到只读期间多次保存会排队多个错误提示，这是原有默认提示行为；本次未扩大为提示去重改造。此次只完成上述实机流程，未把真实中文 IME、Finder 拖放和图片属性弹窗矩阵标记通过。

## 2026-10-21 Computer Use 续验与修复

### 已核实的实机结果

- 中文输入：维护者明确反馈“中文输入已验证”，据此记录手工通过；Computer Use 自动按键没有独立完成候选窗全矩阵，不能将该结果标记成全自动验收。
- 真实 Finder 文件粘贴：PNG 插入 `/i/<uuid>.png`，普通 TXT 插入 `/files/<uuid>.txt`；源码位置与插入点一致。原始文件与新附件 SHA-256 分别一致：PNG `648acd16b4b42946ab13022efde0d3fa4a23494880900dd66d344c3895349362`，TXT `38fa0f8a122ef5ddb8ce75e13c2fe35f79791c2accaf35cbe6a72f7b2a700281`。两次插入均可撤销，撤销保留附件以供恢复。临时证据 `/tmp/mdown-t13-smoke/T13-finder-paste-evidence.json`。
- 修复零高度后，真实右键可显示四种剪贴板操作及“编辑图片”；图片属性弹窗显示 alt、URL、title 原值，已有截图和 AX 状态观察。属性修改保存的完整实机矩阵尚未完成，自动化属性编辑用例通过。
- 操作期间维护者输入的中文测试文字已保留；未用原始空白 fixture 覆盖它。附件粘贴撤销后的源码与 `/tmp/mdown-t13-smoke/T13-user-ime-baseline.md` 字节一致。

### 实机发现的两个缺陷

1. **文本视图高度为 0。** NSTextView 仍向边界外绘制，所以 AX 能读取文字且程序化输入可用，但真实鼠标命中测试失败，右键与拖放无法抵达正文。先加 DEBUG 尺寸日志，窗口内回归复现 `text={{0,0},{400,0}}` / `clip={{0,0},{400,300}}`，600×450 调整后仍失败。修复 host 的垂直自适应、随视口宽度换行、最小视口高度和 resize 布局；回归验证两个尺寸下正文可命中。日志 `/tmp/mdown-t13-geometry-red.log`，修复后相关测试 `/tmp/mdown-t13-geometry-green.log`。
2. **拖放生命周期判定不一致。** 修复命中区域后，维护者实际拖入 PNG/TXT 反馈“没有反应”，磁盘也没有新增引用。注入 NSDraggingInfo 的完整回调测试和 DEBUG 日志显示 `draggingEntered` 返回 copy，但继承的 `draggingUpdated` 返回 0、`prepareForDragOperation` 返回 false。修复为各阶段统一走本视图的接受判断，drop 时再次校验编辑/IME 状态与源 copy 能力，单文件验证不接受多文件；落点插入仍通过既有附件请求和历史。日志 `/tmp/mdown-t13-drag-red2.log` 明确记录两处行为断言失败，修复后 `/tmp/mdown-t13-drag-green.log` 相关 **45/45** 通过。

诊断日志代码已移除，未保留临时 instrumentation。新增覆盖包含上下文菜单动作目标、视口 resize 命中、完整拖放回调→真实文件写入→source 落点→撤销，以及只读/marked/move-only/多文件拒绝。

### 最新验证与剩余项目

- 全量 **485/485，0 failures**，日志 `/tmp/mdown-t13-drag-full.log`，xcresult `/tmp/mdown-t13-derived/Logs/Test/Test-MiaoYan-2026.10.21_01-49-00-+0800.xcresult`。
- Debug build **BUILD SUCCEEDED**，日志 `/tmp/mdown-t13-drag-build.log`；16 个改动 Swift 文件严格 lint/format 通过，日志 `/tmp/mdown-t13-drag-lint-final.log`、`/tmp/mdown-t13-drag-format-final.log`。pbxproj、本地化 plist 与 `git diff --check` 通过。
- Computer Use 的 Finder 拖动接口在跨窗口和窗口内均返回 `noWindowsAvailable`；读窗口、右键、复制粘贴可用。因此请维护者对已更新的独立修复版重复真实拖放，代理负责核对 source、附件字节和重开结果；当前等待这次修复版复验结果，不把前一次失败记成通过。
- 原生附件异步返回时的切换/删除 anchor、IME 拒绝已由真实文件自动化验证；完整人工竞态矩阵与图片属性保存仍按未验证范围保留。所有改动未提交、推送。

## 2026-10-21 拖放修复版人工复验（通过）

维护者在修复版 smoke app 中真实拖入 Finder 的 `DropFixtures/T13-drop.png` 与 `T13-drop.txt`（均在代码块/数学块外的正文末尾），并确认屏幕出现插入内容。代理随后核对：

- 磁盘源码新增 `![T13-drop](/i/29fa5721-a9f6-4a25-85b6-84ba33f45ad0.png)` 与 `[T13-drop](/files/623a8bb0-3820-4727-97de-658275bb9f20.txt)`，引用落点在正文，未进入 raw 块。
- 新附件 SHA-256 与 fixture 逐字节一致：PNG `648acd16…349362`，TXT `38fa0f8a…a700281`；图片进 `i/`，普通文件进 `files/`，UUID 命名。
- 退出并重开 app：磁盘文件字节稳定（重开前后 `cmp` 一致），AX 读取正文完整渲染两个新引用（`T13-drop` ×2），此前粘贴产生后又撤销的旧附件与用户中文输入内容保留不变。
- 复验所用二进制与本轮源码一致（改动时间戳核对，`MiaoYan.debug.dylib` 为 2026-10-21 01:48 修复版构建）。

至此 T13 的实机拖放路径（命中区域、拖放生命周期、落点引用、附件写入、重开持久化）全部验证通过；未验证边界仅剩图片属性修改保存的完整人工矩阵，已在上文保留记录。
