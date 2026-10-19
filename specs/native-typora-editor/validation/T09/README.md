# T09 — watcher、rename、Trash、版本恢复与异步附件

日期：2026-10-19。基线：T08 head `40598ab` 之上。

## 交付

**会话侧（`Business/MarkdownEditingSession.swift`）**
- `pendingExternalContent`：watcher 检测到外部版本但本地 dirty 时保留的
  外部正文（SPEC §7.3：保留双方、不自动覆盖、不宣称三方合并）。
- `reloadFromDisk(externalContent:hasLocalChanges:)`：无本地改动 → 全量
  替换为磁盘真值 + 代际提升（返回 true）；有本地改动 → 只记录外部版本
  （返回 false），会话基线与代际都不动。
- `adoptPendingExternal()`：用户显式接受保留的外部版本（local recovery
  trigger，不是保存成功）。
- `replaceWithRestoredVersion(markdown:)`：版本恢复的显式 source
  replacement。
- `isRetiredForSave` / `canonicalURL` / `undoHistoryTargetsCurrentBaseline`
  暴露：退役写入拒绝语义（区别于「这不归我管」）、rename 比对、恢复前
  undo 是否仍指向当前基线。

**编辑器侧（`Views/EditTextView+EditingSession.swift`）**
- `applyExternalFileChange(_:owner:)`：watcher 外部变化的统一入口。dirty
  判定 = `owner.needsSave || session.storageIsStale`（以会话/Note 提交状态
  为准，不看 table selection，#543）。干净时经新原语
  `publishStorageWithoutRebasingSession` 重新发布 buffer（不二次 rebase 会话，
  避免代际双跳）；dirty 时保留双方。
- `adoptPendingExternalVersion(owner:)` / `applyRestoredVersion(_:owner:)`：
  显式接受外部版本 / 版本恢复。恢复前若 undo 历史已不指向当前基线，清空
  note.undoManager（Cmd-Z 不得把恢复前正文带回编辑器；必须在重新发布前
  取值——发布会把 storageGeneration 对齐回去）。
- `syncSessionAfterRename(of:)`：rename/move 成功后同步会话 canonical URL
  并提升代际（旧 URL 捕获的任务身份失效）；URL 未变时 no-op 不白推代际；
  重新登记发布身份使改名后第一次正常保存不被 revision guard 误伤。
- `captureEditingJobContext()` / `editingSessionAccepts(resultFor:)`：异步
  任务（上传）启动捕获、完成核对；无会话时放行（legacy 行为）。
- `editingSessionAllowsSave` 补退役拒绝：会话存在但已退役时必须拒绝整篇
  写回，而不是经 `owns(url:)==false` 掉进「无会话」放行分支——否则 buffer
  会写进已删除的 Note 实例。
- `saveTextStorageContent` 迁至本扩展文件（主文件触 2000 行上限；方法本
  就是 owner/会话守卫主题）。字节赋值原语留在主文件（`storageNote` 的
  `private(set)` 不放宽）。

**接线**
- `FileSystemEventManager.reloadNote`（NE-19）：buffer owner（storageNote，
  非 table selection）匹配的活动笔记走会话路径——干净：全量替换 + 代际
  提升 + note.content 同步 + refill（fill 从 note.content 重新发布，必须先
  更新否则 buffer 翻回旧正文）；dirty：备份本地草稿（buffer 即 session 权
  威正文）+ toast + 返回，不清 history、不 refill 覆盖。非活动笔记保持原
  有直接重载行为。
- rename/move（`ViewController+Action.fileName` / `move(notes:project:)`、
  `ViewController+Editor.saveTitle`）：成功后 `syncSessionAfterRename`。
  `fileName` 另补 T08 网关（改名是硬保存点：提交组合输入、dirty 先落盘、
  失败四选一；不再绕开 coordinator 直接 moveItem）。
- 版本恢复（`VersionHistoryViewController.restoreAction`）：先捕获 session
  提交原文 → 恢复前快照（history policy）→ `applyRestoredVersion` 显式替
  换（代际提升 + buffer 重发布 + 清恢复前 undo）→ `note.commit` 落盘；
  buffer owner 不匹配时退回原 `save+fill` 路径。
