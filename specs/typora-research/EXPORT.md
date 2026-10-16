# Typora 导出管线：JS 准备与原生保存

状态：2026-10-14，main.js 静态定义/调用和原生 ARM64 反汇编对照；未运行导出。样本/哈希与限制见 [EVIDENCE.md](EVIDENCE.md)。所有 JS 偏移为当前 main.js 的 UTF-8 byte offset，不复用 Python 字符索引或 UTF-16。

## 1. 模块与两套宿主

| 模块 | 注册偏移（registerDynamic 起点） | 职责 |
|---|---:|---|
| `10` | 20366 | JSBridge，macOS bridge 与 Electron IPC 分发 |
| `43` | 333882 | NodeMap → Pandoc native AST 文本、媒体占位与临时文件清理 |
| `44` | 347193 | Node 宿主 print/PDF/整文图片与截图 worker 编排 |
| `45` | 355955 | Node 宿主 Pandoc Process/spawn；window.reqnode 存在时才接外部进程实现 |
| `46` | 364460 | Export 服务、bridge handler、HTML/样式/格式变量 |
| `4a` | 410912 | 项目/文件配置与导出 option 合并 |

module 44/45 的截图窗口、fs、spawn 是 Node/Electron 路径，不能直接描述成 macOS 的实际实现。macOS 分流由 TyWindowController 原生编排，详见 [NATIVE.md](NATIVE.md)。中间静态视图保留在本机 `research/export-pipeline/module-43/44/45/46.js` 及 pretty.txt；本仓库不复制这些实现。

## 2. 真实入口是 prepare 后分支

原生 `_exportWithOption:`（`0x100074bd0`）请求 `export.prepare`，回调按 type 分 pdf、html、html-plain、image、custom、Pandoc。module 46 注册的 handler 是并列能力，不是所有格式固定经过 dataForExport 再调用 HTML/Pandoc。

| JS 定义 | byte offset | 返回/作用 |
|---|---:|---|
| `export.exportToNative` handler | 370114 | 回调 `{native, option}`，native 是 Pandoc AST 文本 |
| `export.dataForExport` handler | 370843 | 回调建议文件名、HTML content、PDF header/footer 与 hasNonAlphabet |
| `export.exportToHTML` handler | 371346 | 同步 File 后返回 HTML 字符串 |
| `pdf.getFixData` handler | 371668 | 在传入配置上合并 `:headers:` 与 calculated setting |
| `export.prepare` handler | 371909 | hideNotification，再加载并返回合并后的 option |
| `beforeExport` | 372057 | 同步/退出源码编辑、更新 TOC 与收起 UI |
| `exportToHTML` | 382481 | 从模型与当前渲染结果构造完整 HTML |
| `exportWithCommand` | 394878 | 自定义导出变量与保存对话框数据准备 |

## 3. prepare 是配置处理，没有资源等待保证

`loadExportOption`（module 4a，byte `412469`）读取元数据和项目/用户配置。基本白名单包括 title、author、subject、creator、split-level、toc-depth；允许 per-file setting 时加入 header/footer/sidebar 与 append-head/body 等。

getSetting 的实际优先顺序是 projectSetting → fileSetting → File.option，并处理 unset；不能仅因项目配置通常优先就假设所有值或所有格式相同。pdf/epub 的 append 字段有转换到 userAppendHead/Body 的逻辑。prepare 返回合并对象，没有等待全部图片/公式/字体的 readiness gate。

Mdown 建议使用明确、类型化的配置优先级与格式专属参数；导出前锁定 snapshot revision，不让前台主题/元数据变化污染进行中的 job。

## 4. dataForExport 的输出与模式副作用

`export.dataForExport` 在 macOS 外层延迟 50 ms；`beforeExport(forPrint)` 返回 true 时内层再延迟 1,000 ms，否则零延迟；随后 await exportToHTML。forImage 有默认字号/宽度参数。

已查实的返回字段：

| 字段 | 数据 |
|---|---|
| suggestedFilename | File 的建议文件名，空值兜底为空串 |
| content | 完整 HTML 文档字符串 |
| pdfHeader / pdfFooter | 从模板与 option 生成的 HTML/文字片段 |
| hasNonAlphabet | 编辑区域文本的连续四个 CJK 字符匹配结果；不能泛化成“任何非 ASCII 文字” |

`beforeExport` 在 source mode 会 hide SourceView、恢复侧栏，并通知 macOS 更新 source mode UI；否则 store 当前编辑状态。它还 File.sync、更新 TOC 与收起通知。导出可能改变当前显示模式，不能当成纯函数行为；Mdown 的设计建议是不可变快照导出，不在用户输入途中切换编辑模式。

`export.exportToHTML` 另有 macOS 400 ms 延迟，之后 File.sync 再生成 HTML。定时延迟不等价于资源加载成功，不能直接复制为 Mdown 的完成条件。

## 5. HTML 从模型和渲染结果派生

exportToHTML（byte `382481`）读取 nodeMap、metadata title、options、主题与样式，逐块处理文本/代码/表格/引用/定义/图表/数学等。代码块会使用 CodeMirror 的渲染结果；图表克隆 SVG 后处理；数学使用 MathJax 容器。forPrint 的标题可加入 `header-<cid>` / `af://<cid>` 标记，供 PDF 目录和链接修复使用。

查实的 await：

- 当前 MathBlock 编辑态存在且保留样式时，等待 stopEditing。
- inline math 在相应 copy format 条件下等待 renderAll（byte `383317`）。
- 导出主题需要 Mermaid 重新生成时，等待 mermaidSvgForExportTheme（调用 byte `390367`；定义 module 15 byte `1135056`），内部有 Promise.all 渲染。

