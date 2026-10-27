# T00 — 基线、语法与行为 corpus

记录日期：2026-10-14（首次）/ 2026-10-15（复核）。执行环境：本机 macOS（Darwin 27.0.0）、Xcode 27.0 (27A266a)、SDK MacOSX27.0。
仓库基线：`main@b8110a942e27ae13ebe531b549a56e5a220f91ae`。首次记录时工作区除 specs/ 外无改动；2026-10-15 复核时已有 T01–T04 在途改动（§1.2）。

## 1. 本机构建/测试基线

项目 `MACOSX_DEPLOYMENT_TARGET = 11.5`（pbxproj 9 处）低于本机 SDK 支持下限 12.0，默认命令无法构建。**不改项目文件**，本机一律追加 override：

```bash
# 本机可行基线命令（与 CLAUDE.md 记录的 CODE_SIGNING_ALLOWED=NO 形态的差异见 §2）
xcodebuild -project Mdown.xcodeproj -scheme Mdown -configuration Debug \
  CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0 build          # SUCCEEDED
xcodebuild test -project Mdown.xcodeproj -scheme Mdown \
  -destination 'platform=macOS' MACOSX_DEPLOYMENT_TARGET=12.0 \
  CODE_SIGN_IDENTITY=-                                                 # 全量单测
```

### 1.1 首次结果（clean main@b8110a9 + T00 产出，2026-10-14）

| 项 | 结果 |
|---|---|
| Debug build（override 后） | SUCCEEDED |
| 全量单测 | 181 tests, 8 failures（3 个 test case，0 unexpected） |
| swiftlint --strict | 0 violations（151 files） |
| swift-format | **本机未安装**（`command not found`）；CI 仍会跑，不改全局工具配置，后续 lint 变更在 CI 验证 |

失败明细（均为 WKWebView 渲染路径，非本次改动引入；本文件 §2 解释环境归因）：

| Test case | 现象 |
|---|---|
| `MathRenderingRuntimeTests/testPreviewAndPPTRenderNestedUnderbraceWithKaTeX` | KaTeX 在 preview.html 与 ppt.html 均等待超时（2 断言错误，20.25s） |
| `MermaidExportTests/testInvalidMermaidFallsBackWithoutOrphanError` | 状态为 nil 而非 "failed"（2 断言错误） |
| `MermaidExportTests/testRenderedMermaidSurvivesExportReloadWithoutOrphanError` | 同类 Mermaid 状态断言失败（4 断言错误） |

### 1.2 复核结果（含 T01–T04 在途改动，2026-10-15）

工作区不再 clean：T01（Vditor setter/owner 修复 + ActiveEditingBackend）、T02（EditTransaction + SourceMap）、T03（LosslessParser + ProjectionBuilder）、T04/G0（RichMarkdownTextView + EditorHistory 原型）已产生 ~1700 行新代码与 8 个文件修改（详见各自 `validation/T01~T03/README.md` 与 `validation/G0/README.md`）。

| 项 | 复核结果 | 与首次差异 |
|---|---|---|
| Debug build | SUCCEEDED | 无回归 |
| 全量单测 | 258 tests, 14 failures（8 test case，0 unexpected） | +77 tests（T01–T04 新增）；+5 failing case（全部为 G0 已知原型缺口，见下表） |
| swiftlint --strict | 0 violations（168 files） | +17 files 均通过 |
| Corpus 完整性 | 8/8 SHA256 匹配，8/8 bytes 匹配；研究 fixtures 4 项 byte-identical | 无变化 |

基线环境失败（§1.1 的 3 case）在相同形态下复现、断言错误数一致；新增 5 个失败 case 全部已在 `validation/G0/README.md` 登记（有根因假设与下一步）：

| 新增失败 case | G0 编号 | 归因 |
|---|---|---|
| `RichMarkdownEditingTests/testLargeDocumentProbe` | G0 #1 | 214KiB 全量重建超预算（3.2s build / 3.1s editSync） |
| `MarkdownCompositionTests/testCompositionFollowedByTypingStaysConsistent` | G0 #2 | unmarkText selection 恢复不走投影映射 |
| `MarkdownCompositionTests/testCommitDoesNotWholeReplaceWhileMarked` | G0 #3 | 同 #2 传导 |
| `RichMarkdownEditingTests/testEnterSplitsListItemAtSameLevel` | G0 #4 | list 容器行级映射边界 |
| `RichMarkdownEditingTests/testTypingPlainParagraphReachesSource` | 补充 | 全量轮 flaky（专项轮绿；firstResponder 顺序敏感） |

