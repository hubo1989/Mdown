# 原生编辑器重建的设计建议

状态：为独立实现做准备的建议，未创建以下 Swift 组件，未验证 TextKit 技术路线。具体改动入口与阶段任务见迁移文档和替换计划。Typora 的静态路径只说明需要哪些行为；本文件中的类型、字段与服务边界均为 Mdown 拟议设计。

## 1. 推荐起点与取舍

推荐沿既有 W0/G0 先验证 **TextKit 1 / AppKit NSTextView + 原文模型 + 显示投影**，保留现有原生窗口、菜单和笔记管理。正式组件优先收敛为既有方案中的 MarkdownEditingSession、MarkdownSourceMap、RichMarkdownTextView，不另建一套平行架构。借鉴 Typora 的源码/渲染态切换体验，但不以 DOM 或 HTML 作为持久化模型。

| 候选 | 取舍 | 本轮判断 |
|---|---|---|
| NSTextView/TextKit 上构建选择映射与 block 投影 | 可保留系统 IME、辅助功能与原生文字服务；隐藏标记、表格和附件必须做技术验证 | 推荐先做有限原型，有失败门槛 |
| 每种 block 一个原生控件/文本编辑子视图 | 块布局自由，但跨块选择、统一撤销、焦点与 IME 要重新编排 | 仅在 TextKit 原型证明关键需求不可实现时评估 |
| WKWebView 承担输入与编辑 | 接近既有 JS renderer 的实现方式 | 与本次“编辑链路本地化”目标不符，不作为终态 |

当前最低系统版本与 TextKit API 兼容需要按仓库验证。不能只为得到 TextKit 2 的能力就擅自提高最低系统版本；原型若依赖新 API，应提供兼容路径并写清性能与行为差异。

## 2. 三层权威状态

建议将状态拆成如下三层，避免 view.textStorage、当前 table selection 和后台 renderer 各持一份互相覆盖的正文。

**文档原文：**原始 Markdown、换行类型、末尾换行、noteID、revision、磁盘 revision。保存只读这一层。词法/parser 可以派生结构，不能在未编辑的情况下无意正规化原文。

**编辑会话：**editorSessionID、source selection、marked-text 状态、命令事务、undo/redo、当前模式、滚动锚点。属于文档 owner；换笔记时明确 flush、取消与保存边界。

**显示/导出投影：**原文范围与显示范围对应、块样式、附件与图表渲染结果、导出配置、当前 revision。可丢弃和重建；异步结果不匹配 owner/revision 时不能发布。

原生方案不需要使用与 Typora 同名的 nodeMap、CID 或历史序列化格式，但必须解决它们对应的结构、身份、选择与恢复问题。

## 3. 源码与显示范围的双向映射

建议用明确的坐标类型表示 UTF-8 byte offset、UTF-16 offset 和 grapheme 边界。AppKit 的 NSRange 通常落在 UTF-16；解析器 source position 未必如此，不能直接传递整数。

每个投影 segment 保留 source range、display range、kind 与可编辑策略：普通文字、显示/隐藏 delimiter、链接 destination、行内 code、block marker、attachment placeholder、metadata。选择移动、点击、复制、拖选、跨段替换都通过映射回原文。

必须定义歧义：隐藏 delimiter 两侧对应同一显示 caret 时，点击/左右移动选择哪一侧；映射保存前按 revision 校验；attachment 的占位字符不能被直接存回 Markdown。

至少满足：

1. 无编辑时 source→display→source 不改变原文。
2. 可编辑显示文字替换映射到对应源码范围，不删除受保护的 URL、code 或 metadata。
3. 跨块删除对结构与选区做一次事务，不由多个视图各自更新。
4. Unicode 范围不能切在代理对或组合字符内部。

## 4. 输入法优先与命令事务

输入顺序建议为：系统 text input/marked text → 组合确认 → 原文 replacement → 有条件 Markdown 输入规则 → 局部解析 → 投影更新。

