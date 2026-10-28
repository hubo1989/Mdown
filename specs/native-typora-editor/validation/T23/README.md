# T23 验证记录 — 文档收口与 P-Gate 状态(partial)— 2026-10-22

前序 `70b7c7f`(T22)。T23 的官方 Typora 对照(AC-21)依赖官方样本,
T00 已记录其不可得("Antibiotics 副本仅静态定位,未建立官方身份")——
AC-21 不能计 pass,不冒充。

## 已交付(文档)

- `DEPENDENCIES.md`:表内移除 Highlightr/Prettier(CI 与 Package.swift
  对账需要),增补 T22 退依赖与 renderer JS 保留披露(指向
  `Resources/DownView.bundle/js/vendor/MANIFEST.json`)。
- `README.md` / `README_CN.md`:鸣谢段移除 Prettier/Highlightr。
- `ARCHITECTURE.md`:编辑管线段更新为原生高亮/格式化与 native-only
  wysiwyg 后端。
- `AGENTS.md`(CLAUDE.md 同源):Current Risk Areas 增补两条必要规则——
  native wysiwyg 面的 #543 owner 规则双面适用、原生高亮/格式化的
  protected 区与 IME marked-text 不动属性。

## P-Gate 状态(NE → 任务 → 证据)

| 门 | 状态 | 证据 |
|---|---|---|
| N1(可选原生基础,T14) | pass | validation/T14 + 全量回归 |
| N2 源码/工程/产物级退依赖(T22) | pass | validation/T22(包图/产物三查) |
| T21 行为/压力/Sandbox 矩阵 | **partial** | 单元/集成全绿(577/8 已知环境项);signed Sandbox、真机 IME、1/10MiB 压力、trace/内存需维护者执行 |
| AC-21 官方 Typora 对照 | **blocked** | 官方样本不可得(T00),不计 pass |
| T20 导出运行验证 | **partial** | 逻辑层(T17 快照/缓存)有测;Mermaid/KaTeX 运行用例受本机 WebKit 环境限制(基线已证) |

## 2026-10-23 实测补录

### signed Sandbox 矩阵(T21 完整门第 1 项)

真实签名 sandbox 副本:`com.mdown.t23.smoke`
(`Apple Development: bo hu (4B8FUZVCHN)`,Team 27LU47J28S,
entitlements `app-sandbox` + `user-selected.read-write`)。

| 场景 | 结果 | 证据 |
|---|---|---|
| Sandbox 隔离生效 | **pass** | 应用无法写外部 `/Volumes/external`,回退容器内 `~/Library/Containers/com.mdown.t23.smoke/Data/Documents/MiaoYan/` 并生成示例文档 |
| 保存(Cmd+S) | **pass** | `欢迎使用.md` 哈希 `bd965c…`→`f62c86…`,字节 216→236," sandbox保存测试"落盘 |
| 覆盖保存 | **pass** | 二次编辑"覆盖2"后哈希 `f62c86…`→`c055da…`,字节 236→244 |
| 取消(编辑后切走) | **既有行为** | "取消测试"字节 244→257 已落盘——切笔记自动保存 outgoing(T01/T13 既有语义),非独立"取消"入口;真正的取消需关窗不保存流 |
| 保存失败提示 | **pass** | `/tmp` 下 smoke 保存遇权限拒绝时弹"保存失败"对话框,不静默失败(此前 T19 smoke 实测) |

未完:security-scoped bookmark 授权失效矩阵(外部目录授权→撤销→重试)
需维护者在 NSOpenPanel 授权流中实操,本会话未覆盖。

### AC-21 官方 Typora 对照(阻塞解除)

**官方样本已确认**:`Typora.dmg` 内为
`Developer ID Application: Abner Lee (9HWK5273G4)`,公证通过,
`spctl -a` accepted,Team 9HWK5273G4。T00 记录的"官方样本不可得"
阻塞解除(此前 `/Applications/Typora.app` 是 Antibiotics 签名非官方)。

同一语料(`T19-visual.md`)在官方 Typora 与 MiaoYan WYSIWYG 对照:

| 项 | Typora 官方 | MiaoYan WYSIWYG | 判定 |
|---|---|---|---|
| 有序列表序号 | 1./2./1嵌套/3. 正确 | "1."脱离、序号错行错值 | **MiaoYan 缺陷** |
| 表格 | 网格渲染、单元格可编辑 | 管道符原文 | 缺口 |
| 数学 | KaTeX 渲染 E=mc² | `$$` 原文 | 缺口 |
| Mermaid | 节点图渲染 | fence 原文 | 缺口 |
| H1-H3/粗斜删/链接/引用/列表 | 正确 | 正确 | **对齐** |
| 长代码 token 高亮 | 有 | 有 | **对齐** |
| 表格 AX 语义 | row/cell 可编辑 input | 管道原文 | 缺口 |

结论:普通排版已对齐;特殊块(表格/数学/mermaid)WYSIWYG 显示原文
与官方 Typora 的渲染态有实质差距——这正是 `specs/wysiwyg-display-parity`
PRD 要消除的缺口。有序列表 marker 错位是独立缺陷,需先修复。

### 仍未完成(不冒充)

1. 真机 IME composition 矩阵:CUA 合成按键(`typeText`/`pressKey`)不走
   输入法管线,拼音以字母落盘,**无法自动化触发 marked text**;需真实
   用户手敲。T13 的中文 IME smoke 是维护者人工输入,本会话未能复现。
2. VoiceOver 语音实测(AC-17):AX 树已采(标题/列表/表格/数学/mermaid
   语义均在),但 VoiceOver 实际朗读需人工听验。
3. security-scoped bookmark 授权失效矩阵(见上)。
4. p95 trace/内存、1/10MiB 压力、旧系统标注。

## P-Gate 状态更新(2026-10-23)

| 门 | 状态 | 变化 |
|---|---|---|
| T21 行为/压力/Sandbox | **partial→多数通过** | Sandbox 隔离/保存/覆盖/失败提示已实测通过;授权失效/IME/trace 未完 |
| AC-21 官方对照 | **blocked→已建立对照** | 官方样本确认,逐项差异已登记;未宣称全 parity |

## 无 owner/IME/丢文档阻断

- owner:#543 规则双面(native rich + source)有测试(NativeWysiwyg/
  EditorStorageOwnership)。
- IME:AppKit 输入协议测试 + T13 实机中文 IME smoke;marked-text 不动
  属性在 rich 面以 rebuildProjection 早退实现,有断言。
- 丢文档:T07/T08/T09 保存/转场/冲突链全绿;T22 硬保存点用例移植保留。

## 发布边界(不冒充)

本计划到 reviewable 通过结果为止;未授权不 tag/送审。发布时直接下载
与 App Store 分别报告。剩余未完成项按 PLAN 标 partial/blocked,不
宣称 "全部任务完成"。
