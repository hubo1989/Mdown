# T10 — 正式 Rich view host 与布局兼容

日期：2026-10-19。基线：T09 head `dbe7dda` 之上。

## 交付

**协议与路由（`Business/Types.swift`）**
- `WysiwygEditingBackend` 协议：`currentNote` / `loadNote` /
  `flushPendingSave(completion:)` / `focus` / `updateAppearance`。native rich
  与 legacy Vditor 经同一协议面被布局层触达；`VditorEditView` 以零改动
  extension conform（SPEC §13：稳定门通过前 Vditor 不与 native 同时发布正文）。
- `ViewController.activeWysiwygBackend`：按 `useNativeWysiwyg` 路由
  （native 默认）；`setVisibleWysiwygBackend` 保证同一时刻只有一个 backend
  可见/被装载。所有 `vditorEditView` 直连点（enableWysiwyg/disableWysiwyg/
  revealEditor/refillEditArea/focusEditArea/captureSessionSourceForVersion/
  enablePresentation/enableMiaoYanPPT/Data 路径/NotesTableView/T08 采集面）
  全部改经协议路由。

**native host（新 `Views/NativeRichEditorHostView.swift`）**
- NSScrollView + RichMarkdownTextView 宿主，与 Vditor 同位
  （editorContainer 全幅 Auto Layout）。
- 保存语义与 Vditor 对齐（AC-22 无新保存定时器类型）：source 提交
  （`RichMarkdownTextView.onSourceCommitted`，didSet 实现）即时镜像
  `note.content`；0.5s debounce 后 `note.save(content:)` commit；切换笔记/
  flush 前先 persist 旧草稿（NE-36 不丢草稿）；`persistNote` 走
  `blockFSUpdates`。同步磁盘写归 Note 层（`flushPendingSaveOutcome`），由
  T08 协调器在离开点统一调用——与 Vditor persistNote 同层，不越权。
- 装载竞态：`loadToken` 守护，晚到异步装载拒绝写新 currentNote
  （测试经 `applyContentLoadedForTesting` 注入）。
- 失败降级（NE-36）：磁盘读取失败经 `onNoteLoadFailure` 上报，
  `handleNativeWysiwygLoadFailure` 仅该笔记在本次会话内回 source 显示，
  **不写全局 layout pref**（`wysiwygLoadFailureNote` 会话内标记）。
- Trash 只读；selection 锚点与笔记身份（ObjectIdentifier）绑定，进
  preview/presentation/PPT/切布局前保存、退出恢复（AC-16）。
- 外观（NE-32 基础）：`RichMarkdownTextView` 增 `bodyFont` / `codeFont` /
  `contentTextColor` 注入面 + `refreshFontAttributes()`；host 应用
  字体/字号/深浅色前景与光标色。

**布局与入口**
- ⌘3 / Toggle Preview（AC-16）：`togglePreview()` 改纯 preview 进出
  （enablePreview/disablePreview），不再把布局切到 wysiwyg；退出经
  `restoreEditorLayoutAfterPreview` 回 saved layout（含 wysiwyg）。
  preview/presentation/PPT 右侧继续用 `MPreviewView` 挂
  `previewScrollView.documentView`（现状保留，未新建平行预览类）。
- wysiwyg 独立入口：storyboard View 菜单新增 `Toggle WYSIWYG`
  （`viewMenu.toggleWysiwyg`，无 keyEquivalent——⌘0–5 不新占，经 First
  Responder 转发，outlets/actions 原样）；四份 Main.strings 补 ObjectID
  标题（zh-Hans/zh-Hant/ja/es）。
- pref（NE-01）：`editorLayoutMode` 迁移语义保持（stored 优先 → legacy
  splitViewMode 迁移 → 新用户 source；读取无写副作用）；新增
  `useNativeWysiwyg`（默认 true；`defaults write` 可回退 legacy Vditor，
  开发期逃生舱，无设置 UI）。降级 toast 文案入四份 Localizable.strings。
- 设置面板三段编辑模式（source/split/wysiwyg）维持不变。

## 验证（本机系统故障恢复后完整执行）

| 项 | 结果 |
|---|---|
| Debug build（`MACOSX_DEPLOYMENT_TARGET=12.0 CODE_SIGNING_ALLOWED=NO`） | **SUCCEEDED**（含新 storyboard 菜单项 ibtool 编译） |
| `NativeEditorModeMigrationTests` | **16/16 passed**（TDD 红→绿；两次红各暴露一个真问题：插入 display 偏移计算、host/Note 的 commit/落盘分层断言错位） |
| 全量单测 | **375 tests，失败仅 3 个既有环境用例**（2 Mermaid + 1 Math，Sandbox restriction，与 T08/T09 基线一致）；`VditorIntegrationTests.testEnableWysiwygModeSetsLayoutVisibility` 按新 backend 语义更新断言后 10/10 绿 |
| swiftlint --strict | 0 violations（全仓 178 files） |
| swift-format --strict（改动文件） | 0 violations |
| 实机 UI 冒烟（菜单驱动 + AX + 截图像素 diff） | 见下 |

### 实机 UI 冒烟记录

菜单驱动（System Events）+ AX 元素树 + 窗口截图像素 diff：

1. **Toggle WYSIWYG 进入 native 投影**：菜单项存在于 View 菜单（顺序在
   Toggle Split View 后、Toggle TOC 前，无快捷键）；点击后 AX textArea
   显示的笔记正文 **0 处 markdown 标记**（对照磁盘原文 `INDEX.md` 的 22 处
   `#`/列表标记）——投影 marker 隐藏生效，native backend 真实工作。
2. **⌘3 纯 preview 往返**：进 preview 截图与其余状态 7.70% 像素差异
   （MPreviewView 独占）；退出后与进 preview 前的 wysiwyg 帧 **0.00%**
   像素一致——退出回 saved layout 成立（AC-16）。
3. **source→split**：23.25% 像素变化，布局正常建立。
4. **既有问题（非本次回归）**：从 wysiwyg 点"切换分栏"无视觉变化
   （无 AXWebArea、截图 0.00% 相同）。在 **T09 干净 HEAD 上同样复现**
   （Vditor wysiwyg→split 同样 0.00%），属既有布局问题，登记不顺手修；
   从 source 进 split 正常，用户有可用路径。

### 本机环境故障与恢复（过程记录，最终不影响结果）

12:05–14:10 期间 `xcodebuild test` 以 *runner hung* 失败，期间证据：干净
T09 HEAD 同样挂；测试宿主卡 dyld `__open`（sample×2）；CoreSimulatorService
（版本 1171.7/1174.9.2 错配）、`simctl`、System Events 同期死锁。14:10
系统自行完成组件安装并清除 stale 服务（simctl 恢复），随后全部验证补跑
完成。期间记录过"栈式 PR 不触发 CI"（`ci.yml` 只认 `pull_request:
branches: [main]`）仍为事实：合栈到 main 前 CI 不跑这些用例，本机已全量
执行。

## 未验证范围

- native rich 面的逐键投影编辑体验（G0 已证可行，T11 范围）。
- legacy Vditor 回退路径的实机往返（`useNativeWysiwyg=false` defaults 写入
  后 enableWysiwygMode 走 Vditor——协议同面，编译期保证 + 语义测试更新，
  未实机驱动）。
- wysiwyg→split 布局既有问题（T09 已存在，见上）。
