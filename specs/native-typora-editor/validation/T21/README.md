# T21 验证记录(阶段 1:压力预算冒烟)— 2026-10-22

前序 `5557c4a`。本记录只覆盖已落地部分;T21 完整门见文末。

## 已交付

- `MiaoYanTests/NativeEditorStressBudgetTests.swift`(4 例,单样本
  冒烟,不冒充 p95):
  - 200KiB/5700 行混合 Markdown:parse + 全块投影 66ms(SPEC §10
    首帧预算 300ms 内,余量充分);
  - 3KiB code 块 tokenize 20 次均值 ≪16ms(输入预算线);
  - 1MiB 源压力:解析完整、块区间不越界、处理前后 source 哈希
    不变(可编辑性底线);
  - 200k 字符单行 tokenize 不崩、线性时间内完成。

## 验证

| 项 | 结果 |
|---|---|
| `NativeEditorStressBudgetTests` | **4/4** |
| 全量(当时) | 577/8 = 既有 3 WebKit 环境用例(基线已证) |

## T21 完整门剩余(不冒充)

1. signed Sandbox 保存/取消/覆盖/授权失效矩阵(需维护者签名环境);
2. 真实 IME 多笔记步骤与 typing parse disorder 完整回归;
3. p95 trace/内存测量(本套件为单样本冒烟);
4. 全故障矩阵(owner/conflict/退役/写错误/失焦/quit)——单元层已有
   覆盖,运行级留维护者实机;
5. 未知设备/旧系统标注 partial。
