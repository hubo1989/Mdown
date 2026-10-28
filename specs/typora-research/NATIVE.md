# Typora 原生文档、桥接与导出边界

状态：2026-10-14 静态研究。已获得 ARM64 反汇编；Hopper 伪代码与运行行为尚未获得。本文件描述指定本地副本，供 Mdown 独立实现行为时参考，不包含供项目复用的 Typora 实现代码。

## 1. 目标身份和证据

| 对象 | 已核验身份 |
|---|---|
| 本地应用 | `/Volumes/external/Projects/typora-r/Typora.app`，Info.plist 为 1.12.6 / 7588 / `abnerworks.Typora` |
| universal 主程序 SHA-256 | `6fc6b2cf726f7366b8b0a62d0e2fa557ef8ec186dea9079c3f758c5a1e46962f` |
| arm64 切片 SHA-256 | `35d2369c866af36e98cbca8a8dec5d408a8c78b8ec210d82b32c71a2b6857f57` |
| 切片对应关系 | 原包偏移 1,572,864，长度 1,606,992 字节；与 `lipo -thin arm64` 产物逐字节相等 |
| REA Mach-O Evidence | `ev_eda34ac073ec3a08f1a7cfda2a8ad62beab761725490e58dee03e68bd2d50807` |
| REA 签名 Evidence | `ev_b53586590447a2f495b9ac27cbce660ffcc35ef7912062ec0e475e24d2db8b14` |
| 本地副本限制 | Authority 为 `Antibiotics`，TeamIdentifier 未返回。未验证为官方发行包，不据此假设官方发布行为 |

完整本机证据位于 `/Volumes/external/Projects/typora-r/research/native-offline/`：`objc.txt`、`disassembly.txt`、`load-commands.txt`、`macho-evidence.json`、`signature-evidence.json`、`cfstrings.json`、`methods.json`、`evidence-manifest.json`。切片来源与逐字节验证位于同级 `native-input-arm64/`。`selected/`、`extra-selected/` 是带源行号的函数视图。

REA `open_binary` 只完成文件身份与 provider 绑定。实际调用 `binary_overview` 后，启动器仍返回 `Not authorized to send Apple events to Hopper Disassembler`。旧路径还存在目标租约；已通过本次命令环境定位 `/Applications/Hopper Disassembler.app/Contents/MacOS/hopper`，未修改全局配置。临时 REA CLI 进程已结束，`close_binary` 报 `cleanup_incomplete`，遗留 `/tmp/rea-nGJaXH`、`/tmp/rea-ZcCPRz` 未擅自删除；Hopper GUI 的关闭未确认。Hopper 内置 MCP 能返回工具清单，但 `list_documents` 在十五秒内未响应，未重复探测。

下列函数事实来自系统 `otool -ov` / `otool -tvV` 和 Mach-O 常量解码，**不是 REA 函数 dossier**。每个地址是该 arm64 切片的虚拟地址；不能把普通 shell 观察标成 REA 反编译结果。CFString 候选注释与原指令、原始地址一起保留。

## 2. 原生层不是只有薄窗口壳

`__objc_classlist` 大小 `0x318`，每项 8 字节，共 **99 个类条目**。旧报告的 198 把 instance class 与 metaclass 重复计算。切片 `nm -gU` 实际还返回 `__mh_execute_header`，`nm -m` 返回 6,670 条记录，含 `Document.syncChange:`、`CommandBridge.callSync:` 等 non-external 方法符号。旧报告“零导出因此全 strip”收回；公开业务导出较少不等于局部符号被剥离。

实际分工包括：

- `Document` / `DocumentSnap`：NSDocument 生命周期、内容同步、会话快照、原地自动保存。
- `CommandBridge` / `*Commands`：按域接入 WebKit，负责菜单、文本服务、窗口、文件和配置。
- `TyWindowController(Export)` / `(ImageExport)`：导出入口、保存面板、独立导出视图、成功/失败/取消反馈。
- `TyPDFEngine`：PDF 链接、目录、页眉页脚、属性与字体映射处理。
- `PandocBridge` / `SpawnTask`：外部转换任务与进程通信。
- `DocWebViewURLHandler`：当前文档 TextBundle 附件供给。

