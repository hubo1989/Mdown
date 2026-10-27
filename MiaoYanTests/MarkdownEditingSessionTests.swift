import XCTest
@testable import MiaoYan

/// T05: 正式 MarkdownEditingSession 的事务、身份与防护语义。
/// oracle 按 PLAN §5 规格；期望值独立推导，不用被测函数互相断言。
@MainActor
final class MarkdownEditingSessionTests: XCTestCase {

    private func makeIdentity(
        generation: UInt64 = 1, url: URL = URL(fileURLWithPath: "/tmp/session.md")
    ) -> EditingIdentity {
        EditingIdentity(ownerToken: UUID(), canonicalURL: url, generation: generation)
    }

    private func makeSession(
        identity: EditingIdentity? = nil, markdown: String = "AB", isReadOnly: Bool = false
    ) -> MarkdownEditingSession {
        MarkdownEditingSession(
            identity: identity ?? makeIdentity(),
            markdown: markdown,
            selection: MarkdownSelection(anchorUTF16: 1, focusUTF16: 1, affinity: .downstream),
            isReadOnly: isReadOnly
        )
    }

    private func makeTransaction(
        identity: EditingIdentity, revision: UInt64 = 0, origin: EditOrigin = .typing,
        patches: [SourcePatch]
    ) -> EditTransaction {
        let sel = MarkdownSelection(anchorUTF16: 1, focusUTF16: 1, affinity: .downstream)
        return EditTransaction(
            identity: identity, expectedRevision: revision, patches: patches,
            selectionBefore: sel, selectionAfter: sel, origin: origin, undoGroupID: UUID()
        )
    }

    // MARK: - PLAN §5 规格 oracle

    func testOldRevisionDoesNotOverwriteNewText() {
        let identity = makeIdentity()
        let before = MarkdownSelection(anchorUTF16: 1, focusUTF16: 1, affinity: .downstream)
        let session = MarkdownEditingSession(
            identity: identity, markdown: "AB", selection: before, isReadOnly: false
        )
        let transaction = EditTransaction(
            identity: identity, expectedRevision: 0,
            patches: [SourcePatch(rangeUTF16: NSRange(location: 1, length: 1), expectedText: "B", replacement: "C")],
            selectionBefore: before, selectionAfter: before,
            origin: .typing, undoGroupID: UUID()
        )
        guard case .accepted(let accepted) = session.apply(transaction) else {
            return XCTFail("当前revision的有效编辑必须成功")
        }
        XCTAssertEqual(accepted.markdown, "AC")
        let stale = EditTransaction(
            identity: identity, expectedRevision: 0,
            patches: [SourcePatch(rangeUTF16: NSRange(location: 0, length: 2), expectedText: "AB", replacement: "旧格式化结果")],
            selectionBefore: before, selectionAfter: before,
            origin: .format, undoGroupID: UUID()
        )
        guard case .rejected(.staleRevision) = session.apply(stale) else {
            return XCTFail("旧formatter结果必须拒绝")
        }
        XCTAssertEqual(session.snapshot.markdown, "AC")
        XCTAssertEqual(session.snapshot.revision, accepted.revision)
    }

    func testRejectsOverlappingPatchesAtomically() {
        let identity = makeIdentity()
        let session = makeSession(identity: identity, markdown: "ABCDE")
        let result = session.apply(
            makeTransaction(
                identity: identity,
                patches: [
                    SourcePatch(rangeUTF16: NSRange(location: 1, length: 2), expectedText: "BC", replacement: "X"),
                    SourcePatch(rangeUTF16: NSRange(location: 2, length: 2), expectedText: "CD", replacement: "Y"),
                ]))
        guard case .rejected(.overlappingPatches) = result else {
            return XCTFail("交叠 patch 必须整体拒绝，实际：\(result)")
        }
        XCTAssertEqual(session.snapshot.markdown, "ABCDE", "source 不变")
        XCTAssertEqual(session.snapshot.revision, 0, "rejected 不推进 revision")
        XCTAssertEqual(session.snapshot.selection.anchorUTF16, 1, "selection 不变")
    }

    func testRejectsExpectedTextMismatch() {
        let identity = makeIdentity()
        let session = makeSession(identity: identity, markdown: "ABCDE")
        let result = session.apply(
            makeTransaction(
                identity: identity,
                patches: [
                    SourcePatch(rangeUTF16: NSRange(location: 0, length: 2), expectedText: "错误基线", replacement: "X")
                ]))
        guard case .rejected(.expectedTextMismatch) = result else {
            return XCTFail("expectedText 不符必须拒绝，实际：\(result)")
        }
        XCTAssertEqual(session.snapshot.markdown, "ABCDE")
    }

