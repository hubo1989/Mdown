# 原生编辑与导出验收输入

这些文件是 Mdown 自编样例，未在 Typora 或 Mdown 中执行动作。验收记录见 [behavior-cases.json](behavior-cases.json)，观测前 observed_result 保持 null。文件不加入应用 target，也不包含从 Typora 恢复的代码或资源。

| 文件 | 目的 |
|---|---|
| [editor-behavior.md](editor-behavior.md) | 输入法、Unicode、段落、列表、表格、代码、公式、图表、脚注、HTML 和导出 |
| [roundtrip-crlf.md](roundtrip-crlf.md) | CRLF、末尾换行、行尾两个空格、缩进、非统一列表标记 |
| [roundtrip-no-final-newline.md](roundtrip-no-final-newline.md) | 无末尾换行、标题尾部标记、Unicode grapheme |
| [behavior-cases.json](behavior-cases.json) | 16 个输入/保存/性能/导出动作序列与拟定合同 |

`example.invalid` URL 与缺失的 `/i/` 图片是故意构造的资源失败场景。不要为使样例“通过”而联网补齐附件；运行时需观察并记录编辑器在失败/离线场景的行为。

各文件哈希与换行特征将记录在 `manifest.json`。无编辑打开/关闭/切换模式后的字节应与原始摘要一致；实际有编辑的测试另记录 source diff。
