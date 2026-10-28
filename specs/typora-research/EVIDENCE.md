# 证据索引与复核方法

更新：2026-10-14。本轮研究产物分为 Typora 本地样本静态证据、Mdown 源码核验、拟定实现合同三类。静态路径与函数存在不等于运行完成；建议不等于既有功能。

## 1. 身份基线

| 目标 | 身份/作用 |
|---|---|
| Mdown | `/Volumes/external/Projects/Mdown`，`main@b8110a942e27ae13ebe531b549a56e5a220f91ae` |
| 现有改动 | 研究开始时仅 `specs/typora-research/` 未跟踪；本轮只修改此目录 |
| Typora.app | Info.plist：1.12.6，7588，`abnerworks.Typora` |
| Typora 主程序 | SHA-256 `6fc6b2cf726f7366b8b0a62d0e2fa557ef8ec186dea9079c3f758c5a1e46962f` |
| appsrc/main.js | 1,639,455 bytes；SHA-256 `745d737c75397a1424e6211a8a9523349ecae5267f39e4a516790ac7f9cfeee8` |
| arm64 分析切片 | SHA-256 `35d2369c866af36e98cbca8a8dec5d408a8c78b8ec210d82b32c71a2b6857f57`；原包 arm64 区间与切片逐字节相等 |
| 官方发行身份 | 尚未验证。签名记录 Authority 为 `Antibiotics`，运行一致性需要官方原包基准 |

原始程序、恢复模块、汇编和工具运行日志保留在研究工作区，不复制进 Mdown 业务资源。Mdown 中只保存行为结论、证据地址/偏移、独立设计与自编样例。

## 2. REA Evidence

| ID | 操作 | 已得到的结论与限制 |
|---|---|---|
| `ev_eda34ac073ec3a08f1a7cfda2a8ad62beab761725490e58dee03e68bd2d50807` | `inspect_macho` | 完整 universal 两切片与系统依赖、load command 等；imports/exports 受工具和符号可见性影响 |
| `ev_b53586590447a2f495b9ac27cbce660ffcc35ef7912062ec0e475e24d2db8b14` | `inspect_signature` | 指定字节样本签名字段；未作官方来源和系统信任验证 |
| `ev_4f70c403206fe59ec78a099fd4a11f5d8d3b865265d5796d851a7391b3dba6a7` | 上轮 `analyze_javascript_application` 父记录 | graph partial；main.js 等大文件语义分析受到资源限制。2026-10-14 本轮查询 matching retained records 为 0，不能当作仍可调用的 retained reference |
| `ev_f49a105e399a5a6730873c54461840da16b844cbb0c758c0a0c9fb4c9a230e46` | 上轮摘要视图 | 191 个相关文件，23 个 parsed JavaScript files，0 parse failures；并非“191 个文件全都语义解析完成” |
| `ev_728cbaf1cb2a1908f2860401568f3216e3014b48de1487aeab99adbe93a7d8db` | 上轮 main.js asset 视图 | 文件身份和 parse 状态；不包含全部编辑器数据流 |

本轮不重复执行上一轮的全 TypeMark 分析。对大 bundle 使用惰性语法解析和文件偏移跟踪，并把它们标为普通静态源码观察。

## 3. 本机原生证据路径

基础路径：`/Volumes/external/Projects/typora-r/research/`。

- `native-input-arm64/provenance.json`、`slice-verification.json`：原包与切片来源、位置及逐字节核验。
- `native-offline/macho-evidence.json`、`signature-evidence.json`：本轮可携带的完整 REA Evidence。
- `native-offline/commands.json`：实际执行的 `otool -ov`、`-tvV`、`-l` 参数、输出文件和大小。
- `native-offline/objc.txt`、`disassembly.txt`、`load-commands.txt`：完整原生工具输出。
- `native-offline/cfstrings.json`、`methods.json`、`selected-index.json`、`extra-selected-index.json`：原生字段、方法地址和局部视图索引。
- `native-offline/selected/`、`extra-selected/`、`callback-slices/`：聚焦函数和 block callback 的汇编片段。
- `native-offline/evidence-manifest.json`：已保存文件的长度与 SHA-256。局部字符串解码说明是分析者候选，不伪称 Hopper 原生标注。
- `native-verify/report.md`：已生成的独立静态复核报告，交叉检查切片字节、CFString 地址、同步/快照/导出分支及符号计数；其中首键地址与时间界限曾误读，已对照原始字节纠正后采用。

