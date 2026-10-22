# T19 验证记录(阶段 1:typewriter 与输入策略分流)— 2026-10-22

前序 `616baf3`(T18 part 2)。只覆盖已落地部分。

## 已交付

- `RichMarkdownTextView`:
  - `isTypewriterMode` + `typewriterScrollOffset`(纯几何,nonisolated,
    caret 行中心对准视口中心并 clamp 到内容边界,不足一屏回 0);
    caret 恢复路径(`restoreSelectionFromSource`)接入滚动居中。
    开关只改 view state:不推进 revision、不入历史、不动 dirty。
  - init 关 continuous spell(保守策略:code/math/URL 不得被 spell
    改写;按 range 精确分流的开关留 N2 如实记录);automatic
    quote/dash/text replacement 已在早期阶段关闭,补断言钉住。
- `MarkdownEditorHistory.debugDepth` 观察口(测试断言 view-state 不入
  历史用)。

## 验证

| 项 | 结果 |
|---|---|
| `NativeEditorViewStateTests`(7,PLAN T19 指定文件) | **7/7** |
| 全量套件 | 583 tests,8 failures = 既有 3 个 WebKit 环境用例(基线已证) |
| SwiftLint --strict | 0;触及文件 swift-format 干净 |

## T19 剩余(不声称完成)

1. focus 非活动块降噪、mode/zoom 切换保持滚动锚。
2. 按 protected kind 的 spell 精确分流(N1 整体关的升级版)与
   markedtext 不抢候选的实测。
3. font/line spacing/codefont/Retina/darklight 一致性核对;图片/table
   宽度限制、长 code 局部 scroll 的视觉验收。
4. es/ja/zh-Hans/zh-Hant 菜单 ObjectID 完整性审计(本阶段未新增菜单)。
5. 实机 keyboard/VoiceOver(AC-17 真实验收,不能被单测替代)。
