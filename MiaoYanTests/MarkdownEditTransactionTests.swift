import CryptoKit
import XCTest
@testable import MiaoYan

/// T02: source patch 原子应用与 Unicode 不变量。所有期望值由 NSString /
/// 手工 UTF-16 坐标独立推导，不用被测函数互相断言。
final class MarkdownEditTransactionTests: XCTestCase {

    private func makeIdentity(generation: UInt64 = 1) -> EditingIdentity {
        EditingIdentity(
            ownerToken: UUID(), canonicalURL: URL(fileURLWithPath: "/tmp/t02.md"), generation: generation
        )
    }

    private func makeSnapshot(
        _ markdown: String, identity: EditingIdentity? = nil, revision: UInt64 = 0
    ) -> EditingSnapshot {
        EditingSnapshot(
            identity: identity ?? makeIdentity(), revision: revision,
            markdown: markdown, selection: MarkdownSelection(anchorUTF16: 0, focusUTF16: 0, affinity: .downstream)
        )
    }

    private func makeTransaction(
        identity: EditingIdentity, revision: UInt64 = 0,
        patches: [SourcePatch]
    ) -> EditTransaction {
        let sel = MarkdownSelection(anchorUTF16: 0, focusUTF16: 0, affinity: .downstream)
        return EditTransaction(
            identity: identity, expectedRevision: revision, patches: patches,
            selectionBefore: sel, selectionAfter: sel, origin: .typing, undoGroupID: UUID()
        )
    }

    private func apply(_ patches: [SourcePatch], to source: String) -> Result<String, EditRejection> {
        MarkdownPatchApplier.applyPatches(patches, to: source)
    }

    // MARK: 拒绝类型（PLAN red cases）

    func testRejectsOverlappingPatchesAtomically() {
        // "ABCDE"：[1,3) "BC"→"X" 与 [2,4) "CD"→"Y" 交叠
        let result = apply(
            [
                SourcePatch(rangeUTF16: NSRange(location: 1, length: 2), expectedText: "BC", replacement: "X"),
                SourcePatch(rangeUTF16: NSRange(location: 2, length: 2), expectedText: "CD", replacement: "Y"),
            ],
            to: "ABCDE"
        )
        guard case .failure(.overlappingPatches) = result else {
            return XCTFail("交叠 patch 必须整体拒绝，实际：\(result)")
        }
    }

    func testRejectsExpectedTextMismatch() {
        let result = apply(
            [SourcePatch(rangeUTF16: NSRange(location: 0, length: 2), expectedText: "错误基线", replacement: "X")],
            to: "ABCDE"
        )
        guard case .failure(.expectedTextMismatch) = result else {
            return XCTFail("expectedText 不符必须拒绝，实际：\(result)")
        }
    }

    func testUTF16RangeDoesNotSplitEmoji() {
        // "A🙂B"：🙂 占 UTF16 2 个单元（location 1..<3）
        let half = apply(
            [SourcePatch(rangeUTF16: NSRange(location: 1, length: 1), expectedText: "x", replacement: "?")],
            to: "A🙂B"
        )
        guard case .failure(.invalidRange) = half else {
            return XCTFail("半代理 range 必须拒绝，实际：\(half)")
        }

        let whole = apply(
            [SourcePatch(rangeUTF16: NSRange(location: 1, length: 2), expectedText: "🙂", replacement: "😀")],
            to: "A🙂B"
        )
        XCTAssertEqual(try whole.get(), "A😀B", "完整 grapheme range 的替换应成功")
    }

    func testRejectsSamePositionMultipleInserts() {
        let result = apply(
            [
                SourcePatch(rangeUTF16: NSRange(location: 2, length: 0), expectedText: "", replacement: "一"),
                SourcePatch(rangeUTF16: NSRange(location: 2, length: 0), expectedText: "", replacement: "二"),
            ],
            to: "AB"
        )
        guard case .failure(.overlappingPatches) = result else {
            return XCTFail("同位置多 insert 必须拒绝（顺序歧义），实际：\(result)")
        }
    }

    func testRejectsOutOfRange() {
        let cases = [
            SourcePatch(rangeUTF16: NSRange(location: 5, length: 1), expectedText: "", replacement: "X"),  // 越起点
            SourcePatch(rangeUTF16: NSRange(location: 0, length: 6), expectedText: "", replacement: "X"),  // 越终点
            SourcePatch(rangeUTF16: NSRange(location: 1, length: -1), expectedText: "", replacement: "X"),  // 负长度
        ]
        for patch in cases {
            guard case .failure(.invalidRange) = apply([patch], to: "ABCDE") else {
                return XCTFail("越界 patch 必须拒绝：\(patch)")
            }
        }
    }

    func testCRLFSplitRejected() {
        // range 边界落在 \r\n 中间（"A\r\nB"：\r=1, \n=2，边界 2 非法）
        let result = apply(
            [SourcePatch(rangeUTF16: NSRange(location: 0, length: 2), expectedText: "A\r", replacement: "X")],
            to: "A\r\nB"
        )
        guard case .failure(.invalidRange) = result else {
            return XCTFail("切在 CRLF 中间必须拒绝，实际：\(result)")
        }
        // 整行替换（含完整 CRLF）合法
        let ok = apply(
            [SourcePatch(rangeUTF16: NSRange(location: 0, length: 3), expectedText: "A\r\n", replacement: "X\n")],
            to: "A\r\nB"
        )
        XCTAssertEqual(try ok.get(), "X\nB")
    }

    // MARK: 事务层拒绝

