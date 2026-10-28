# T05 — 正式 MarkdownEditingSession 与源码接入

日期：2026-10-16。基线：PR #1 head `1d84892`（T00–T04 + 两轮 review 修复）之上。

## 交付

- **`Business/MarkdownEditingSession.swift`**（正式类，SPEC §5 拟定 API）：
  `init(identity:markdown:selection:isReadOnly:)` revision=0 基线、`snapshot`、
  `apply(_:) -> EditApplyResult`（retired → owner → generation → revision →
  readOnly → patch 原子校验；noChange 不推 revision；rejected 不回退）。
  生命周期：`rebind(url:markdown:)`（同 URL 复用）、`replaceAll(markdown:)`
  （全量替换 + generation+1 + revision 归零）、`rename(to:)`、`retire()`。
  buffer 防护：`markStoragePublished()` 记录 **(generation, revision) 二元组**，
  `storageIsStale` 同时比对两者。任务身份：`currentJobContext` /
  `accepts(resultFor:)` latest-wins（parse/attachment/write 完成回调共用，
  T07/T10 接入消费）。
- **`Views/EditTextView+EditingSession.swift`**（extension）+ EditTextView 主类
  （属性 + mutator）：
  - `publishStorage` 发布即登记会话新基线（同 URL 复用/replaceAll 提代际，
    URL 变化新开会话）——模板、版本恢复等整篇调用点无需各自维护 revision。
  - `saveTextStorageContent` 在 #543 owner guard 之后追加 revision 防护：
    退役 note（顺带 retire 会话）与失效 buffer 的整篇写回拒绝
    （trackError code 4）。
- `Business/Note.swift`：新增 `isRetiredForEditing` internal 只读访问器
  （存储保持 private）。
- pbxproj：3 个新文件注册 4 处，纯 24-hex ID。

## 关键设计决定（实现即合同）

1. **buffer 防护必须比对 (generation, revision)，不能只比 revision 数字**。
   `replaceAll` 归零 revision 后，旧 buffer 的 revision 数字与新基线相同——
   首版实现只比数字，`storageIsStale` 恒 false，`testStaleBufferRevisionCannotWholeSave`
   当场抓红。这正是 PLAN §5 表格 `testWriteFromOldGenerationCannotClearSameRevisionDirty`
   预言的陷阱在 buffer 维度的形态。
2. **T05 不做逐键 apply**：source 模式 buffer 的附件化文本（NSTextAttachment
   U+FFFC、checkbox）与 raw source 的映射是 T10 投影层职责；强行跟随会让
   session.markdown 吸入 FFFC。因此 revision 的推进点是程序化整篇替换
   （publishStorage/replaceAll）与后续接入的命令入口；正常输入路径下
   buffer 与会话同处基线 revision，防护零误伤
   （`testTypingThenSaveStillWorksUnderSessionGuard` 固定）。
3. **`retire()` 的消费时机**：Note 层 `isRetired` 已在全部保存入口 fail
   closed；本阶段在保存入口做防御性同步（retired note → session.retire()）。
   watcher/upload 等 in-flight 任务的失效消费者按计划在 T07/T08 接入。

## 验证（2026-10-16，本机）

- `MarkdownEditingSessionTests`（13）：PLAN §5 oracle 原文
  （testOldRevisionDoesNotOverwriteNewText）、重叠原子拒绝、expectedText
  拒绝、半代理拒绝/完整 emoji、CRLF+BOM 20 次 no-op hash 不变、readOnly、
  跨 owner 拒绝、replaceAll 代际失效、rebind 同 URL/异 URL、rename 身份
  失效、retire 全拒且不可复活、jobContext latest-wins（rev1 结果在 rev2
  后拒绝）、buffer 发布身份跟踪。
- `EditorStorageOwnershipTests` 扩展（3）：
  `testStaleBufferRevisionCannotWholeSave`（旧 buffer rev0 不得覆盖 rev1 的
  v2——PLAN §5 testSameOwnerStaleBufferCannotSave 的 source 模式形态）、
  `testTypingThenSaveStillWorksUnderSessionGuard`（防护不误伤正常输入）、
  `testPublishStorageRebasesSessionAndKeepsGuardAligned`（发布即重定基线）。
- 全套：**291 tests，8 failures = 3 个既有环境性 WKWebView 用例**
  （KaTeX/Mermaid sandbox，PR #1 基线同款），无新增失败。
- `swiftlint lint --strict` 0 violations（171 files）；
  `swift-format 604.0.0 lint --strict` 0 errors（CI 同版本）。
- EditTextView.swift 经抽取 extension 控制在 1988 行（file_length ≤2000）。

## 未验证 / 留后续

- `retire()`/`rename(to:)` 的 watcher、upload 回调、TransitionCoordinator
  消费者（T07/T08）；selection 字段的视图同步（T06 viewstate 正式化）；
  rich 视图接入（T10+）。
- 实机 UI 冒烟（note 切换/模板替换/Trash 后保存拒绝）依赖 T07 完整链路，
  本阶段以单测覆盖接口合同。