典型原生定位：

| 范围 | 方法/地址 |
|---|---|
| 脏状态与同步入口 | `-[DocumentCommands setup]` `0x10005fd60` |
| 多窗口变更广播 | `-[Document syncChange:]` `0x100043264` |
| 多窗口 Oversize 通知 | `-[Document enterOversize]` `0x1000434a4` |
| 会话快照 | `-[Document buildDocumentSnap:]` `0x100040fd0` |
| 快照 JSON | `-[DocumentSnap jsonObject]` `0x100065340` |
| 同步桥 | `-[CommandBridge callSync:]` `0x10000f524` |
| WK prompt 桥回调 | `0x10000f654` |
| 导出 prepare | `-[TyWindowController(Export) _exportWithOption:]` `0x100074bd0` |
| 导出 type 分流 callback | `0x100074cc8` |
| 独立导出 WKWebView | `makeExportViewWithHTML:width:` `0x100071b5c` |
| PDF 创建 | `_doPrintTo:from:withOption:` `0x100073a08` |
| PDF 修复请求/回调 | `0x10002989c` / `0x100029ab0` |
| Pandoc Process 配置 | `-[PandocBridge prepPandocTask:]` `0x100058560` |
| TextBundle asset handler | `0x10001df94` |

所有上述地址均为 arm64 虚拟地址，不是文件偏移。原包的 slice 偏移和 thin image 的 section 映射是两个不同层次。

## 4. JS 证据定位方法

JS bundle 的 minified 模块号仅对当前 SHA-256 有效，不是跨版本稳定身份。`main.js` 中语法位置应明确使用 UTF-8 byte offset 或 UTF-16 code unit；二者不能混用。

查找例：

```bash
rg -o 'tryEnterOversize|registerHandler|dataForExport|buildUndo|compositionend' \
  /Volumes/external/Projects/typora-r/Typora.app/Contents/Resources/TypeMark/appsrc/main.js
```

词频仅帮助定位，不能证明以下命题：某 parser 库的名称、DOM 类名用途、单块图表导出功能、代码路径运行可达或性能。真正结论需要模块的调用点、定义与上下文。

独立研究报告及其语法摘录在 `research/editor-model/` 和 `research/export-pipeline/`。编辑侧完整报告为 finding-report.md / NOTES.md；导出侧结论以会话交付与已保存 module 视图为准，report.md 写入曾被宿主权限 hook 拦截，未重试覆盖或扩大权限。父会话重新核验的字节定位存于 `research/js-final-anchors.json`、`js-export-verified-anchors.json`，最终结论写入本目录 EDITOR-MODEL.md / EXPORT.md。这些是本机研究产物，不是业务源码，也不需要导入 Mdown 构建。

## 5. 缺失证据与继续条件

| 缺失项 | 当前事实 | 下一步 |
|---|---|---|
| Hopper 函数 dossier | `open_binary` 成功绑定后实际启动仍被 Apple Events 拒绝 | 修复宿主 Automation 权限；关闭/恢复本任务旧会话后对指定函数分析 |
| Hopper 内置 MCP 运行查询 | 能读取工具 schema；list_documents 超时 | 用户在 Hopper 中确认可分析文档和可响应接口，再作一次有新条件的探测 |
| Typora 实际输入、视觉和性能 | 本轮未启动目标或操作文档 | 官方原包 + 本任务样例，记录版本、操作、正文/选区、截图与延迟 |
| 全部功能同等性 | 未定义完整且观测过的比较全集 | 按 fixtures 的行为矩阵逐项建立可对比 oracle，未知项保持 pending |
| 本地副本与官方代码一致性 | 未建立 | 用官方包重复哈希/签名和重点行为验证 |

故障不是许可扩大范围的依据。本轮不安装分析引擎、不修改 REA 全局注册、不删除共享租约、不结束用户的 Hopper GUI、不下载或发布目标程序。