**结论：T01–T04 在途改动未引入基线外的新失败；环境性失败与 G0 原型失败均已知、有登记。基线仍然有效。**

## 2. 签名与环境差异（本机新事实，影响后续所有本机验证）

- 本机无 Team `5EH69Y5X38` 的 "Mac Development" 证书：默认签名 test 报 `No signing certificate found`。
- `CODE_SIGNING_ALLOWED=NO`（CLAUDE.md 记录的本机形态）在 Xcode 27 下出现 **test runner hung before establishing connection**（333s 超时，纯逻辑单类同样挂起；Mdown.app 本体可正常启动运行）。归因假设：无签名宿主无法被 Xcode 27 runner attach，待证。
- **可行组合：`CODE_SIGN_IDENTITY=-`（ad-hoc 签名）**，runner 正常连接，181 tests 全部执行。T00 起本机单测统一用该形态。
- 上述 3 个 WKWebView 失败在 ad-hoc 签名下出现，宿主日志大量 `Sandbox restriction`（WebContent 进程）。待证假设：ad-hoc 签名无 entitlements 导致 macOS 27 沙箱限制 WebContent，CI（macos-15、CODE_SIGNING_ALLOWED=NO）上这些测试通过。**判定为环境性失败，不作为代码回归处理，也不顺手修**；后续涉及 WKWebView 的验收在本机记录该限制。

## 3. Corpus（MdownTests/Fixtures/NativeEditor/）

复用 `specs/typora-research/fixtures/` 4 个样本（byte-identical，SHA256 与研究 manifest 核对一致），新增 4 个生成样本，manifest 见 `MdownTests/Fixtures/NativeEditor/manifest.json`：

| 文件 | 覆盖 | SHA256（前 8） |
|---|---|---|
| editor-behavior.md | 组合重音/emoji、metadata、ref/footnote、三层 list、table pipe/code、nested fence、错误 mermaid、HTML | fc7364b7 |
| roundtrip-crlf.md | 纯 CRLF | 0d6e0526 |
| roundtrip-no-final-newline.md | 无末尾换行 | 82413095 |
| behavior-cases.json | 16 项行为合同输入 | f3b8b9e6 |
| bom-utf8.md | UTF8 BOM + frontmatter | 27be6fa9 |
| mixed-eol.md | LF/CRLF 混合 | 14a332cf |
| tabs.md | tab 缩进列表 / code block 内 tab / 行内 tab | 863d02fc |
| bad-math.md | 未闭合 $ / $$、悬空美元、错误 \frac | a5526370 |

压力样本（200KiB/2k 行、1MiB、10MiB）**不进 repo/bundle**：由测试内确定性生成器按 manifest `stress_specs` 产生，首次固化后回填期望 SHA256；此决定为 T00 设计选择（repo 卫生 + hash 仍固定）。

注册证据：9 文件 + 2 group（`Fixtures`/`NativeEditor`）注册进 pbxproj（BuildFile/FileReference/group children/MdownTests Resources phase 四处），`plutil -lint` 通过。`MdownTests/NativeEditorFixtureTests.swift`（5 tests，Bundle 查找 + SHA256 + BOM/CRLF/tab/无末尾换行特征断言）注册进 Sources 并通过：**5/5 passed**。

## 4. 当前编辑栈 baseline（代码事实，供迁移对比）

以 `main@b8110a9` 为准；行号为该提交下位置。

