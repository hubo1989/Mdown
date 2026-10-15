# T02 — source patch 与 Unicode 不变量原型

日期：2026-10-14。新增（均已注册 pbxproj 四处并编译进 target）：

- `Business/MarkdownEditTransaction.swift`：SPEC §5.2 值类型合同（`EditingIdentity` / `MarkdownSelection` / `SourcePatch` / `EditTransaction` / `EditingSnapshot` / `EditRejection` / `EditApplyResult`；`EditRejection` 附加 `Error` 一致性以满足 `Result` 约束，字段未变）+ `MarkdownPatchApplier` 纯函数应用器。
- `Helpers/MarkdownSourceMap.swift`：UTF-16 ↔ UTF-8 字节 ↔ grapheme 边界转换。

## 语义决定（实现即合同）

1. **原子性**：`applyPatches` 逐项校验（越界 → `invalidRange`；grapheme 边界 → `invalidRange`；`expectedText` 与 base 实际文本不符 → `expectedTextMismatch`；patch 间重叠 → `overlappingPatches`），任一失败整体拒绝、原文不变。通过后按 upperBound 降序应用，base 坐标不漂移。
2. **Unicode 不变量**：所有 patch 边界必须位于 grapheme cluster 边界——统一覆盖代理对、CRLF、组合附标（e+U+0301）、ZWJ emoji 序列。半代理 range、切在 `\r\n` 中间的 range 一律 `invalidRange`。
3. **重叠规范**：空 range 视为点。两个空 range 同点 → 重叠（同位置多 insert 的顺序歧义，PLAN red case）；点严格落在另一 range 开区间内 → 重叠；点在端点上 → 允许（降序应用无歧义，测试 `testInsertAtPatchBoundaryIsAllowed` 固定）。
4. **事务层**（T05 session 复用）：`apply(transaction, to: snapshot)` 按 identity（owner/URL）→ generation → revision → patch 顺序校验，拒绝类型分别为 `ownerChanged` / `generationChanged` / `staleRevision`；正文无变化返回 `noChange`（revision 不增、selection 更新），有变化 `accepted`（revision +1）。
5. 组件为纯值类型 + 纯函数，不读 Note/Storage/renderer。

## 测试证据（19/19 绿；oracle 为 NSString UTF-16 切分与手工字节锚点，未用被测函数互相断言）

- `MarkdownEditTransactionTests`（12）：重叠原子拒绝、expectedText 拒绝、半代理拒绝/完整 emoji 替换、同位置多 insert 拒绝、越界×3、CRLF 中间拒绝+整行合法、staleRevision、generation/ownerChanged、多 patch 降序应用（aBCdEf 手工 oracle）、未改范围 UTF-8 字节逐一致、BOM+CRLF 无操作×20 hash 不变、边界 insert 合法。
- `MarkdownSourceMapTests`（7）：UTF-16 布局假设（NSString oracle）、grapheme 边界/非边界枚举（代理对、CRLF、ZWJ 序列中 9/12/15）、UTF8 偏移字节 oracle、UTF16↔UTF8 往返、byteRange、非边界 nil、组合附标单 grapheme。

全套回归：212 tests，8 failures 均为 BASELINE §1.1 既有环境性 WKWebView 失败；swiftlint --strict 0 violations。

## 压力样本回填

`stress_specs` 的确定性生成器尚未实现（T03/T04 用到 parse/性能时首次固化并回填 manifest 的 sha256 与行数）。
