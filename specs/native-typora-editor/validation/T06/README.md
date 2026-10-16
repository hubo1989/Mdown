# T06 — 单一语义 UndoManager 与 composition 正式化

日期：2026-10-16。基线：T05 head `e958fd5` 之上。

## 交付

- **`Business/MarkdownEditorHistory.swift`**（正式化，替换 G0 原型）：
  - `record(_:)` 接收 `RecordInput`（patches/sourceBefore/selectionBefore/
    selectionAfter/origin/undoGroupID/name），避免 6 参 lint 违规。
  - `Entry` 增加 `origin`、`undoGroupID`、`recordedAt`；`Result` 不再携带
    revision——history 不拥有 revision 语义，调用方（view/session）推进。
  - typing 合并策略：同 origin、同 undoGroup、selection 紧贴、patch
    范围相邻、纯插入、未超 `coalescingInterval`（默认 1.0s，显式记录
    不盲抄 Typora 3s / Vditor 800ms）。
  - 非 typing origin（composition/paste/format/structure）一律独立成组。
  - 内存上限 `maxEntries = 200`（SPEC §9 显式预算），超限丢弃最旧。
  - `undo`/`redo` 恢复 selectionBefore/selectionAfter；redo 重放 patch
    到 entry.sourceBefore，base 不符时拒绝（不静默覆盖）。
- **`Views/RichMarkdownTextView.swift`**：
  - composition 正式化（SPEC §5.3）：`setMarkedText` 记录基线
    （source + selection），marked 期间 `textDidChange` 走
    `syncSourceFromDisplayWithoutHistory`（source 跟随 display，不登记
    历史），`insertText` 前置 `justUnmarked` 标记提交，提交时把整段
    marked 内容以 marked 前 source 为 base 一次成组记入 history。
    取消（setMarkedText("") + unmarkText）不产生历史。
  - undo/redo 推进 view 自己的 revision（每次外观变更都是新 revision，
    包括 undo），不回退 revision 冒充旧状态。
  - `applyStructurePatches` 的 origin 从 "typing" 改为 `.structure`。
- **`Views/EditTextView+History.swift`**（新增 extension）：
  - `withoutUndoRegistration(_:)`：程序化刷新（fill/版本恢复/外部
    重载）禁止 view 自动 undo 登记（SPEC §5.4「view 变化不登记编辑」）。
  - `breakTypingUndoGroup()`：显式结束 typing group 的公开入口。
  - `replaceText(_:in:)`：从主文件迁入的辅助方法（控制主文件行数）。
- **`Views/EditTextView.swift`**：
  - `publishStorage` 用 `withoutUndoRegistration` 包裹
    `setAttributedString`，程序化装载不污染 undo 栈。
  - 主文件行数控制在 1984 行（lint 2000 上限内）。
- `MiaoYan.xcodeproj/project.pbxproj`：2 个新文件注册 4 处，纯 24-hex ID。

## 关键设计决定（实现即合同）

1. **history 不拥有 revision**。G0 原型的 `Result.revision` 会让调用方
   误以为 undo 是「回退到旧 revision」；T06 明确 undo/redo 也是新
   revision 的编辑，旧 async 任务按 revision 失效（SPEC §5.2「undo/redo
   也是新 revision 的反向/正向 source transaction」）。
2. **composition 的历史 base 是 marked 前的 source**，不是最后一次
   update 前的 source。marked 期间 source 已逐步跟随 display（保证
   预览/映射新鲜），若历史只记最后一步增量，undo 无法回到 composition
   前。因此 `insertText` 前置 `justUnmarked`，提交时以基线 source 为
   base 构造整段 patch 一次成组。
3. **取消路径的 `hasMarkedText()` 为 false 但仍在 composition 会话中**。
   `setMarkedText("")` 后 `markedTextRange` 已清，但 `markedSourceBefore`
   非空——textDidChange 必须按 composition 处理（不登记历史），否则
   取消会留下 typing entry。
4. **EditTextView 的 view 自动 undo 与 MarkdownEditorHistory 是两层**。
   source 模式的字符级 undo 经 `windowWillReturnUndoManager` 路由到
   note.undoManager（AppKit 原生）；rich 投影的语义 undo 由
   MarkdownEditorHistory 拥有。T06 保证程序化刷新不污染前者，后者在
   投影层独立工作；T10 统一宿主后由协调层收敛为单一入口。

## 验证（2026-10-16，本机）

- `MarkdownEditorHistoryTests`（16）：selectionAfter 正确性、非 typing
  不合并、typing 合并（同 group/selection 紧贴/范围相邻/纯插入）、
  selection 跳变截断、groupID 不同截断、超时截断、redo 截断、undo/redo
  恢复 selection、内存上限、跨 source/rich 同一历史、空 patch 不入栈、
  redo base 不符拒绝。
- `MarkdownCompositionTests`（9）：G0 原有 4 项 +
  testCompositionCommitsOnceAndUndoRestoresSelection（PLAN §5 oracle：
  真实 AppKit composition 宿主 + 候选，submit 一次 history，undo 恢复
  source/selection）、testCompositionCancelDoesNotRecordHistory、
  testCompositionCommitDoesNotCoalesceWithFollowingTyping、
  testRebuildDuringMarkedDoesNotInterruptComposition。
- `RichMarkdownEditingTests`（19）：G0 全部通过，undo/redo 语义不变。
- 全套：**309 tests，8 failures = 3 个既有环境性 WKWebView 用例 +
  2 个 Mermaid 导出 + 1 个 Vditor 集成 + 2 个 Math 渲染**（均与 T06
  无关，T05 基线已存在）。
- swiftlint 0 violations、swift-format 604.0.0 0 errors。

## 有意不做（已记录在案）

- **EditTextView 的逐键 apply 到 session**：source 模式 buffer 的附件化
  文本（NSTextAttachment U+FFFC、checkbox）与 raw source 的映射是 T10
  投影层职责；T06 只保证 view 自动 undo 与程序化刷新不冲突，不改变
  T05 的保存节奏。
- **MarkdownEditorHistory 与 note.undoManager 的合并**：两者当前并存
  （source 模式字符 undo vs rich 投影语义 undo），T10 统一宿主后由
  协调层决定单一入口。
- **跨 note 历史隔离的显式测试**：当前 `windowWillReturnUndoManager`
  在切 note 时换 manager，自然隔离；T07/T08 的 TransitionCoordinator
  接入后补显式测试。
