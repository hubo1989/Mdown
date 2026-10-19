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
  `note.content`；0.5s debounce 落盘；切换笔记/flush 前先落盘旧草稿
  （NE-36 不丢草稿）；`persistNote` 走 `blockFSUpdates` + `note.save(content:)`。
- 装载竞态：`loadToken` 守护，晚到异步装载拒绝写新 currentNote
  （测试经 `applyContentLoadedForTesting` 注入）。
- 失败降级（NE-36）：磁盘读取失败经 `onNoteLoadFailure` 上报，
  `handleNativeWysiwygLoadFailure` 仅该笔记在本次会话内回 source 显示，
  **不写全局 layout pref**（`wysiwygLoadFailureNote` 会话内标记）。
- Trash 只读；selection 锚点（`saveSelectionAnchor` /
  `restoreSelectionAnchor`）与笔记身份绑定，进 preview/presentation/PPT/
  切布局前保存、退出恢复（AC-16）。
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
  （`viewMenu.toggleWysiwyg`，无 keyEquivalent——⌘0–5 不新占，storyboard
  经 First Responder 转发，outlets/actions 原样）；四份 Main.strings 补
  ObjectID 标题（zh-Hans/zh-Hant/ja/es）。
- pref（NE-01）：`UserDefaultsManagement.editorLayoutMode` 迁移语义保持
  （stored 优先 → legacy splitViewMode 迁移 → 新用户 source）；新增
  `useNativeWysiwyg`（默认 true；`defaults write` 可回退 legacy Vditor，
  开发期逃生舱，无设置 UI）。降级 toast 文案入四份 Localizable.strings。
- 设置面板三段编辑模式（source/split/wysiwyg）维持不变。

## 验证

| 项 | 结果 |
|---|---|
| Debug build（`MACOSX_DEPLOYMENT_TARGET=12.0 CODE_SIGNING_ALLOWED=NO`） | **SUCCEEDED**（含新 storyboard 菜单项 ibtool 编译） |
| swiftlint --strict（改动文件） | 0 violations（全仓 178 files 0 violations） |
| swift-format --strict（改动文件） | 0 violations |
| 本机单测（`NativeEditorModeMigrationTests` 16 用例） | **blocked（环境故障，见下）**；转 CI 执行 |
| App 冒烟 | 启动/quit 正常（open + AppleScript quit） |
| 实机 UI 冒烟（菜单驱动） | blocked（System Events AppleEvent 超时，同环境故障） |

`NativeEditorModeMigrationTests` 覆盖：迁移语义 6 例（新用户 source、legacy
split 迁移、stored 优先、读取无写副作用、wysiwygMode setter 边界、
useNativeWysiwyg 默认）+ 协议面 2 例（编译期 conformance 证明）+ host 8 例
（投影装载、编辑镜像+flush 落盘、切换笔记落盘旧草稿、Trash 只读、晚到装载
竞态、selection 锚点往返、⌘3 纯 preview 源码断言、backend 路由源码断言）。

## 本机测试环境故障记录（非代码回归）

2026-10-19 12:05 起，`xcodebuild test` 全部以 *test runner hung before
establishing connection* 失败。证据链：

1. **干净 T09 HEAD（`dbe7dda`，stash 后）跑既有 `StringExtensionsTests`
   同样挂**——排除本次代码引入。
2. 测试宿主进程被拉起（带 XCTest 参数）但主线程 100% 卡在 **dyld
   `loadDependents` → `__open` 系统调用**（`sample` 抓栈，两轮复现），
   宿主永远到不了 main()。
3. 宿主 env 含 `DYLD_INSERT_LIBRARIES=/usr/lib/libRPAC.dylib:...`（系统
   注入）；同时 `CoreSimulatorService` 死锁（`xcrun simctl list` 无响应，
   pkill 后仍复现）、`System Events` AppleEvent 超时——系统级进程启动/IPC
   故障，非项目因素。
4. `MiaoYan.app` 直接启动正常（上表冒烟通过），构建链路全程正常。

处理：单测验证转 CI（`.github/workflows/ci.yml`：macos-15 +
CODE_SIGNING_ALLOWED=NO，与 BASELINE §2 记录的可行组合一致）。本机故障
疑似需重启恢复；重启属破坏性操作，未执行，待维护者决定。

## 未验证范围

- 实机 UI 冒烟（Toggle WYSIWYG 菜单点击、⌘3 纯 preview 往返、设置面板
  三段切换、preview/PPT 退出回 wysiwyg）——环境恢复后执行；CI 单测只覆盖
  迁移/host 逻辑与源码断言，不覆盖视觉路径。
- native rich 面的逐键投影编辑体验（G0 已证可行，T11 范围）。
- legacy Vditor 回退路径的实机往返（`useNativeWysiwyg=false` defaults 写入
  后 enableWysiwygMode 走 Vditor——协议同面，编译期保证，未实机驱动）。