样式路径包含 @import 深度限制、导出专属 include 条件、主题 CSS 内联与 Mermaid/ZenUML 过滤。`noBackground` 被解构后，专项跟踪未找到该方法内独立消费，不根据参数名声称透明背景总能保证。

**尚未建立的完成条件：**所有 img 解码、字体就绪、首次 MathJax 排版、非主题 Mermaid 渲染与异步 Promise rejection 的端到端完成/取消。静态上看到部分 await 不能升为“所有资源都已等待”。

## 6. Pandoc 的 native 指的是 AST 格式

`NodeMap.exportToNative` 位于 module 43，byte `344756`。输出 Pandoc native 格式文本，含 `Pandoc (Meta ...)` 和 block/inline AST；它不表示用 AppKit 绘制正文，也不是恢复的 Swift 源码。

module 46 的 wrapper 归一化 pandoc/native/raw/targetFormat、latex-pdf/mediawiki 等 target，生成 option；handler 回调 `{native, option}` 交给原生 PandocBridge。原生以 NSTask/argument array 执行转换，见 `NATIVE.md`。

媒体占位会转临时路径。图表/数学落盘的 `saveSVGToTempPath`（module 2a，byte `1204181`）在 macOS 走原生图片保存的 PNG 路径；失败有删除占位继续的静态分支，不能说所有失败会 abort 导出。epub 有数学编号状态准备。

成功/失败终态可调用临时文件清理；module 43 提供具体实现，module 46 的默认 cleanUpTempFiles 本身可为空。Mdown 应由 ExportJob 显式持有临时产物和终态，不靠服务实例上可被覆盖的 cleanup 函数隐含归属。

## 7. PDF 元数据闭环

`pdf.getFixData`（byte `371668`）对输入 option 合并 `:headers:` 和 getCalculatedSetting（byte `411947`，项目与文件配置）。outline header matrix 包含深度、纯文本标题、cid。

原生 `TyPDFEngine.repairPDFWith...`（`0x10002989c`）收到创建的 PDF 后请求这些数据；回调 `0x100029ab0` 读取 `:headers:` 并重绘、修目录、属性和字体 ToUnicode，再写盘。页眉页脚、纸张 margin、页码变量也在原生端使用。

Electron 的 PDF 后处理可用 PDF annotation 中的 af://cid 建映射；macOS 具体 anchor 坐标转换仍需核验，不能把 Node 宿主的首页高度/top-left 算法直接套到原生 PDFDestination。hasNonAlphabet 的渲染用途也不能由名字推断。

**Mdown 验收：**文字可搜索与复制、链接与 outline 正确、CJK/emoji 无缺字、分页和页眉页脚一致；仅截图完整不能证明这些语义。

## 8. 整文图片与单块导出要分开

module 44 exportToImage（byte `354184`）的 Node 路径会生成 HTML、调用 prepareImageCapture/captureImage，按 pageHeight 滚动捕获并交 worker 合成；存在最大图片/分页保护和保存面板取消后清理。它是整文档图片导出路径，不是单 Mermaid 输出的证明。

同一软件可能通过独立媒体菜单支持其他导出；本轮未把所有单块菜单、SVG 清理/格式规则完整追通。Mdown 的 D 线是独立产品合同，不应因看到了整文截图就宣称单块 PNG/SVG 等价。

## 9. 成功、失败、取消与风险

| 观察路径 | 实际处理 | 原生重建合同 |
|---|---|---|
| onExportCanceled | JS hideNotification；全部 native cleanup 尚未遍历 | cancelled 不能等同 succeeded/failed；任务级资源清理 |
| onExportFailed `{path,error}` | JS 显示错误并清理部分临时产物 | 保存失败不得报成功，不覆盖原文件 |
| image 取消 | Node 宿主 destroy capture view / terminate worker | native 也要可取消，清理仅本 job |
| Pandoc 取消/非零退出 | Node 宿主 kill/listener cleanup，stderr 提示 | Swift Process 需并行 drain、超时、取消和退出码 |
| 媒体临时保存失败 | 静态存在删占位后继续路径 | 不静默丢块；明确错误/降级并进入输出验证 |
| 模式切换后的定时等待 | 50/400/1000/1900 ms 等不同路径 | readiness 应由显式信号判定，固定 sleep 不是资源就绪证据 |

原生 Pandoc 当前实现先 waitUntilExit 再读 pipe（静态观察），输出量大的背压风险应在新实现避免。此次没有执行自定义导出命令、安装 Pandoc 或访问外部 URL。

## 10. 给 Mdown 的最小导出边界

1. Snapshot 持有 note identity、revision、source/结构、资源引用和导出配置；不读随时变化的隐藏 source view。
2. 每个格式拥有自己的 prepare/render/write/validate 合同；HTML、位图、PDF、Pandoc 不能强行共用一条状态路径。
3. 图片/字体/公式/图表分别报告 ready/failed/timeout/cancelled；输入和 source 保存不等这些 renderer 成功。
4. 导出服务和原生编辑器解耦，继续复用当前 Mdown 独立导出宿主，单 Mermaid D 线先交付。
5. 完全去 JS 时原生 renderer 必须逐类建立 corpus、语法/视觉/性能支持边界；禁止通过删除库而静默丢失功能。

未覆盖：vendor renderer 内部、全部 runtime 等待/取消、单块菜单全路径、mac PDF 锚点的精确坐标、官方原包所有格式实际输出。它们已进入行为验收待测项。