    func testStaleRevisionRejected() {
        let identity = makeIdentity()
        var snapshot = makeSnapshot("AB", identity: identity, revision: 0)
        let tx1 = makeTransaction(
            identity: identity, revision: 0,
            patches: [
                SourcePatch(rangeUTF16: NSRange(location: 1, length: 1), expectedText: "B", replacement: "C")
            ])
        guard case .accepted(let s1) = MarkdownPatchApplier.apply(tx1, to: snapshot) else {
            return XCTFail("合法首笔事务必须接受")
        }
        XCTAssertEqual(s1.markdown, "AC")
        XCTAssertEqual(s1.revision, 1)
        snapshot = s1

        let stale = makeTransaction(
            identity: identity, revision: 0,
            patches: [
                SourcePatch(rangeUTF16: NSRange(location: 0, length: 2), expectedText: "AB", replacement: "旧格式化结果")
            ])
        guard case .rejected(.staleRevision) = MarkdownPatchApplier.apply(stale, to: snapshot) else {
            return XCTFail("旧 revision 事务必须拒绝为 staleRevision")
        }
        XCTAssertEqual(snapshot.markdown, "AC", "拒绝后 source 不变")
    }

    func testGenerationAndOwnerChangedRejected() {
        let base = makeSnapshot("AB")
        let newGen = makeTransaction(
            identity: EditingIdentity(
                ownerToken: base.identity.ownerToken, canonicalURL: base.identity.canonicalURL, generation: 2
            ),
            patches: [SourcePatch(rangeUTF16: NSRange(location: 0, length: 0), expectedText: "", replacement: "X")]
        )
        guard case .rejected(.generationChanged) = MarkdownPatchApplier.apply(newGen, to: base) else {
            return XCTFail("不同 generation 必须拒绝")
        }

        let newOwner = makeTransaction(
            identity: EditingIdentity(
                ownerToken: UUID(), canonicalURL: base.identity.canonicalURL, generation: 1
            ),
            patches: [SourcePatch(rangeUTF16: NSRange(location: 0, length: 0), expectedText: "", replacement: "X")]
        )
        guard case .rejected(.ownerChanged) = MarkdownPatchApplier.apply(newOwner, to: base) else {
            return XCTFail("不同 owner 必须拒绝")
        }
    }

    // MARK: 应用正确性（独立 oracle）

    func testDescendingApplicationMultiplePatches() {
        // base "abcdef"：[4,5)"e"→"E"、[1,3)"bc"→"BC"——同一 base 坐标，互不漂移
        let result = apply(
            [
                SourcePatch(rangeUTF16: NSRange(location: 4, length: 1), expectedText: "e", replacement: "E"),
                SourcePatch(rangeUTF16: NSRange(location: 1, length: 2), expectedText: "bc", replacement: "BC"),
            ],
            to: "abcdef"
        )
        // 手工 oracle：a + BC + d + E + f
        XCTAssertEqual(try result.get(), "aBCdEf")
    }

    func testUnchangedRangesPreserveExactBytes() {
        let source = "---\ntitle: t\n---\n\n正文 **加粗** `code`。\n\t- tab 项\r\n"
        let result = apply(
            [SourcePatch(rangeUTF16: NSRange(location: 23, length: 2), expectedText: "加粗", replacement: "斜体")],
            to: source
        )
        guard case .success(let updated) = result else { return XCTFail("合法替换必须成功") }
        // oracle：前 23 与后缀（NSString UTF16 切分）必须逐字节不变
        let ns = source as NSString
        let prefix = ns.substring(to: 23)
        let suffix = ns.substring(from: 25)
        let oracle = prefix + "斜体" + suffix
        XCTAssertEqual(updated, oracle)
        XCTAssertEqual(
            Array(updated.utf8), Array(oracle.utf8),
            "未改范围与替换结果的 UTF-8 字节必须与 NSString oracle 完全一致"
        )
    }

    func testNoOperationPreservesCRLFAndBOM() {
        let source = "\u{FEFF}---\r\ntitle: BOM 样例\r\n---\r\n\r\n- BOM 必须原样保留\r\n"
        for _ in 0..<20 {
            let result = apply(
                [SourcePatch(rangeUTF16: NSRange(location: 1, length: 0), expectedText: "", replacement: "")],
                to: source
            )
            XCTAssertEqual(try result.get(), source, "无操作 patch 不得改变任何字节")
        }
        // 事务层 noChange 同样不产生新 revision，字节 hash 不变
        let identity = makeIdentity()
        let snapshot = makeSnapshot(source, identity: identity)
        let noOp = makeTransaction(
            identity: identity,
            patches: [
                SourcePatch(rangeUTF16: NSRange(location: 0, length: 0), expectedText: "", replacement: "")
            ])
        guard case .noChange(let s) = MarkdownPatchApplier.apply(noOp, to: snapshot) else {
            return XCTFail("无效果事务必须是 noChange")
        }
        XCTAssertEqual(s.revision, snapshot.revision)
        XCTAssertEqual(
            SHA256.hash(data: Data(s.markdown.utf8)),
            SHA256.hash(data: Data(source.utf8))
        )
    }

    func testInsertAtPatchBoundaryIsAllowed() {
        // 边界端点上的 insert 与替换无顺序歧义：[1,3)"bc"→"BC" + location 3 插入 "X"
        let result = apply(
            [
                SourcePatch(rangeUTF16: NSRange(location: 3, length: 0), expectedText: "", replacement: "X"),
                SourcePatch(rangeUTF16: NSRange(location: 1, length: 2), expectedText: "bc", replacement: "BC"),
            ],
            to: "abcd"
        )
        // oracle：a + BC + X + d
        XCTAssertEqual(try result.get(), "aBCXd")
    }
}
