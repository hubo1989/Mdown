import XCTest

@testable import MiaoYan

/// T17 (SPEC NE-11 / NE-12 / NE-28 / NE-29 / AC-13 / AC-18):
/// MarkdownBlockRenderAdapter 的状态与缓存合同。
///
/// 固定:请求携带不可变 source 快照 + 身份/revision/主题代;结果只在
/// 身份全等时接受(latest-wins);同 fingerprint 的 ready artifact 直接
/// 复用;错误/取消不产生 artifact;缓存只按 fingerprint 驱逐,不清
/// 共享状态。
final class MarkdownRenderedBlockStateTests: XCTestCase {

    private func makeRequest(
        revision: UInt64, themeGeneration: UInt64 = 1,
        source: String = "graph TD\nA-->B\n"
    ) -> MarkdownBlockRenderRequest {
        MarkdownBlockRenderRequest(
            blockID: "b1",
            noteID: "note.md",
            revision: revision,
            themeGeneration: themeGeneration,
            kind: .mermaid,
            source: source
        )
    }

    func testFingerprintIsStableForSameSourceAndConfig() {
        let a = makeRequest(revision: 1)
        let b = makeRequest(revision: 99)  // revision 不入指纹(内容相同即可复用)
        XCTAssertEqual(a.fingerprint, b.fingerprint)

        let c = makeRequest(revision: 1, themeGeneration: 2)
        XCTAssertNotEqual(a.fingerprint, c.fingerprint, "主题代变化必须换指纹")

        let d = makeRequest(revision: 1, source: "graph TD\nA-->C\n")
        XCTAssertNotEqual(a.fingerprint, d.fingerprint)
    }

    func testCacheReusesReadyArtifactByFingerprint() {
        let cache = MarkdownBlockRenderCache(capacity: 4)
        let artifact = MarkdownBlockArtifact(
            payload: .svg("svg-bytes"), naturalSize: NSSize(width: 100, height: 50))
        cache.store(artifact, for: makeRequest(revision: 1))

        let hit = cache.artifact(for: makeRequest(revision: 200))
        XCTAssertEqual(hit?.payload, .svg("svg-bytes"), "同内容不同 revision 应命中")
        XCTAssertNil(cache.artifact(for: makeRequest(revision: 1, themeGeneration: 9)))
    }

    func testCacheEvictsByCapacityKeepingFingerprintsDistinct() {
        let cache = MarkdownBlockRenderCache(capacity: 2)
        let art = MarkdownBlockArtifact(payload: .html("<p>x</p>"), naturalSize: .zero)
        cache.store(art, for: makeRequest(revision: 1, source: "a"))
        cache.store(art, for: makeRequest(revision: 1, source: "b"))
        cache.store(art, for: makeRequest(revision: 1, source: "c"))
        XCTAssertNil(cache.artifact(for: makeRequest(revision: 1, source: "a")), "超容先逐")
        XCTAssertNotNil(cache.artifact(for: makeRequest(revision: 1, source: "b")))
        XCTAssertNotNil(cache.artifact(for: makeRequest(revision: 1, source: "c")))
    }

    @MainActor
    func testLatestWinsRejectsStaleRevision() {
        let coordinator = MarkdownBlockRenderCoordinator()
        let ctx1 = coordinator.captureContext(for: makeRequest(revision: 1))
        _ = coordinator.captureContext(for: makeRequest(revision: 2))  // 更新

        let result = MarkdownBlockRenderResult.ready(
            ctx1, MarkdownBlockArtifact(payload: .svg("late"), naturalSize: .zero))
        XCTAssertFalse(
            coordinator.accepts(result), "旧 revision 的迟到结果必须拒绝")
    }

    @MainActor
    func testGenerationChangeRejectesEvenSameRevision() {
        let coordinator = MarkdownBlockRenderCoordinator()
        let ctx = coordinator.captureContext(for: makeRequest(revision: 5))
        // 主题重载:同 revision、新主题代
        _ = coordinator.captureContext(
            for: makeRequest(revision: 5, themeGeneration: 2))

        let result = MarkdownBlockRenderResult.ready(
            ctx, MarkdownBlockArtifact(payload: .svg("stale-theme"), naturalSize: .zero))
        XCTAssertFalse(coordinator.accepts(result), "主题代变化后旧结果拒绝")
    }

    @MainActor
    func testCurrentContextResultIsAccepted() {
        let coordinator = MarkdownBlockRenderCoordinator()
        let ctx = coordinator.captureContext(for: makeRequest(revision: 3))
        let artifact = MarkdownBlockArtifact(payload: .svg("ok"), naturalSize: .zero)
        XCTAssertTrue(coordinator.accepts(.ready(ctx, artifact)))
    }

    @MainActor
    func testCancelledAndErrorProduceNoArtifactAndDoNotPoisonCache() {
        let cache = MarkdownBlockRenderCache(capacity: 2)
        let coordinator = MarkdownBlockRenderCoordinator()
        let ctx = coordinator.captureContext(for: makeRequest(revision: 1))

        // 错误/取消/超时:身份仍新鲜(accepts 不负责成败),但不产生
        // artifact、不落缓存,也不影响后续同指纹 ready
        _ = coordinator.accepts(.failed(ctx, reason: "syntax"))
        _ = coordinator.accepts(.cancelled(ctx))
        _ = coordinator.accepts(.timedOut(ctx))
        XCTAssertNil(cache.artifact(for: makeRequest(revision: 1)))

        XCTAssertTrue(coordinator.accepts(.ready(ctx, MarkdownBlockArtifact(payload: .svg("v"), naturalSize: .zero))))
    }
}
