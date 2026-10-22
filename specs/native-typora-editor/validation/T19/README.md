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

## 阶段 2(同日补交):focus 降噪 / 滚动锚 / 菜单审计

- focus 降噪(NE-32):caret 块之外的块前景降 40% alpha;code fence 的
  token 色只涂活跃块(降噪块平色,避免活跃色残留);关闭开关幂等恢复
  全彩;caret 移动经 textViewDidChangeSelection 钩子(视图自身即
  delegate)。只动显示属性:revision/历史/dirty 有断言钉住。
- zoom/mode 滚动锚:refreshFontAttributes 先快照 caret 视口偏移,
  重排后按 anchoredScrollOffset(纯几何,2 用例)顶回原位置。
- 菜单 ObjectID 审计:脚本比对 storyboard 全部 menuItem id 与四语
  Main.strings(分隔符免译)——发现 7 个真缺(Code Block/Inline Code/
  Copy Path/Open in Terminal×2/HTML/PDF/Format)静默发英文,已补译并
  复跑 AUDIT PASS。
- 测试:NativeEditorViewStateTests 11/11;全量 629/629。

## T19 剩余(不声称完成)

1. **spell 按 protected kind 精确分流:AppKit 平台限制裁定** —
   NSTextView/NSSpellChecker 只有整视图开关,无 per-range 排除 API;
   N1 保守策略(富面整体关 continuous spell)保持,精确分流需
   NSSpellChecker 子类化,归 N2,不再列为可收窄缺口。
2. font/line spacing/Retina/darklight 一致性核对、图片/table 宽度
   限制、长 code 局部 scroll 的视觉验收(需视觉比对,留实测)。
3. 实机 keyboard/VoiceOver(AC-17 真实验收,需人机交互)。
