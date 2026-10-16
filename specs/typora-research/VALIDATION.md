# 本轮研究交付验证

日期：2026-10-14。范围：研究文档与静态证据，不是业务编辑器、UI 或运行一致性验证。

## 实际执行

```bash
python3 -I /Volumes/external/Projects/typora-r/research/scripts/verify_research_docs.py \
  /Volumes/external/Projects/Mdown \
  /Volumes/external/Projects/typora-r/research
```

结果：exit 0，failures 空数组，以下九项核验通过：

1. 所有研究 JSON 解析。
2. 本地 Markdown 文档链接可达。
3. 样例 SHA-256、UTF-8、CRLF 和末尾换行特征匹配 manifest。
4. 16 项行为用例步骤/合同完整，运行结果全部为 null。
5. BRIDGE 的 98/63/5 项字面量清单与实际匹配一致。
6. NATIVE 的原生方法/回调地址存在于索引或明确调用点。
7. 原包与 arm64 切片逐字节对应记录为真。
8. JS 关键定义的 UTF-8 byte offset 与原始文件匹配。
9. Mdown 迁移文档的源码路径和行号存在。

另行核验：native-offline/evidence-manifest.json 记录的 75 份文件摘要全部匹配，63 个聚焦函数/回调视图存在；独立原生复核覆盖快照、同步桥、多窗口、PDF/导出分流、TextBundle 与类/符号数量。研究辅助 Python 脚本语法检查通过；工具错误响应解析使用五种成功/失败样本验证。

## 工作区检查

`git diff --check` 无输出、exit 0；tracked diff 空。`git status --short --branch` 为 main...origin/main，仅 `?? specs/typora-research/`。未提交、推送、修改构建目标或业务源码；既有 WYSIWYG SPEC/PLAN 未修改。

## 未执行与阻塞

- 没有运行 xcodebuild、产品测试、Mdown 或 Typora。文档检查通过不能宣称运行 bug 修复、性能提升或体验一致。
- Vditor setValue/clearStack 合同错配已读声明和实现确认；输入桥、同 owner 旧 buffer 与 formatter revision 风险尚未运行复现或修复。
- REA open_binary 完成绑定，实际 Hopper 分析仍被 Apple Events 拒绝；没有 Hopper 函数 dossier。
- 已尝试 close_binary，返回 cleanup_incomplete；本次 CLI/内置 MCP 子进程均结束，GUI/旧私有目录关闭未确认，未清理共享状态。
- 当前副本官方发行身份未验证，Authority 为 Antibiotics；官方包的输入/视觉/性能/导出对照尚未建立。
- fixtures 中 null 的运行结果明确是待测，不能自动计为通过。

原始证据与辅助脚本仅在 typora-r/research 工作区保存，不引入 Mdown 构建；最终实现准备见 NATIVE-REPLACEMENT-PLAN 与 MDOWN-MIGRATION。
