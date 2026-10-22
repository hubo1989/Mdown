# T22 验证记录 — 三编辑依赖退场(N2 门,部分)— 2026-10-22

前序 `9903146`(T19 part 1)。T21 的 signed-Sandbox/真机 IME 矩阵无法在
本会话完成(需维护者签名环境与真实输入法),按 PLAN 标 partial;源码/
工程/产物级退依赖已执行并验证。

## 已交付

- **移除**(T22 任务卡指定项):
  `Views/VditorEditView.swift`、`Resources/DownView.bundle/editor.html`、
  `Resources/DownView.bundle/vditor/`、
  `MiaoYanTests/VditorIntegrationTests.swift`、
  `MiaoYanTests/VditorBridgeContractTests.swift`。
- **包退场**:`Package.swift` 去 Highlightr + Prettier;两份
  `Package.resolved` 去对应 pin(其余 pin 原值保留);pbxproj 去全部
  产品/包引用(按花括号深度剥离,曾有一次嵌套 `};` 误删全文件的事故,
  从 HEAD 恢复后以深度追踪算法重做,断言 PBXBuildFile 计数与结构完整)。
- **路由迁移**:`activeWysiwygBackend` 恒返回 nativeRichHost——legacy
  `useNativeWysiwyg=false` 值兼容迁移为 native;Vditor 创建块、
  `setVisibleWysiwygBackend` 的 vditor 分支、外观调用、
  `extension VditorEditView: WysiwygEditingBackend` 全部移除。
- **测试替换**(行为逐项映射,不删断言绕过):
  `NativeWysiwygContractTests`(9 例):资源反向断言(vditor/、
  editor.html 已除,index.html 等 renderer 资源保留)、初始化/loadNote/
  外观/初始状态、切笔记不动盘、非预载异步装载、快速切换 stale 拒绝、
  编辑镜像+flush 落盘。`NativeEditorModeMigrationTests` 的 Vditor
  conformance 例改为 legacy 值迁移断言(源码体扫描);
  `EditingTransitionTests.BackendCaptureStubContext` 与
  `EditorStorageOwnershipTests`/`NoteSaveDebounceTests` 的硬保存点
  用例移植到 NativeRichEditorHostView(经 T14 整篇替换事务模拟编辑)。

## 验证

| 项 | 结果 |
|---|---|
| 包图解析 | 仅 Sparkle / swift-cmark-gfm / KeyboardShortcuts(无 Highlightr/Prettier) |
| 全量套件 | **577 tests, 8 failures** = 既有 3 个 WebKit 环境用例多次断言(基线已证,非回归) |
| 产物级(T22 门) | 主二进制 strings 无 Highlightr/PrettierFormatter;otool 无相关 dylib;bundle 无 vditor 资源 |
| SwiftLint --strict / swift-format(触及) | 0 violations |

过程事故:探针启动曾把 Debug 产物 CFBundleIdentifier 改为
`com.mdown.t22.probe` 未还原,导致测试宿主注入挂起("test runner hung
before establishing connection");还原为 com.tw93.miaoyan 后即恢复。
教训已吸收:探针对构建产物的临时改动必须同会话还原。

## 未完成(partial,不冒充)

1. T21 全矩阵:signed Sandbox 保存/取消/覆盖/授权失效、真实 IME
   步骤、1/10 MiB 压力、trace/内存——需维护者签名环境与真机。
2. 实机 typing/format/highlight/save/导出回归(产物级证据已具备,
   运行级 smoke 在 T21 矩阵内)。
3. `useNativeWysiwyg` defaults key 的存废未清(保留读取兼容,无 UI)。
4. `MarkdownEditorCommandAdapter` 的 `legacyVditor` 路由 case 保留
   (测试仍覆盖其"adapter 不写"语义),T21 后可裁剪。