    func testUTF16RangeDoesNotSplitEmoji() {
        let identity = makeIdentity()
        let session = makeSession(identity: identity, markdown: "A🙂B")
        let half = session.apply(
            makeTransaction(
                identity: identity,
                patches: [
                    SourcePatch(rangeUTF16: NSRange(location: 1, length: 1), expectedText: "x", replacement: "?")
                ]))
        guard case .rejected(.invalidRange) = half else {
            return XCTFail("半代理 range 必须拒绝，实际：\(half)")
        }
        guard
            case .accepted(let accepted) = session.apply(
                makeTransaction(
                    identity: identity,
                    patches: [
                        SourcePatch(rangeUTF16: NSRange(location: 1, length: 2), expectedText: "🙂", replacement: "😀")
                    ]))
        else {
            return XCTFail("完整 emoji range 必须成功")
        }
        XCTAssertEqual(accepted.markdown, "A😀B")
    }

    func testNoOperationPreservesCRLFAndBOM() {
        let source = "\u{FEFF}front\r\nline2\r\n"
        let identity = makeIdentity()
        let session = makeSession(identity: identity, markdown: source)
        let sel = MarkdownSelection(anchorUTF16: 0, focusUTF16: 0, affinity: .downstream)
        for _ in 0..<20 {
            let noOp = EditTransaction(
                identity: identity, expectedRevision: session.revision,
                patches: [SourcePatch(rangeUTF16: NSRange(location: 1, length: 5), expectedText: "front", replacement: "front")],
                selectionBefore: sel, selectionAfter: sel,
                origin: .typing, undoGroupID: UUID()
            )
            guard case .noChange = session.apply(noOp) else {
                return XCTFail("无操作必须 noChange，不推进 revision")
            }
        }
        XCTAssertEqual(session.snapshot.markdown, source, "CRLF 与 BOM 原样保留")
        XCTAssertEqual(session.revision, 0)
        XCTAssertEqual(
            NativeFixtureLoader.sha256(Data(session.snapshot.markdown.utf8)),
            NativeFixtureLoader.sha256(Data(source.utf8)),
            "20 次 no-op 前后字节 hash 相等")
    }

    // MARK: - 只读与身份

    func testReadOnlyRejectsEdits() {
        let identity = makeIdentity()
        let session = makeSession(identity: identity, markdown: "AB", isReadOnly: true)
        let result = session.apply(
            makeTransaction(
                identity: identity,
                patches: [SourcePatch(rangeUTF16: NSRange(location: 0, length: 1), expectedText: "A", replacement: "X")]))
        guard case .rejected(.readOnly) = result else {
            return XCTFail("只读会话必须拒绝编辑，实际：\(result)")
        }
        XCTAssertEqual(session.snapshot.markdown, "AB")
    }

    func testOwnerMismatchIsRejected() {
        let identity = makeIdentity()
        let session = makeSession(identity: identity, markdown: "AB")
        let otherOwner = EditTransaction(
            identity: makeIdentity(),  // 不同 ownerToken + URL
            expectedRevision: 0,
            patches: [SourcePatch(rangeUTF16: NSRange(location: 0, length: 2), expectedText: "AB", replacement: "串写")],
            selectionBefore: session.selection, selectionAfter: session.selection,
            origin: .externalReload, undoGroupID: UUID()
        )
        guard case .rejected(.ownerChanged) = session.apply(otherOwner) else {
            return XCTFail("跨 owner 事务必须拒绝")
        }
    }

    // MARK: - 代际（rebind / replaceAll / rename / retire）

    func testReplaceAllRaisesGenerationAndInvalidatesOldTransactions() {
        let identity = makeIdentity()
        let session = makeSession(identity: identity, markdown: "v1")
        let contextBefore = session.currentJobContext
        XCTAssertTrue(session.replaceAll(markdown: "v2"), "活动会话的显式替换必须成功")

        XCTAssertEqual(session.snapshot.markdown, "v2")
        XCTAssertEqual(session.snapshot.revision, 0, "新基线 revision 归零")
        XCTAssertTrue(session.storageIsStale, "旧 buffer 未重新 publish 前落后于会话")

        let staleTransaction = makeTransaction(
            identity: identity,  // 旧 generation
            patches: [SourcePatch(rangeUTF16: NSRange(location: 0, length: 2), expectedText: "v1", replacement: "X")])
        guard case .rejected(.generationChanged) = session.apply(staleTransaction) else {
            return XCTFail("旧 generation 事务在替换后必须拒绝")
        }
        XCTAssertFalse(session.accepts(resultFor: contextBefore), "旧任务身份失效")
        XCTAssertTrue(session.accepts(resultFor: session.currentJobContext), "新身份接受")
    }