marked text 存在时不全量重载 textStorage、不改当前组合区属性、不把候选用 Enter/Tab 当作块导航；异步 parser/高亮不能抢组合输入的选区。显示刷新可延后，提交后的逻辑文字与选择必须一次记录。

每个 EditTransaction 携带 owner、base revision、原文范围、replacement、selection before/after、原因和相应的结构变更。验证成功后发布新的 revision；不同时由 NSTextView 内部 undo 与另一套正文事务重复注册历史。模式切换是否可撤销需先锁定产品行为。

连续输入聚合只在同一 owner、相邻文字范围、同类编辑且没有选区/结构边界时允许；组合提交、格式操作、拆块、表格动作均有显式边界。聚合时间窗在运行 Typora 基准后设定，不凭静态名称猜秒数。

## 5. 模型解析和增量边界

CommonMark/GFM AST 可提供语义结构，但不能天然保存原始定界符、空白和所有扩展的源码位置。建议在现有原生 parser 外保留原文切片、token/range 和结构身份，支持“只序列化已编辑范围”。

至少需要区分：段落/标题/列表/引用/分隔符、代码 fence、表格、脚注/引用定义、frontmatter、数学/图表与 raw HTML。参考定义变化可能影响远处块，增量失效范围不能只看当前行；嵌套列表与 fences 的修复范围也可能跨段。

原型先验证正确性再测局部更新。大文档降级建议保持本地原文可编辑，按需延迟图表、公式和高亮，不静默丢弃内容或改变保存格式。Typora 的 Oversize 行为是对照项，不是直接采用的阈值。

## 6. 渲染插件不得拥有正文

建议 Renderer 接口只接受不可变 block input：owner、blockID、revision、source、配置和目标尺寸；返回 image/vector/layout 或显式错误。缓存键包括源码/主题/字体/renderer 版本；发布结果前再次比对 revision。

第一阶段可隔离既有 JS 渲染服务，确保它无法接收编辑事件或写回正文。完全去除 JS 时，分别实现代码语言高亮、公式语法、Mermaid 图种/布局、PlantUML 功能、演示和 raw HTML 策略；每一种替换均需声明支持语法和降级结果。不能用“原生图形绘制”自动推导“兼容 Mermaid 全语法”。

对源码错误、渲染超时、缺失资源必须保持原文编辑入口；图表错误不会阻止 Markdown 保存。

## 7. 导出使用不可变快照

建议 ExportJob 记录 noteID、revision、format、配置、资源列表和任务 ID；从同一原生文档模型生成 HTML/向量/位图/PDF/Pandoc 输入。

ExportJob 的终态是 succeeded、failed、cancelled，资源等待分别有 ready、failed、timeout、cancelled。结果写入确认后才能成功，允许取消但不把取消等同错误；失败/取消只清理本任务临时产物。

PDF 的创建与语义验收分开：字体、ToUnicode、链接、outline、页眉页脚和分页都需要运行验证。HTML 预览质量不能替代 PDF 搜索与复制验证，单块 PNG/SVG 也不能替代整文 PDF。

## 8. 采用与淘汰门槛

以下任一问题未解决，不进入默认模式替换和依赖删除阶段：

- IME 组合输入被 attributes 更新或选区改写打断。
- 隐藏 marker 的 source/display caret 无法稳定双向映射。
- 跨块选择/撤销存在正文和视图分歧。
- 无编辑打开/切换模式引起文件字节漂移。
- 当前笔记与 buffer owner 混淆、旧异步结果可以覆盖新 owner。
- 原生高亮/格式化结果只能通过 JS fallback 才能保证关键路径。
- 代码/公式/图表插件错误会阻断基础编辑或保存。
- 新 API 使既定系统兼容性下降且没有获准迁移路径。

原型未过门槛时记录失败位置和可复现输入，改进同一层模型或评估另一种原生投影方式；不通过删除验收项来制造“原生替换已完成”。
