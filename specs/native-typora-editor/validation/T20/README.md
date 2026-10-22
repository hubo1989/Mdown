# T20 验证记录(阶段 1:导出正文来源审计)— 2026-10-22

前序 `df12e53`。本记录只覆盖已落地部分。

## 审计结论(T20 核心风险面:"export 不读 hidden view / 切换后 note")

`Extensions/MPreviewView+Export.swift` 四处正文入口(52/85/185/695)
全部读 `note.getPrettifiedContent()`——即 Note 的**提交镜像**,不是
隐藏 buffer:
- native rich 的编辑经 onSourceCommitted 即时镜像进 note.content
  (T10 契约,NativeWysiwygContractTests 有断言);
- source 面经 textDidChange → saveTextStorageContent(owner guard +
  session revision 防护)。

正文在任务起点同步取字符串(in-flight job 不随后续切笔记/输入变化)——
等价 job 固定 source snapshot。`RenderedBlockExportController` 走
T17 的 RenderedBlockSnapshot(独立静态产物,不读主预览 DOM)。
`ViewController+Export.exportFile` 路由经 editArea.markdownView(预览
WebView)——未进入预览/分栏时为 nil,保持既有 no-op 行为,不新增旁路。

## T20 剩余(不冒充)

1. 运行级导出验证(PDF 中文/emoji/复制搜索/链接/outline/页眉页脚、
   Mermaid PNG/SVG 单块):需 UI 流程;Mermaid/KaTeX 运行用例在本机
   WebKit 环境不可运行(基线已证,见 T13/T23 记录)——独立调查进行中,
   结论出来前不计 pass。
2. iOS 读取回归(共享 resource 触及时 mobile build + simulator)——
   本阶段未触 iOS target。
3. 预检期间 source/主题变化取消旧操作的运行级矩阵(T17 状态层有单测)。
