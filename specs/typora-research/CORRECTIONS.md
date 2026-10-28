# 首轮报告修正记录

2026-10-14。首轮报告主要依赖词频、类名与框架 inventory，部分结论超过证据能力。本轮以原生指令、JS 定义/调用和 Mdown 源码重新核验；此文件保留修正原因，避免后续设计沿用旧假设。

| 首轮表述 | 处理 | 本轮证据与边界 |
|---|---|---|
| 198 个 ObjC 类 | 修正为 99 个 classlist 条目 | `__objc_classlist` 大小 0x318，每项 8 字节；原计数重复包含 metaclass |
| `nm -gU` 为 0，因此全 strip | 收回 | arm64 切片返回 `__mh_execute_header`；`nm -m` 有 6,670 条记录，包含 non-external 方法和 block callback |
| `--tyopt` 是 macOS 原生壳配置通路 | 修正 | HTML 仅在 window.process 存在时读 argv；macOS `SettingCommands.preSetupScript` 注入 window._options，DocumentCommands 注入 documentState |
| main.js 是 webpack 压缩 bundle | 修正为 SystemJS Builder SFX | 查实 86 个 registerDynamic，入口 a；page-dist 的打包形式不能推及 main.js |
| markdown-it 风格 AST 因而确认 parser/模型架构 | 收回库名推断 | 实际 Node.parseFrom、Node.toMark/NodeMap 在自有模块；有限关键字负搜索不证明整个软件不存在其他库 |
| Python 字符索引约等于 UTF-16 | 收回 | main.js 含 1,634 个增补 Unicode codepoint，最终定位统一为 UTF-8 byte offset |
| 全量同步是增量失败才调度 | 修正 | syncChange callback 为真时才 scheduleFullContentSync（500 ms）；不推断未观察的失败策略 |
| `md-expand` 表示块折叠 | 收回通用用途推断 | 同一类可能用于行内标记/编辑展开；必须跟踪 add/remove 与目标元素后定性 |
| JS undo 与原生文件快照完全独立 | 修正 | DocumentSnap 接收 nodeMap、undoRedo、srcContent、srcHist、光标和滚动，是原生保存的编辑会话状态 |
| `enterOversize` 意味停止全量 IPC/实时统计 | 收回 | 原生函数只广播 File.tryEnterOversize 给其他窗口；真正阈值和模式由 JS 决定 |
| 全格式使用 prepare → dataForExport → HTML/Command | 修正为 type 分流 | `_exportWithOption:` prepare callback 分 PDF、HTML、图片、自定义命令、Pandoc；dataForExport 不是所有分支的固定后继 |
| 图表导出本质就是 SVG → 位图 | 收回泛化 | 整文导出包括独立 WKWebView、PDF 创建与链接/目录/属性/字体二次处理；单块导出需另外查实 |
| URLHandler 证明通用本地资源安全边界 | 收回 | 查实为当前 TextBundle 按 lastPathComponent 查 asset；未证明通用路径安全策略 |
| 原生桥同步操作都低开销 | 收回保证 | prompt 桥接和 RunLoop 等待实际存在；文件读取、JSON 大小和等待成本需逐项验证 |
| libTypora.dylib 可基本断定为授权加密模块 | 收回职责定论 | 未分析函数；导出和字符串少不能证明内部职责 |
| 原生壳 + JS 可以保证相同响应速度 | 收回性能结论 | 没有性能测量；是否“原生”不是输入延迟或内存的证据 |
| Mdown W 线就是 WKWebView 编辑器路线 | 修正 | 既有 SPEC/PLAN 明确 TextKit 1/AppKit 原生投影；当前代码另接 Vditor，与旧规划状态发生漂移 |
| Mdown 没有 JS 编辑器，WebView 仅预览 | 修正 | 当前 VditorEditView 已接入编辑 host；Highlightr/Prettier 也是各自独立的 JS 编辑依赖 |
| 当前副本可以当官方 Typora 验收基准 | 增加限制 | 该样本签名 Authority 为 Antibiotics；官方来源尚未验证 |
| open_binary 成功代表 Hopper 已可用 | 修正 | 实际分析阶段仍遇到 Apple Events 拒绝；未获得 Hopper 函数 dossier |

已查实的函数和具体协议见 [NATIVE.md](NATIVE.md)、[BRIDGE.md](BRIDGE.md)。JS 编辑模型与导出流程按专项文档中的字段、偏移和覆盖边界判断；任何静态结论均不升级为运行一致性证明。