    func testRebindRequiresSameURLAndResetsBaseline() {
        let url = URL(fileURLWithPath: "/tmp/rebind.md")
        let session = makeSession(identity: makeIdentity(url: url), markdown: "旧实例内容")

        let differentURL = URL(fileURLWithPath: "/tmp/other.md")
        XCTAssertFalse(session.rebind(url: differentURL, markdown: "x"), "URL 不同不得 rebind")

        XCTAssertTrue(session.rebind(url: url, markdown: "新实例内容"), "同 URL 新实例回流复用会话")
        XCTAssertEqual(session.snapshot.markdown, "新实例内容")
        XCTAssertEqual(session.revision, 0)
        XCTAssertTrue(session.accepts(resultFor: session.currentJobContext))
    }

    func testRenameInvalidatesOldIdentity() {
        let url = URL(fileURLWithPath: "/tmp/before-rename.md")
        let identity = makeIdentity(url: url)
        let session = makeSession(identity: identity, markdown: "AB")
        let contextBefore = session.currentJobContext

        session.rename(to: URL(fileURLWithPath: "/tmp/after-rename.md"))

        XCTAssertFalse(session.accepts(resultFor: contextBefore), "rename 后旧任务身份失效")
        let oldIdentityTransaction = makeTransaction(
            identity: identity,
            patches: [SourcePatch(rangeUTF16: NSRange(location: 0, length: 2), expectedText: "AB", replacement: "X")])
        guard case .rejected(.ownerChanged) = session.apply(oldIdentityTransaction) else {
            return XCTFail("旧 URL 身份的事务在 rename 后必须拒绝")
        }
    }

    func testRetireRejectsEverything() {
        let identity = makeIdentity()
        let session = makeSession(identity: identity, markdown: "AB")
        let contextBefore = session.currentJobContext

        session.retire()

        let result = session.apply(
            makeTransaction(
                identity: session.identity,  // 即便是当前身份
                patches: [SourcePatch(rangeUTF16: NSRange(location: 0, length: 1), expectedText: "A", replacement: "X")]))
        guard case .rejected(.retired) = result else {
            return XCTFail("退役会话必须拒绝一切编辑，实际：\(result)")
        }
        XCTAssertFalse(session.accepts(resultFor: contextBefore))
        XCTAssertFalse(session.accepts(resultFor: session.currentJobContext), "退役后任何任务结果都拒绝")
        XCTAssertFalse(session.rebind(url: identity.canonicalURL, markdown: "x"))
        XCTAssertFalse(session.replaceAll(markdown: "x"), "退役会话不得再被重置复活")
        XCTAssertEqual(session.snapshot.markdown, "AB", "退役不改动内容")
    }

    // MARK: - 任务身份 latest-wins（AC-04 的 session 侧）

    func testJobContextRejectsStaleRevisionResults() {
        let identity = makeIdentity()
        let session = makeSession(identity: identity, markdown: "AB")

        guard
            case .accepted(let first) = session.apply(
                makeTransaction(
                    identity: identity,
                    patches: [SourcePatch(rangeUTF16: NSRange(location: 1, length: 1), expectedText: "B", replacement: "C")]))
        else {
            return XCTFail("编辑必须成功")
        }
        let rev1Context = MarkdownEditingSession.JobContext(
            ownerToken: identity.ownerToken, canonicalURL: identity.canonicalURL,
            generation: identity.generation, revision: first.revision
        )

        guard
            case .accepted = session.apply(
                makeTransaction(
                    identity: identity, revision: first.revision,
                    patches: [SourcePatch(rangeUTF16: NSRange(location: 0, length: 1), expectedText: "A", replacement: "Z")]))
        else {
            return XCTFail("后续编辑必须成功")
        }

        XCTAssertFalse(
            session.accepts(resultFor: rev1Context),
            "rev1 的迟到 parse/attachment 结果在 rev2 之后必须拒绝（latest-wins）")
        XCTAssertTrue(session.accepts(resultFor: session.currentJobContext))
        XCTAssertEqual(session.revision, 2)
    }

    // MARK: - buffer revision 防护

    func testStaleBufferDetectionFollowsStoragePublish() {
        let identity = makeIdentity()
        let session = makeSession(identity: identity, markdown: "v1")
        session.markStoragePublished()
        XCTAssertFalse(session.storageIsStale, "刚发布的 buffer 不落后")

        session.replaceAll(markdown: "v2")
        XCTAssertTrue(session.storageIsStale, "会话推进后旧 buffer 落后")

        session.markStoragePublished()
        XCTAssertFalse(session.storageIsStale, "重新发布的 buffer 对齐会话")
    }
}
