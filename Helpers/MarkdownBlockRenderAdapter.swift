import Foundation

// MARK: - T17 渲染块快照与状态(PLAN T17 / SPEC §9 / NE-28 / AC-13 / AC-18)
//
// 渲染请求携带不可变 source 快照 + 身份/revision/主题代;结果只在身份
// 全等时接受(latest-wins,旧 revision / 主题代变化一律拒);同
// fingerprint(内容 + kind + 主题代,不含 revision)的 ready artifact
// 直接复用——同内容重渲染不重复占宿主。错误/超时/取消不产生 artifact,
// 也不污染缓存。缓存按容量逐出最旧指纹,只动自己的条目。
//
// 隔离渲染宿主(单块静态 SVG/HTML 生成)接既有 RenderedBlockExport
// 管线,由后续阶段接入;本文件只承载可独立验证的状态/缓存语义。

import AppKit

/// 待渲染的特殊块种类(与既有 RenderedBlockKind 对齐的子集)。
enum MarkdownBlockRenderKind: String, Equatable {
    case mermaid
    case plantuml
    case math
    case html
}

/// 渲染产物(静态,不含可执行桥)。
enum MarkdownBlockArtifactPayload: Equatable {
    case svg(String)
    case html(String)
}

struct MarkdownBlockArtifact: Equatable {
    let payload: MarkdownBlockArtifactPayload
    /// 渲染产物自然尺寸(布局/导出用;无意义时 .zero)。
    let naturalSize: NSSize

    static func == (lhs: MarkdownBlockArtifact, rhs: MarkdownBlockArtifact) -> Bool {
        lhs.payload == rhs.payload
            && lhs.naturalSize.width == rhs.naturalSize.width
            && lhs.naturalSize.height == rhs.naturalSize.height
    }
}

/// 一次渲染请求:全部值语义,捕获后不可变(SPEC:job 固定 source
/// snapshot 与配置,不跟随编辑器当前态)。
struct MarkdownBlockRenderRequest: Equatable {
    let blockID: String
    let noteID: String
    let revision: UInt64
    let themeGeneration: UInt64
    let kind: MarkdownBlockRenderKind
    let source: String
    /// 渲染时的明暗主题(mermaid 页面按它注入 darkmode class,
    /// theme-manager.isDarkMode 据此配色)。默认 false 保持既有
    /// 调用方语义不变。
    var isDarkTheme: Bool = false

    /// 内容指纹:kind + source + 主题代(刻意不含 revision——同内容
    /// 的新 revision 应命中缓存;主题/内容任一变化即失效)。明暗不
    /// 入指纹:host 实例每次新建、缓存不跨请求复用,视图层缓存的
    /// 失效由主题切换时的 invalidateRenderedBlockImages 承担。
    var fingerprint: String {
        var hasher = Hasher()
        hasher.combine(kind.rawValue)
        hasher.combine(source)
        hasher.combine(themeGeneration)
        return "\(hasher.finalize())"
    }
}

/// latest-wins 的任务上下文(请求发起时捕获,完成时回核对)。
struct MarkdownBlockRenderContext: Equatable {
    let request: MarkdownBlockRenderRequest
}

enum MarkdownBlockRenderResult: Equatable {
    case ready(MarkdownBlockRenderContext, MarkdownBlockArtifact)
    case failed(MarkdownBlockRenderContext, reason: String)
    case timedOut(MarkdownBlockRenderContext)
    case cancelled(MarkdownBlockRenderContext)

    var context: MarkdownBlockRenderContext {
        switch self {
        case .ready(let ctx, _), .failed(let ctx, _),
            .timedOut(let ctx), .cancelled(let ctx):
            return ctx
        }
    }
}

/// 单块渲染的 latest-wins 协调器:每次 capture 记录当前权威请求,
/// 结果的上下文与之全等才接受(revision 或主题代落后即拒)。
@MainActor
final class MarkdownBlockRenderCoordinator {

    private var current: MarkdownBlockRenderRequest?

    func captureContext(for request: MarkdownBlockRenderRequest) -> MarkdownBlockRenderContext {
        current = request
        return MarkdownBlockRenderContext(request: request)
    }

    func accepts(_ result: MarkdownBlockRenderResult) -> Bool {
        result.context.request == current
    }
}

/// 按 fingerprint 的有界 ready-artifact 缓存;只逐出自己条目。
final class MarkdownBlockRenderCache {

    private let capacity: Int
    private var store: [String: MarkdownBlockArtifact] = [:]
    private var order: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func artifact(for request: MarkdownBlockRenderRequest) -> MarkdownBlockArtifact? {
        store[request.fingerprint]
    }

    func store(_ artifact: MarkdownBlockArtifact, for request: MarkdownBlockRenderRequest) {
        let key = request.fingerprint
        if store[key] == nil {
            order.append(key)
            if order.count > capacity {
                let evicted = order.removeFirst()
                store.removeValue(forKey: evicted)
            }
        }
        store[key] = artifact
    }
}