`libTypora.dylib` 的授权职责没有函数证据。本轮不分析它的许可证逻辑，不再将“少量字符串或少量导出”推成其职责定论。

## 3. 文档同步是按文档和窗口分发

| 路径 | 反汇编锚点 | 查实的动作 |
|---|---|---|
| `DocumentCommands.setup` | `0x10005fd60`；汇编源行 98741 | 注册 `document.updateChangeCount`、`updateChangeCountIfUnedited`、`enterOversize`、`syncChangeIfNeeded` 等 handler |
| `syncChangeIfNeeded` 的 block | `0x100060460` | 读取 `controller.shouldTriggerSyncChange`；真时调用 `document.syncChange:`；回调返回该布尔值 |
| `shouldTriggerSyncChange` | `0x100076ac8` | 仅当前活动窗口且 linkedWindowControllers 数量大于一时返回真 |
| `Document.syncChange:` | `0x100043264`；源行 68781 | 少于两个 window controller 时退出；忽略 null/空 payload；锁住 activeWindow，枚举其他窗口，发送 `editor.applyChange` |
| `Document.enterOversize` | `0x1000434a4`；源行 68926 | 至少两个窗口时，向非 activeWindow 运行 `File.tryEnterOversize('', true, true);` |
| `Document.syncToSelf` | `0x1000415a0`；源行 66908 | 锁定文档时退出；通过 `MainThreadRunner` 取客户端内容，并在当前 RunLoop 等回调 |
| `Document.syncToClient` | `0x100041898`；源行 67101 | 正在加载 WebView 时跳过；清理旧 snap，并向活动窗口请求 `File.reloadContent` |

`enterOversize` 本体没有按文本长度判阈值。阈值和模式转换必须读 JS 的 `tryEnterOversize`，不能仅凭原生 handler 名得出“超长文档关闭统计和全量同步”。跨窗口同步与磁盘重新载入也应分别建模。

**Mdown 建议：**用 `noteID + revision + editorSessionID` 标识编辑事务及其结果。其他窗口/预览收到的是同一文档的新 revision，当前选中行不能成为持久化 owner。后台渲染、附件、导出回调都应先核对 owner 和 revision，再发布结果。这是拟采用的设计，不是从 Typora 读出的字段名。

## 4. 快照包含完整编辑会话

`Document.buildDocumentSnap:` 位于 `0x100040fd0`，汇编源行 66532。它先用 payload 的 `content` 更新 Document，再建立 `DocumentSnap`。

查实读取/保存的字段：`nodeMap`、`undoRedo`、`useCRLF`、`finalNewline`、`fromSourceMode`、`srcHist`、`content`、`timeStamp`、`cursorPos`、`scrollOffset`。从源码模式生成时设置 `srcContent` 和 `srcHist`；另一路保留旧快照的源码内容/历史。新 payload 没有 scrollOffset 时存在沿用旧值的分支。

`DocumentSnap.jsonObject` 位于 `0x100065340`，还序列化 `srcContent`、`isOutDated`、`fromPath` 等。`DocumentCommands.buildDocumentSnap:` 位于 `0x10006101c`，仅当前活动窗口才会把 payload 交给 Document，其他窗口不更新原生 snap。由此可见：**原生层接收并保存 JS 编辑历史与视图状态**。不能继续表述为“JS undo 与原生文件备份完全独立”。

**原生重建需要保留的合同：**

1. 文本、模式、选择范围、滚动位置属于同一文档会话。
2. 模式切换必须定义撤销连续性和 source selection 映射。
3. CRLF、末尾换行与源码格式不能因打开/关闭编辑模式被无意改写。
4. 崩溃恢复的会话状态与磁盘版本备份用途不同；两者可共享数据，不混用成功条件。

