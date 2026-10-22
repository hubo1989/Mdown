# T14 验证记录 — 命令 adapter、find/preview intent(N1 门)

日期:2026-10-21 ~ 10-22。基线:`main@b8110a9` 线,前序 `65f028b`(T13)。

## 改动

- 新建 `Helpers/MarkdownEditorCommandAdapter.swift`:内容命令注册表(bold/italic/
  underline/deleteline/inlineCode/codeBlock/link/todo/快捷模板)+ 三路路由
  (rich source patch / source TextFormatter 同缓冲 / legacy Vditor 回退)+
  preview task intent(payload 解析、span 规划、应用防线)。
- `Views/RichMarkdownTextView.swift`:新增命令通道 public API ——
  `insertUnderlineCommand` / `insertLinkCommand` / `toggleTodoCommand` /
  `insertCodeBlockCommand` / `insertShortcutTemplate` / `sourceMatches` /
  `displayRange(forSourceRange:)` / `reveal` / `replaceNextMatch` /
  `replaceAllMatches`(一次事务一条历史)/ `applyWholeSourceReplacement`
  (format 通道,单步 undo)/ `applyTaskTogglePatch`(origin `.previewIntent`,
  caret 原位)。`applyStructurePatches` 增加 origin 参数。
- `Helpers/EditorMenuManager.swift`:native rich 活动面时格式命令/
  codeBlock/codeSpan/文件附件走 adapter(rich T13 附件通道),不再强制
  踢回 source;legacy Vditor 与 source 布局行为不变。
- `Views/EditTextView.swift`:`insertShortcutText` rich 优先;查找条在
  rich 活动时让位(`richHostOwnsFind`,移至 EditTextView+EditingSession
  extension),消除 ⌘F 双查找条。
- `Controllers/ViewController+Editor.swift`:`formatText` native rich 分支——
  读会话 source、结果以整篇替换事务应用、`flushPendingSave`、split 预览刷新;
  不触碰隐藏 editArea。
- `Controllers/ViewController+Action.swift`:`textFinder` 与全局 ⌘F 监听
  (`handleKeyDown`)在 native rich 活动时路由到 rich host 查找条。
- `Views/NativeRichEditorHostView.swift`:rich 查找条(PreviewSearchBar 复用),
  source 匹配 → display 高亮/跳转/replace-next/replace-all;编辑后重跑高亮。
- `Views/MPreviewHandlers.swift`:HandlerCheckbox 重写为有限 payload 转发;
  `PreviewTaskIntentRouter` 按会话状态(surface 身份/渲染代/只读态)校验并
  应用;拒绝时 diagnostics 记录 + toast + preview 刷新回滚。
- `Views/MPreviewView.swift`:`renderGeneration`(NE-28)——phase1 成功后
  stamp `window.miaoyanRenderGeneration`;didFinish 归零并 stamp 0;phase1
  DOM 重建后重跑 `setupInteractiveCheckboxes`(修复既有缺陷:updateContent
  后 checkbox 交互失联)。
- `Resources/DownView.bundle/js/common.js`:`handleCheckboxClick` 发有限
  JSON `{index, checked, generation}`,不再发裸序号(只动自有 JS)。
- 本地化:readonly-hint toast 补 es/ja/zh-Hans/zh-Hant 四份 Localizable.strings。
- pbxproj:3 个新文件(Adapter + 2 个测试)各注册 4 处。

## 自动化验证

| 项 | 结果 |
|---|---|
| macOS Debug build | **BUILD SUCCEEDED** |
| 新测试 `MarkdownCommandRoutingTests`(20)+ `PreviewEditIntentTests`(15) | **35/35**(RED→GREEN:初版断言含 5 处坐标/基线误设,修正后全绿) |
| 全量套件 | 520 tests,512 通过;8 failures 全部为 2 Mermaid + 1 KaTeX 用例的多次断言 |
| 上述 8 failures 基线对照 | 在 `65f028b`(T13 HEAD)独立 worktree 复跑,**完全相同的 8 failures**(WebKit content process 在本会话环境不可用),非 T14 回归 |
| SwiftLint --strict | 0 violations(期间修复:applyRichFormattingResult 参数数、textFinder 圈复杂度、large_tuple、EditTextView file_length→helper 移至 extension) |
| swift-format --strict(触及文件,双二进制) | 0 violations |

## 实机 smoke(独立副本 `/tmp/mdown-t14-smoke/MdownT14Smoke.app`,
bundle `com.mdown.t14.smoke`,临时库 `/tmp/mdown-t14-smoke/Library`;
未触碰已安装 Mdown 与用户数据;CUA + AX 驱动)

1. **命令不再踢回 source**:native rich(wysiwyg)选中 "word" ⌘B →
   确认磁盘 `plain **word** here`,AX 结构保持 rich 投影(`[ ]` 字面可见、
   `- ` 隐藏),无 source 模式切换。
2. **⌘F 单一查找条**(修复后):rich 查找条唯一,输入 "FindMe" 匹配
   1/2,"下一个" 跳转第二匹配(AX 2/2 + 选区截图),完成可关闭。
3. **preview intent 防线实测**:预览点击 task checkbox → 消息到达 router,
   过期渲染被拒(`staleRender`,diagnostics:
   `PreviewTaskIntentRouter.rejected.staleRender`),**零写入**,拒绝后
   preview 刷新回滚。诊断固定代值:`payloadGen=null, nativeGen=0` ——
   由此发现并修复 didFinish 不 stamp 缺陷。
4. **发现并修复的缺陷**:
   - ⌘F 双查找条(全局 ⌘F 监听 + 菜单各自建条)→ `handleKeyDown` 路由
     rich host,单条实测通过;
   - 模板初始渲染无渲染代 stamp → didFinish stamp 0;
   - phase1 DOM 重建后 checkbox 交互失联(既有缺陷,updateContent 后点不动)
     → phase1 追加 `setupInteractiveCheckboxes()` 重绑。

## 保留的边界与待办

- **preview checkbox 正向写盘的截图级证据未取得**:拒绝链路、代数防线、
  零写入已实机证实;成功链路(定位第 n 项→span 翻转→镜像→落盘)由
  15 个 PreviewEditIntentTests 覆盖(含 rich/source 两 surface、caret 不动、
  一次撤销)。修复 stamp/重绑后未能在本会话再取得一次 UI 命中,留维护者
  一次实测:预览中点击 task checkbox,预期磁盘 `- [ ]`↔`- [x]` 翻转且
  编辑器 caret 不动。若仍被拒,diagnostics 会留下
  `PreviewTaskIntentRouter.rejected.<原因>` 定位线索。
- rich 查找条的全匹配高亮沿用 EditTextView 同色(0.35 alpha),截图缩放下
  可见性偏弱,视觉打磨留 T19。
- 本会话实机出现一次 `Note.writeError`(code 513 EPERM,原子换名路径),
  重试即成功,仅一次;与 /tmp 原子写瞬态一致,继续观察。
- Mermaid/KaTeX 3 用例在本会话环境不可运行(T13 HEAD 同样失败),
  不能宣称本机全绿;CI 环境以 CI 结果为准。

## N1 门状态

AC-01~AC-10、AC-14、AC-16、AC-22 适用集:单元 + 实机 smoke 如上;N1
"正式可选 native 基础" 成立。公开表述边界:table 与特殊扩展(math/diagram/
raw HTML)暂为局部 source 编辑,N1 不声称 N2/零 JS(预览/导出 JS renderer
保留,交互面收敛为有限 intent)。
