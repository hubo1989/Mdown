# Typora 研究与 Mdown 原生编辑器替换准备

更新：2026-10-14。状态：静态研究与实施准备，未替换编辑器、未删除依赖、未修改 Mdown 业务代码。目标是用 Swift/AppKit 本地实现 Typora 的用户可见编辑行为；当前成果不代表“已完全复刻”。

仓库基线：`main@b8110a942e27ae13ebe531b549a56e5a220f91ae`，`/Volumes/external/Projects/Mdown`。开始本轮时已有的 untracked `specs/typora-research/` 属于此前研究成果。本轮继续在该目录补证据、纠错与准备文档，不提交、不推送、不扩大修改到既有 SPEC/PLAN 或业务资源。

## 1. 结论

1. 指定 Typora macOS 副本采用原生 AppKit + WebKit；编辑模型、输入规则与主要渲染在 JS，原生负责文档会话、文件、系统服务和导出编排。采用原生窗口不意味着编辑核心是本地文本模型。
2. 原生文档层参与保存 JS 的 `nodeMap`、富文本/源码历史、光标、滚动与换行信息，职责超出“薄壳与文件备份”。
3. 导出先 prepare，再按类型分流；PDF 使用独立 WebView 创建并再处理链接、目录、属性、页眉页脚和字体映射。只复刻截图不能覆盖这些语义。
4. Mdown 当前同时有 NSTextView 源码编辑和 Vditor 网页 WYSIWYG；Highlightr 与 Prettier 还各有 JS 依赖。需要分别替换这三条编辑路径，保留 cmark、存储和独立导出；整应用无 JS 还涉及公式、图表、演示与渲染。
5. 原生方案建议以 Markdown 原文 + source/display 映射 + 文档会话事务为基础；视图和导出读取同一 revision，保存 owner 与选中笔记分开。
6. “体验一致”按固定样例与逐步操作验证，涵盖 IME、选择、撤销、表格、原文往返、图表错误和导出；静态分析不替代运行结果。

## 2. 阅读入口

| 文档 | 用途 |
|---|---|
| [EDITOR-MODEL.md](EDITOR-MODEL.md) | JS 编辑模型、parser/serializer、CID、选区、IME、undo、Oversize 的实际路径与偏移 |
| [EXPORT.md](EXPORT.md) | 导出准备、资源等待、HTML/图片/PDF/Pandoc 分流和错误终态 |
| [NATIVE.md](NATIVE.md) | 原生 ARM64 方法地址、文档/快照/同步桥/导出边界与 Hopper 阻塞 |
| [MDOWN-MIGRATION.md](MDOWN-MIGRATION.md) | Mdown 现有源码、JS 依赖真实位置与可复用原生能力 |
| [NATIVE-DESIGN.md](NATIVE-DESIGN.md) | 本地原文、编辑事务、source/display 映射、IME 与渲染边界的建议设计 |
| [正式实施 SPEC](../native-typora-editor/SPEC.md) / [PLAN](../native-typora-editor/PLAN.md) | 原生编辑替换的主合同、38 项需求、22 项验收和 T00–T23 实施任务 |
| [NATIVE-REPLACEMENT-PLAN.md](NATIVE-REPLACEMENT-PLAN.md) | 历史研究准备清单；正式阶段编号与合同以新主 Spec/Plan 为准 |
| [PARITY.md](PARITY.md) | “Typora 体验一致”验收范围、官方基准与记录方式 |
| [BRIDGE.md](BRIDGE.md) | 98 个 callHandler、63 个 registerHandler、5 个 callSync 的已观测清单 |
| [CORRECTIONS.md](CORRECTIONS.md) | 首轮过度推断的修正记录，避免沿用旧假设 |
| [EVIDENCE.md](EVIDENCE.md) / [evidence-ledger.json](evidence-ledger.json) | Evidence ID、样本身份、地址/偏移坐标体系和未知项 |
| [fixtures/README.md](fixtures/README.md) | 自编 Markdown 样例、16 项行为合同、CRLF/末尾换行与样例摘要 |
| [VALIDATION.md](VALIDATION.md) | 本轮实际检查结果、未运行范围和阻塞状态 |

## 3. 分析对象与来源边界

