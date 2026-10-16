# T08 — 离开前 TransitionCoordinator

日期：2026-10-16。基线：T07 head `7d04dd0` 之上。

## 交付

- **`Controllers/EditingTransitionCoordinator.swift`**（新增）：
  - 统一入口 `finishActiveEditing(in:forceCompositionFinish:)`：
    finish-composition（源码后端 `unmarkText`，NE-13）→ 从活动后端
    capture（wysiwyg 时 Vditor 权威，source 时 `saveTextStorageContent`
    的 owner guard）→ flush 活动笔记。`forceCompositionFinish=false`
    用于失焦/进 preview 等编辑器仍在上下文的点，不打断进行中的 IME。
  - 可取消前置：`prepareExit`（关窗/退出）、`prepareNoteSwitch`（切
    笔记，捕获后立即整篇写盘不等 1.5s debounce）、`saveAllNow`
    （Cmd+S，Cancel 无「阻止离开」语义只留 dirty）、
    `prepareCommandTargeting`+`flushOrResolve`（rename/move/duplicate）。
  - 失败四选一循环：Retry / Save Copy（NSSavePanel，副本确认写成功才
    放行；原笔记保持 dirty 原状，同一网关内不重复处理）/ Discard（只丢
    会话草稿）/ Cancel（阻止离开）。UI 经 `EditingTransitionPresenting`
    协议注入，测试用脚本桩。
  - `EditingTransitionContext` 协议 + ViewController conformance
    （activeEditingNote / finishSourceComposition / captureActiveBuffer /
    dirtyNotes）。
- **`Business/Note.swift`**：`discardUnsavedChanges()`——取消 debounce、
  generation+1（在途写完成只能 `.superseded`，不复活草稿/不清新
  dirty）、`forceReload()` 回到磁盘真值；不删磁盘文件。
- **`Views/EditTextView.swift`**：`finishActiveComposition()`
  （`hasMarkedText`/`unmarkText`）。
- **接线**：
  - `MainWindowController`：新增 `windowShouldClose`（可取消网关）；
    `windowWillClose`/`windowDidResignKey` 改走统一入口（前者
    force=true 最后兜底，后者 force=false 不打断 IME）。
  - `AppDelegate`：新增 `applicationShouldTerminate`（terminateCancel
    可取消）；`applicationWillTerminate` 改静默兜底。
  - `NotesTableView.handleSelectionChange`：切笔记前经
    `prepareNoteSwitch`；被阻止时还原选中行（沿用 export-guard 的
    `selectRowIndexes` 模式）。
  - `ViewController+Action`：Cmd+S、duplicate、`move(notes:project:)`；
    `ViewController+Editor`：`saveTitle`（改名前先落盘草稿）、
    `enablePreview`（进 preview 前采集活动 buffer）。
  - `Helpers/ActiveEditingBackend.swift` 删除（T01 临时 adapter 按
    计划收敛，pbxproj 4 处一并移除）；既有 3 个调用点的等价逻辑进入
    coordinator。
- **本地化**：4 语言（es/ja/zh-Hans/zh-Hant）各 +5 键（失败告警与
  Retry/Save Copy…/Discard Changes；Cancel 已存在）。
- **测试**：`MiaoYanTests/EditingTransitionTests.swift` 新增 17 用例；
  `EditorStorageOwnershipTests`/`NoteSaveDebounceTests` 的 3 个硬保存点
  用例迁移到统一入口（经 `BackendCaptureStubContext`）。

## 关键设计决定

1. **失焦不打断 IME**：resignKey/进 preview 用 `forceCompositionFinish:
   false`——用户回到窗口时组合状态保持；真正离开点（切笔记/关窗/退出/
   Cmd+S/duplicate/rename）才 force 提交。组合无法提交时网关返回阻止，
   不捕获 hidden buffer（NE-13）。
2. **Save Copy 不动原笔记**：副本写到用户选定位置后放行离开，原笔记
   保持 dirty；同一网关内已用 Save Copy 解决的笔记不再进入第二轮
   flush/告警（否则死循环：dirty→告警→Save Copy→仍 dirty→…）。
3. **Discard 是显式会话草稿丢弃**：generation+1 + forceReload，磁盘
   文件不动；在途写完成按 T07 身份校验返回 `.superseded`。
4. **切笔记保持原语义**：捕获后无条件立即整篇写盘（不是仅 dirty 才
   flush），与原 `save(content:)` 行为一致，程序化 buffer 变更不会因
   未标 dirty 而丢捕获。
5. ** ViewController+Data.swift:409/425 未改**：PLAN 列出的这两处在
   启动自愈路径上（`EditTextView.note == nil`，无 outgoing 草稿），
   网关无对象，保持原样。

## 验证（2026-10-16，本机）

- `EditingTransitionTests`：17/17（统一入口顺序、组合阻断、退出/切换
  网关各分支、Retry/Save Copy/Discard/Cancel、0.5s 空窗同步落盘、
  discard 的 stale 写 superseded）。失败注入用目录 chmod 只读 +
  `onAlert` 钩子解除，走真实 FileWrapper 写盘路径，非 memory-only。
- 迁移套件 `EditorStorageOwnershipTests` + `NoteSaveDebounceTests` +
  `EditorCommitPersistenceTests`：34/34。
- 全套：339 tests，失败仅 3 个既有环境用例（2 Mermaid + 1 Math，
  T06/T07 基线已存在）。本机 Xcode 27 仍需
  `MACOSX_DEPLOYMENT_TARGET=12.0` 命令行覆盖 + `CODE_SIGNING_ALLOWED=NO`
  （本机无 Mac Development 证书；CI macos-15 不受影响，未改仓库设置）。
- swiftlint --strict 0 violations；swift-format --strict 0 errors（改动
  文件）。
- 冒烟：Debug 构建启动正常，osascript quit 干净退出（clean 状态经
  `applicationShouldTerminate` → terminateNow 路径）。
- 四选一告警的实际 UI（NSAlert 文案/按钮布局/NSSavePanel 交互）未做
  人工 GUI 冒烟，自动化只覆盖决策逻辑；发布前建议手动演练一次只读
  目录 + dirty 关窗。

## 有意不做（已记录在案）

- watcher/rename/Trash 的 generation 接线、外部冲突（dirty 外部修改）
  的专门 UI：T09 职责；T08 的 Rename/Move 前置只保证草稿先落盘。
- `ViewController+Editor.swift` 的 enableWysiwyg(~523)/refill(~1522)
  捕获路径未动：已有 owner 守卫，属 #543 buffer 所有权/T09 范围。
- 跨重启恢复库：不新增（退出门要求明确排除）。
