# T07 — Note commit、write outcome 与 dirty revision

日期：2026-10-16。基线：T06 head `0c29317` 之上。

## 交付

- **`Business/Note.swift`**：
  - `NoteSaveOutcome`（saved / noChanges / retired / failed / superseded）与
    `NotePendingWriteIdentity`（url + generation + revision + digest）。
  - `editGeneration`（rename/rebind/retire 时 +1）、`committedRevision`
    （每次 commit 新内容 +1）、`inFlightWrite` 捕获记录。
  - `executeSave` 拆为 capture（写前捕获完整四元组）→
    `performDiskWrite`（纯磁盘半，无 dirty 簿记）→
    `completeSave`（完成时校验四元组 + 当前 content digest，全部匹配才
    清 dirty；不匹配报 `.superseded`，失败报 `.failed` 保留 dirty）。
    `completeSave` 同时是测试接缝，直接驱动在途写竞态。
  - `commit(content:)` 最小 commit 接口：即时标 dirty + revision，1.5s
    debounce 不变；`save(content:)` / `save(globalStorage:)` 保持兼容入口
    转发；新增 `saveReturningOutcome` / `flushPendingSaveOutcome` 可观察
    结果 API。
  - BOM 修复：`performDiskWrite` 检测目标文件既有 UTF-8 BOM，写前重建
    wrapper 字节（PLAN T07「修 byte encoding path，不伪装 memory 测试」）。
  - `overwrite(url:)`、`retireAfterRemoval` 推进 generation；retire 清
    `inFlightWrite`，旧写完成只能得到 `.superseded`，不复活删除文件。
- **`MiaoYan.xcodeproj/project.pbxproj`**：新测试文件注册 4 处，纯 24-hex ID。
- **`MiaoYanTests/EditorCommitPersistenceTests.swift`**（新增，13 用例）：
  commit 即时 dirty/revision、outcome 各态、在途 rev1 完成晚于 rev2 仍
  dirty（退门口）、同 URL rebind 同号 revision 拒绝旧完成、失败保留
  dirty 且重试成功、CRLF / 无尾换行 / BOM 经 FileWrapper 落盘再读实测、
  500 次 keystroke commit 的镜像正确性与延迟上界（<2s，实测 0.006s）。

## 关键设计决定

1. **清 dirty 的唯一条件**：写盘成功 ∧ url/generation/revision 与捕获时
   一致 ∧ 捕获 digest == 当前 content digest。rebind 后同号 revision 由
   generation 挡住（SPEC §7.1 显式要求）。
2. **版本记录 / Wikilink 仍跟随真实落盘内容**（写成功后在
   performDiskWrite 内更新），不跟随内存镜像；superseded 的写已真实落盘，
   版本记录合法，dirty 保留使更新内容仍待写。
3. **未新增外层 timer**，沿用 1.5s debounce 与即时 dirty 登记；commit
   路径不做整篇 unLoad/重扫描。
4. 即时 save 调用点（`ViewController+Editor.swift` cleanTypography/
   format、`ClipboardManager.swift` 粘贴）经 `save()` →
   `saveReturningOutcome` 兼容转发自动接入，无需改调用点；结果消费
   （失败 toast 语义）留给 T08 TransitionCoordinator。

## 验证（2026-10-16，本机）

- `EditorCommitPersistenceTests`：13/13 通过。
- 全套：317 tests（T06 基线 309 + 13 新增 - 既有计数差异），失败仅
  3 个既有环境用例（2 Mermaid + 1 Math，T06 基线已存在）。
  注：本机 Xcode 27 要求 `MACOSX_DEPLOYMENT_TARGET=12.0` 命令行覆盖
  （仓库设置 11.5，CI macos-15 的 Xcode 不受影响，未改仓库设置）。
- swiftlint --strict 0 violations、swift-format --strict 0 errors。
- BOM 用例先红后绿：修复前 `testSaveRoundTripPreservesUTF8BOM` 失败
  （NSAttributedString plain writer 丢 BOM），按 PLAN 修 byte path 后通过。

## 有意不做（已记录在案）

- **watcher/rename/Trash 的 generation 语义接线**：T09 职责；T07 只提供
  generation 基础设施与 rename 接线。
- **失败 outcome 的 UI 消费**（Retry/Save Copy/Discard）：T08
  EditingTransitionCoordinator 职责。
- **flushPendingSaves（Storage）返回 per-note outcome 明细**：当前 Bool
  足够，T08 需要逐 note 失败清单时再扩展。
- **增量 patch/COW commit 的分配 profiling**：当前 commit 即 COW 镜像，
  延迟测试 500×keystroke commit 0.006s，无整篇重保存成本；专项
  Instruments 分配分析留到 T10 投影层统一后。