保存入口 `Document.dataOfType:error:` 位于 `0x1000420f4`，对原生 content 调用 `dataUsingEncoding:4`（UTF-8）。这说明磁盘写入最终依赖原生内容缓冲，并不证明前端提供的 source 已经无损。`restoreStateWithCoder:` 位于 `0x10004087c`，本体调用 superclass 再写一个状态标志；完整快照恢复还需要追踪其上游和 JS 载入路径，不能仅凭方法存在宣称崩溃恢复已验证。

## 5. 同步桥的真实机制与迁移取舍

- `CommandBridge.callSync:`，`0x10000f524`，源行 14631：解析 JSON，读取 `name`、`data`、`method`；按 `groupForString:` 找服务，调用 `callMethod:data:`，再序列化结果。
- `webView:runJavaScriptTextInputPanelWithPrompt:...`，`0x10000f654`，源行 14708：prompt 与 `__bridge__` 相等时调用 `callSync:`，把结果送入 WebKit completionHandler。
- `evaluateJavaScriptSync:`，`0x10000f274`，源行 14453：调用异步 WebKit evaluation 后 pump RunLoop 等待。循环计数为 50，读取的时间步长常量为 0.1 秒；不能把这个轮询机制视为严格的五秒 deadline 或低开销保证。

**Mdown 的目标是本地编辑器，推荐：**编辑命令直接调用类型化 Swift 服务；必须跨渲染进程时采用异步请求、明确超时与取消。无需仿照 JS prompt 同步 RPC，也不复制它的 RunLoop 轮询。移除 JS 编辑依赖并不要求移除 AppKit 原生菜单、系统剪贴板和 NSSpellChecker。

`WordCommands.getSpellSuggestionInContext:from:withLength:`，`0x1000618b4`，实际调用 `guessesForWordRange:inString:language:inSpellDocumentWithTag:`。这是系统拼写服务的函数证据，不再仅凭方法名字推断。

## 6. macOS 配置通过注入脚本接入

`SettingCommands.preSetupScript` 位于 `0x100023798`，构造 `window._options = { ... }`，含 keyboardLayout、mountFolder、isLocked 与若干快捷键。`DocumentCommands.preSetupScript` 位于 `0x100060bb8`，注入 `window._documentState=%@`，setup 再用 `presetScriptOnStart:` 注册。

`html/content.html` 中的 `process.argv / --tyopt` 只在 `window.process` 存在时执行；不能当成 macOS WKWebView 的统一配置入口。

## 7. 导出是分支合同，PDF 是二次加工

`TyWindowController(Export)._exportWithOption:` 位于 `0x100074bd0`，先请求 `export.prepare`。回调 `0x100074cc8` 按 `type` 分流：

| type | 原生后续方法 | 对应 JS 请求 |
|---|---|---|
| `pdf` | `exportPDF:` / `wkExportToPDF:` | `export.dataForExport` |
| `html` | `exportHTML:` | `export.exportToHTML` |
| `html-plain` | `exportHTMLWithoutStyles:` | HTML 路径 |
| `image` | `exportImage:` | `export.dataForExport` |
| `custom` | `exportWithCommand:` | `export.exportWithCommand` |
| 其他格式 | `exportWithPandoc:` | `export.exportToNative`，返回序列化结果后继续转换 |

所以 `prepare → dataForExport → exportToHTML/exportWithCommand` 不是所有格式共享的串行顺序。

`makeExportViewWithHTML:width:` 位于 `0x100071b5c`：把 HTML 写入临时文件，建立独立 `WKCommonWebView` 后加载。其 `allowingReadAccessToURL` 指向 `/`；这是当前副本的观测，Mdown 不应照搬广泛文件授权，应限定笔记、附件及本次导出临时目录。

`_doPrintTo:from:withOption:` 位于 `0x100073a08`，实际调用 `createPDFWithConfiguration:completionHandler:`。`TyPDFEngine.repairPDFWith:orFile:to:withOption:callback:` 位于 `0x10002989c`，载入 PDFDocument 并向 JS 请求 `pdf.getFixData`。回调 `0x100029ab0` 的次序为：

