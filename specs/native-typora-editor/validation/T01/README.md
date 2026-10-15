# T01 — Vditor 与保存桥风险复现/修复验证

日期：2026-10-14。基线 `main@b8110a9` + T00 产出之上。本机测试形态见 [BASELINE.md §2](../BASELINE.md)（`MACOSX_DEPLOYMENT_TARGET=12.0 CODE_SIGN_IDENTITY=-`）。

## 复现（红）→ 修复 → 回归（绿）记录

### 风险 #1：setter callback 错配 → 加载后所有用户输入被静默丢弃

- **复现（红）**：`VditorBridgeContractTests.testUserInputDuringSetMarkdownWindowIsNotLost` 在旧代码上失败——`editor.html` 的 `setMarkdown` 把 callback 传给 `setValue(markdown, clearStack?: boolean)` 的第二参（随包 `method.d.ts` 只有 boolean 参数，callback 永不执行），`isUpdatingFromSwift` 置 true 后**永不复位**：每次程序化加载后 wysiwyg 的所有用户 input 被 JS 侧丢弃（不更新 `Note.content`、不置 dirty、不保存）。严重度高于 PLAN 预估的 100ms 窗口。
- **修复**：`setMarkdown` 改官方 API `setValue(md, true)`（clearStack=true：程序化加载清 undo 栈；Vditor 内部 `enableInput:false` 应用内容，不产生 input 回声）；删除 `isUpdatingFromSwift` flag 机制。
- **回归（绿）**：真实 WKWebView 循环内 `execCommand('insertText')` 模拟用户输入，`Note.content` 收到更新。附带固定契约：Vditor 序列化为无末尾换行文档追加单个 `\n`（`testSetMarkdownRoundTripsThroughEditor`）。

### 风险 #2：晚到 vditorChange 写坏切换后的 note

- **复现（红）**：`testLateChangeMessageDoesNotOverwriteSwitchedNote` 在旧代码上失败——A 的消息晚于 `loadNote(B)` 到达时被套用 `currentNote=B`，`B.content` 被写成 A 的内容并排入保存。
- **修复**：加载身份 token。Swift `VditorEditView.loadToken` 每次程序化加载自增并随 `setMarkdown`/`initEditor` 下发；JS `currentLoadToken` 跟随，input 回调携带 token；Swift 侧 `token != loadToken` 或无 token 的消息一律拒绝。
- **回归（绿）**：注入 stale token / 无身份消息均被拒；真实输入链路（token 匹配）端到端通过。

### 风险 #3：Cmd+S / windowWillClose / applicationWillTerminate 用旧 source buffer 覆盖 Vditor 输入

- **复现（红）**：`EditorStorageOwnershipTests.testHardSavePointMustNotOverwriteVditorContentWithStaleSourceBuffer` 在旧调用点（`editArea.saveTextStorageContent(to: EditTextView.note)`）上失败——同一 note 从 source 切 wysiwyg 后 textStorage 停留旧 v1，owner guard 按 URL 匹配通过，v1 覆盖 Vditor 已写入的 v2。
- **修复**：`Helpers/ActiveEditingBackend.swift` 最小临时 adapter（**T05~T08 由 MarkdownEditingSession / EditingTransitionCoordinator 收敛后删除**）：wysiwyg 活动时目标 note 取 `vditorEditView.currentNote`、采集 = `flushPendingSave()`；否则沿用 source buffer + owner guard。三处调用点替换：`ViewController+Action.swift`（⌘S）、`MainWindowController.windowWillClose`、`AppDelegate.applicationWillTerminate`。
- **0.5s 空窗收口（绿）**：`NoteSaveDebounceTests.testWysiwygHardSavePointLandsOnDiskInsideDebounceWindow`——Vditor 输入后（0.5s/1.5s debounce 均未到）立即走硬保存点链，磁盘文件实际为 v2，flush 幂等。

## 附加事实

- WKWebView + Vditor 本地 JS 在本机 ad-hoc 签名测试宿主中可运行（KaTeX/Mermaid 的失败不阻塞 Vditor 桥测试）；宿主日志有 pboard/runningboard entitlement 噪音，不影响断言。
- 资源存在测试（VditorIntegrationTests 前 2 项）与真实输入/save 测试（VditorBridgeContractTests）已分离。

## 退出门核对

- 症状有运行证据：三项风险均先红后绿。
- source/Vditor 不串写、不丢最后输入：全套 193 tests 中仅剩 3 个既有环境性 WKWebView 失败（见 BASELINE §1.1），lint 0 violations。
- 现有 selector/default/renderer 未改：`editor.html` 仅动自有 `setMarkdown`/`input`，未触碰 `vditor/dist/` vendor；storyboard selector 未动。
- 未宣称原生化；`ActiveEditingBackend` 标记 T05~T08 待替换。
