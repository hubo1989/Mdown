# T17 验证记录(阶段 1:渲染快照/状态/缓存)— 2026-10-22

前序 `18993aa`(T16 part 2)。只覆盖已落地部分。

## 已交付

- `Helpers/MarkdownBlockRenderAdapter.swift`(PLAN T17 指定 Create):
  - `MarkdownBlockRenderRequest`:不可变值(块 ID/笔记/revision/主题代/
    kind/source 快照);`fingerprint` = kind+source+主题代,刻意不含
    revision(同内容新 revision 命中缓存)。
  - `MarkdownBlockRenderCoordinator`(MainActor):capture/accepts 的
    latest-wins——旧 revision、主题代变化后的同 revision 一律拒。
  - `MarkdownBlockRenderCache`:按 fingerprint 的有界缓存,容量逐出
    最旧,只动自己条目;failed/cancelled/timedOut 不产生 artifact、
    不落缓存。

## 验证

| 项 | 结果 |
|---|---|
| `MarkdownRenderedBlockStateTests`(7,RED→GREEN) | **7/7** |
| 全量套件 | 564 tests,8 failures = 既有 3 个 WebKit 环境用例(基线已证) |
| SwiftLint --strict | 0;触及文件 swift-format 干净 |

## T17 剩余(不声称完成)

1. 隔离只读渲染宿主(单块静态 SVG/HTML + 尺寸/能力)与既有
   RenderedBlockExportController 的预检/冻结衔接;不读主预览 DOM。
2. raw HTML/math/diagram 块的 source 编辑面已有(T13 raw editor),
   readonly error 态回 source、invalid 公式永不丢源码的实机矩阵。
3. 渲染错误/超时保持可编辑 plain 的实测与缓存复用的实机证据。
