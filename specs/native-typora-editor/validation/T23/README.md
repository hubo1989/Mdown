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