- 本地应用：`/Volumes/external/Projects/typora-r/Typora.app`，Info.plist 为 Typora 1.12.6 / 7588 / `abnerworks.Typora`。
- 主程序：universal x86_64 + arm64，SHA-256 `6fc6b2cf726f7366b8b0a62d0e2fa557ef8ec186dea9079c3f758c5a1e46962f`。
- arm64 切片：SHA-256 `35d2369c866af36e98cbca8a8dec5d408a8c78b8ec210d82b32c71a2b6857f57`；与原包对应字节区间逐字节相等。
- `appsrc/main.js`：1,639,455 bytes，SHA-256 `745d737c75397a1424e6211a8a9523349ecae5267f39e4a516790ac7f9cfeee8`。
- 当前副本签名记录 Authority 为 `Antibiotics`，未验证为官方发布包。行为验收需官方来源核验后的样本，不能由该副本推及所有 Typora 版本。

恢复模块、目标资源和原始汇编保存在 `/Volumes/external/Projects/typora-r/research/`，不引入 Mdown 构建或依赖。Mdown 内只保存行为研究、地址/偏移、独立实现建议与自编测试输入。

## 4. 已核验的总体结构

| 层 | 样本位置/类型 | 已核验职责 |
|---|---|---|
| 原生应用 | `Contents/MacOS/Typora` | AppKit/NSDocument/WebKit/PDFKit；99 个 ObjC classlist 条目 |
| 编辑前端 | `Resources/TypeMark/appsrc/main.js` | SystemJS Builder SFX，86 个 registerDynamic 模块；Node/NodeMap、parser、serializer、Selection、UndoManager 和 CodeMirror 分工 |
| 页面 | `html/content.html` | 文档模板；有条件读取 `window.process` 的 Electron argv；不是 macOS 配置通路证明 |
| 独立页面 bundle | `page-dist/` | Preferences、License、Welcome、localSetting 等应用页面 |
| 渲染资源 | `lib/` | CodeMirror、MathJax3、Mermaid/diagram、AWS SDK 等；文件存在本身不证明所有功能运行 |
| 原生服务 | `CommandBridge` / `*Commands` | 按域提供文件、剪贴板、窗口、菜单、拼写、配置等服务 |
| 导出 | `TyWindowController(Export)` / `TyPDFEngine` / `PandocBridge` | 格式分流、独立渲染、PDF 后处理、可选外部转换 |

macOS `SettingCommands.preSetupScript` 注入 `window._options`，`DocumentCommands.preSetupScript` 注入 `_documentState`。`main.js` 中存在 `window.reqnode` / Electron 路径，说明前端保留不同宿主分支；不能因有 Electron 字符串就把 macOS 包定义为 Electron 应用。

## 5. 本轮完成边界

| 项目 | 当前状态 |
|---|---|
| 指定样本身份与切片来源 | 已验证哈希、切片逐字节对应；官方来源未验证 |
| 原生方法/常量/调用分支 | 已获得 otool ARM64 反汇编并独立复核关键路径 |
| REA Mach-O/签名证据 | 已保存完整 Evidence 与摘要 |
| Hopper 伪代码级分析 | 阻塞：实际启动仍被 Apple Events 拒绝；未获得函数 dossier |
| JS 核心与导出路径 | 静态定位与语法跟踪；详见专项文档的边界，不宣称全 bundle 已理解 |
| Mdown 替换入口 | 源码核验结果见迁移文档，不以此前摘要代替实际代码 |
| 行为样例和阶段验收 | 已定义；未运行的 observed_result 保持 null |
| 编辑器替换/依赖删除 | 未实施 |
| Typora 运行、视觉/输入法/性能一致性 | 未验证 |

成功 `open_binary` 只表示文件绑定；不能宣称 Hopper 分析已完成。失败会话已调用 close，临时 CLI 进程已结束；工具返回 cleanup_incomplete，Hopper GUI 与遗留私有目录关闭未确认，未擅自清空。

## 6. 与既有计划的关系

现有 [WYSIWYG SPEC](../wysiwyg-and-rendered-block-export/SPEC.md) / [PLAN](../wysiwyg-and-rendered-block-export/PLAN.md) 保持原始状态。Mermaid 等渲染内容单张保存的 D 线可独立推进；本地编辑器替换作为 W 线后续准备，不能成为 D 线前置依赖。

本轮新增的原生替换准备覆盖更广的编辑模型与 JS 依赖边界，沿既有 W0/G0 的 TextKit 1 技术验证推进；正式组件优先使用 MarkdownEditingSession、MarkdownSourceMap、RichMarkdownTextView。仅写建议和验收合同，不替换既有产品决策、默认模式、快捷键、附件约定或 iOS 编辑器。

## 7. 文档验证

文档交付前核验：链接可达、JSON 可解析、桥接清单与实际字面量匹配、原生地址存在、样例摘要一致、CRLF 与无末尾换行特征保留。业务源码未改，不运行构建来冒充 UI/行为验证。实现阶段需补纯模型测试、macOS 构建、输入法实机和导出文件验证，再按 PARITY 的规则报告。