`redrawPDFContent → addOutline → addAttributes → fixFontFrom → writeToFile → callback`。

修复用途有实际指令和常量佐证：

- `repairURLForPage:on:withPageNo:`，`0x100027e60`：解析 PDF 页面链接，处理 `af://`、`at://`、`uaf://`、`uat://`、`applewebdata://` 等标记，并设置 URL/link destination。
- `redrawPDFContent:withOption:`，`0x1000283d4`：重绘 PDF 页，处理 backgroundColorStr、paper margin、pdfHeader/pdfFooter、`${pageNo}` 与 `${totalPages}`。
- `buildOutlineWithObject:onPDF:`，`0x100029488`：构造 PDFOutline 和 PDFDestination。修复回调读取的 JS 字段为 `:headers:`。
- `fixFontFrom:To:`，`0x100029120`：用 YPDocument 查看源与目标 PDF 的 Font、BaseFont、ToUnicode、Subtype，并修改目标映射。静态实现存在不代表每种字体都已运行验证。

**Mdown 的导出门槛：**中文和 emoji 不缺字、不裁切；PDF 文字可搜索与复制；内链和目录正确；页眉页脚与页码一致；失败或取消不产生成功提示、不覆盖已有文件。SVG/PNG 单块导出与整文档 PDF 是两套合同。

## 8. Pandoc 服务的复用与改进

`PandocBridge.prepPandocTask:`，`0x100058560`：创建 NSTask，设置环境、launchPath、argument array、独立 stdout/stderr pipe。`runTask:input:onBefore:onAfter:`，`0x100058f38`：可接 stdin，并把执行安排到 global queue。其后台 block `0x100059190` 会 launch、写/关 stdin、waitUntilExit，再读 stderr/stdout；完成 block `0x100059530` 检查状态并回调布尔结果和输出。

**迁移判断：**使用 Swift Process 和 argument array 接入可选 Pandoc 是合理路径；不要照搬先等待退出再读取 pipe 的顺序，输出较多时可能产生背压。Mdown 新实现需并行 drain stdout/stderr、设置取消与超时、记录退出状态。自定义 shell export 是显式高级能力，不因目标“体验一致”自动开启或安装外部命令。

## 9. 资源 handler 的已知边界

`DocWebViewURLHandler.webView:startURLSchemeTask:` 位于 `0x10001df94`，源行 30007：

`request.URL.path.lastPathComponent → document.textbundleDocument.asset: → regularFileContents → MIME/response/data/finish`。

附件不存在时调用 didFailWithError；stopURLSchemeTask 另有入口。它是当前 TextBundle 附件读入实现，**没有证据证明它是任意本地文件通用安全 handler**。原报告“绕过 file:// 并建立安全边界”收回。注册点 `0x10005b164` 的 scheme 是 `textbundle`；同一设置路径还可观察到 `_setAllowUniversalAccessFromFileURLs:`，这是另一套 file URL 权限机制，不能用附件 handler 的边界概括整个 WebView 的访问范围。

## 10. 剩余验证

| 问题 | 状态 | 下一项证据 |
|---|---|---|
| 文档、快照、同步桥、导出分流的函数存在与调用 | 已有静态反汇编 | 用 Hopper dossier 交叉复核局部值流 |
| PDF 修复字段和系统 API | 已有静态证据 | 官方包导出中文、内部链接与 outline 样例 |
| Enter/Backspace/IME 和选区的用户可见效果 | 未进行原生 UI 验证 | 官方包、任务专用 Markdown 样例、输入序列和录屏/截图 |
| 性能、超长文档体验 | 未测量 | 固定文档、硬件、版本下的延迟与内存观测 |
| 官方包与当前副本一致性 | 未建立 | 官方发布包的签名/摘要及相同场景运行结果 |

本轮研究可以支持独立实现的边界和行为清单，不支持声称“已完全复刻 Typora”或“全部原生层已反编译”。