- 版本快照三处 local recovery trigger（导航离开 `EditTextView.fill`、打开
  面板 `showVersionHistory`、恢复前）：新增
  `captureSessionSourceForVersionSnapshot(of:)` 先把活动 buffer 已确认原文
  采集进 note 镜像（owner 不匹配安全 no-op），快照才是用户实际所见正文；
  与真实写盘成功保存的版本（`Note.performDiskWrite` 路径）在注释中明确
  区分。
- 上传结果绑定（`ClipboardManager`，NE-22）：PicGo/PicList 与 uPic/Picsee
  两条上传链在启动时 `captureEditingJobContext()`，完成回调核对——会话代
  际已推进（watcher 重载/rename/退役）时整个结果作废（trackError 记录），
  不插当前 buffer、不追加进 note。
- 孤立附件清理（`Storage.removeAttachments`）：去掉 Trash 失败后的
  `removeItem` 硬删兜底——只走可恢复路径，失败上报（无任意删除）。

**测试**：`MiaoYanTests/EditorFileSyncTests.swift` 新增 20 用例（pbxproj 4
处注册）。

## 关键设计决定

1. **dirty 保留双方的真实语义**：外部版本留在磁盘 + 记入
   `pendingExternalContent`，本地草稿留在 buffer/镜像；不清 history、不
   refill 覆盖。用户后续保存草稿即「本地赢」（外部版本此前已备份），或经
   `adoptPendingExternalVersion` 显式接受外部版本。不提供自动三方合并。
2. **会话与 buffer 各推进一次**：`replaceAll` 只在会话侧发生一次，buffer
   经 `publishStorageWithoutRebasingSession` 跟随（对齐发布身份而不重
   rebase）。否则代际双跳，`storageIsStale` 防护与断言都偏离真实代际。
3. **恢复前 undo 清空必须在重发布前判定**：重发布会把 storageGeneration
   对齐回新代际，之后再问「undo 是否指向当前基线」恒为否，防护失效。
4. **退役会话 ≠ 无会话**：`owns(url:)` 在退役后同样返回 false，但两者的
   调用方语义不同（拒绝写入 vs 不归我管）。写入防护必须区分。
5. **上传身份用捕获快照而非回调时状态**：只有启动时的 JobContext 才能
   证明「结果属于发起时的正文」；回调时查询当前状态无法区分「一直没变」
   与「变过又变回来」。

## 验证（2026-10-19，本机）

- `EditorFileSyncTests`：20/20（watcher 干净重载代际提升/不登记 undo、
  dirty 保留双方+记录外部版本、显式接受、rename 代际+旧身份失效+保存不
  误伤、URL 未变 no-op、同 URL 新实例 rebind、退役全路径拒绝+不重建文件、
  版本恢复显式替换+清 undo+保存恢复版、上传结果绑定捕获身份/无会话不误
  伤/退役拒绝）。
- 迁移面回归：`EditorStorageOwnershipTests` + `NoteSaveDebounceTests` +
  `EditingTransitionTests` + `MarkdownEditingSessionTests` +
  `EditorCommitPersistenceTests` + `MarkdownCompositionTests` +
  `RichMarkdownEditingTests`：91/91。
- 全套 359 tests：失败仅 3 个既有环境用例（2 Mermaid + 1 Math，与 T08 基
  线一致；8 为断言计数）。本机仍需 `MACOSX_DEPLOYMENT_TARGET=12.0` +
  `CODE_SIGN_IDENTITY=-` 覆盖。
- swiftlint / swift-format --strict：改动文件 0 violations（EditTextView.swift
  1988 行，回低于 2000 上限）。
- Debug 构建通过；启动 + osascript quit 冒烟干净退出。

## 有意不做（已记录在案）

- dirty 外部冲突的专门选择 UI（「采用外部/保留本地」面板）：会话已保留
   双方并留有 `adoptPendingExternalVersion` 入口，UI 属后续任务；当前用
   toast + 冲突备份兜底。
- `FileSystemEventManager.reloadNote` 的 delegate 面（备份文件写入、toast、
   refill）无直接单测——需要 ViewController 实例；决策逻辑全部在会话层
   覆盖，delegate 走的是未改动的既有机制。
- 版本 key 随 URL 变化（rename 后版本历史在新 key 下不可见）：既有行为，
   修复需要稳定 note 身份或版本目录迁移，超出 T09 范围。
- 上传插入点的 anchor 漂移（用户在锚点前继续输入）仍按当前光标插入：
   PLAN 的 placeholder/anchor 细化属 T13。