- **Vditor 桥**（`Views/VditorEditView.swift`、`Resources/DownView.bundle/editor.html`）：
  - `editor.html:146` `setMarkdown` 用 `isUpdatingFromSwift` + `setTimeout(100ms)` 固定 sleep 抑制程序化 setValue 触发的 `vditorChange`——T01 目标风险 #1（错配/丢输入窗口）在源码可见。
  - `VditorEditView.handleContentChanged`（164）每次 change 直接 `note.content = NSMutableAttributedString(string:)` 覆盖 Note buffer，0.5s debounce 后 `persistNote`（`blockFSUpdates` + `note.save(content:)`）。保存走 0.5s 外层 timer，非 Note 自身 1.5s debounce。
  - `loadNote`（124）仅当 `hasUnsavedChanges` 才 persist outgoing；纯浏览不写盘（既有测试 `testVditorEditViewSwitchNotesWithoutEditingDoesNotTouchDisk` 固定）。
  - `flushPendingSave` 只在 `viewWillMove(toWindow: nil)` 触发；Cmd+S/quit 路径对 Vditor 的处理待 T01 复现验证。
  - 既有测试：`VditorIntegrationTests` 10 项（资源存在 2、行为 6、layout 2），无保存竞争/setter 错配覆盖。
- **Prettier**（`Controllers/ViewController+Editor.swift:912 formatText`、`PrettierFormatter(plugins: [MarkdownPlugin()], parser: MarkdownParser())`）：异步 Task + `formatRequestID` 竞争防护 + `editArea.storageNote === note` owner guard（#543 修复后形态）；取消路径 toast "Formatting cancelled"。source 模式专用；Vditor rich 模式未接 Prettier。Prettier golden 输出尚未采集（T00 未运行格式化实机对比，标未知，T18 采）。
- **默认编辑面**：`EditTextView`（NSTextView + CustomTextStorage）source 模式为主路径；性能阈值在 `NotesTextProcessor`（>1MB/64KB 段、>5000/2000 行分级简化）。
- **模式**：⌘1 侧栏、⌘2 列表、⌘3 preview、⌘4 presentation、⌘5 TOC、⌘0 actual size（storyboard 绑定）；wysiwyg 为独立开关（`EditorStateManager`）。

## 5. 固定输入序列（验收用，输出 source/selection/viewstate/文件，非截图）

实现阶段在 `validation/<阶段>/` 逐项回填实测；序列本身不在本 T00 执行（无官方基准时不做 Typora 对照）：

1. **输入**：`fixtures/editor-behavior.md` 加载 → 在 §1 段落中逐字输入「中文字符串」→ IME 组合（start/update/cancel、start/update/commit）→ 在 `**未完成的加粗` 内续写 → code block 内输入含 `**` 文本。
2. **选择**：paragraph 起点 shift+↓ 连续跨入 code block、跨入 table cell；鼠标拖选跨 `**AB**普通*CD*`；hidden marker 双侧 caret 移动。
3. **复制**：rich 内复制可见文本 vs 复制 Markdown 源（两种意图）；从外部粘贴 plain text / HTML / 图片文件。
4. **模式**：source → wysiwyg → split → preview 往返，记录每步后 `Note.content`、revision/owner、`⌘S` 后磁盘 hash。
5. **undo**：上述每类操作后 ⌘Z 到起点，再 ⇧⌘Z 重做；跨模式切换后继续 undo。
6. **导出**：含 Mermaid（对/错两版本）+ 数学 + 图片的文档导出 PDF/PNG，核对产物尺寸、非空渲染、源文件 hash 不变。

## 6. 官方 Typora 基准状态

**Blocked**：本地仅 `/Volumes/external/Projects/typora-r/Typora.app`（1.12.6/7588，签名 Authority `Antibiotics`，非官方来源验证）。按 PLAN 不自动下载/启动新样本。AC-21 在官方基准可用前不计 pass；原生原型（T02+）不受此阻塞。

## 7. T00 退出门自检

- [x] 样例 hash 固定（manifest + 测试断言双重）；2026-10-15 复核 8/8 hash+bytes 通过
- [x] 步骤固定（§5 序列定义）
- [x] baseline 失败有位置与根因/待证假设（§1.1、§2；2026-10-15 复核确认 3 个环境 case 不变，5 个 G0 case 均有登记）
- [x] 官方样本缺失不阻止原生原型（§6）；AC-21 保持不计 pass
- [x] 2026-10-15 复核：build SUCCEEDED / swiftlint 0 violations / corpus 完整；T01–T04 在途改动未引入基线外新失败
