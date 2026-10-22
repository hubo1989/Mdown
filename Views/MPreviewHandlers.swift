import Cocoa
import WebKit

class HandlerTOCTip: NSObject, WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        UserDefaultsManagement.hasShownTOCTip = true
    }
}
/// T14（NE-28 / AC-14）：preview checkbox 点击的唯一入口。只解析有限
/// payload 并转发给原生校验；不再按全局 Note + DOM 序号直写。
class HandlerCheckbox: NSObject, WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let previewView = message.webView as? MPreviewView else { return }
        let isMainFrame = message.frameInfo.isMainFrame
        guard let payload = PreviewTaskIntent.parsePayload(message.body) else { return }
        Task { @MainActor in
            PreviewTaskIntentRouter.apply(
                payload, previewView: previewView, isMainFrame: isMainFrame)
        }
    }
}

/// 从会话状态构建 intent 上下文并应用；拒绝时提示并刷新 preview 以回滚
/// JS 侧的乐观翻转。
@MainActor
enum PreviewTaskIntentRouter {

    private static let readonlyHint = "Task checkboxes need an active editor for this note."

    static func apply(
        _ payload: PreviewTaskIntentPayload, previewView: MPreviewView, isMainFrame: Bool
    ) {
        guard let displayedNote = previewView.displayedNote else { return }
        guard
            let vc = previewView.window?.contentViewController as? ViewController
                ?? AppContext.shared.viewController
        else {
            previewView.updateContent(note: displayedNote, preserveScroll: true)
            return
        }

        // presentation / PPT 的 checkbox 只是展示；渲染代不匹配 = 过期预览。
        let interactiveAllowed = !vc.sessionPresentationMode && !vc.sessionMagicPPTMode

        var surface: PreviewTaskIntentApplier.Context.Surface?
        if vc.sessionLayoutMode == .wysiwyg,
            let host = vc.activeWysiwygBackend as? NativeRichEditorHostView
        {
            surface = .rich(host)
        } else if vc.editArea.storageNote === displayedNote,
            vc.editArea.editingSession?.storageIsStale == false
        {
            surface = .sourceEditor(vc.editArea, displayedNote)
        }

        let context = PreviewTaskIntentApplier.Context(
            surface: surface,
            displayedNote: displayedNote,
            currentRenderGeneration: previewView.renderGeneration,
            interactivePreviewAllowed: interactiveAllowed,
            isMainFrame: isMainFrame
        )

        let rejection = PreviewTaskIntentApplier.apply(payload, in: context)
        if let rejection {
            AppDelegate.trackError(
                PreviewTaskIntentError(rejection),
                context: "PreviewTaskIntentRouter.rejected.\(rejection)")
            if rejection != .modeForbidden {
                vc.toast(message: I18n.str(readonlyHint), style: .info)
            }
        }
        // 成功时同步 checkbox 视觉与真实内容；拒绝时刷新回滚 JS 乐观翻转。
        previewView.updateContent(note: displayedNote, preserveScroll: true)
    }
}

/// 拒绝原因的可诊断错误包装（进 diagnostics.log 的 context 链）。
struct PreviewTaskIntentError: Error {
    let rejection: PreviewTaskIntentRejection
    var localizedDescription: String { "preview task intent rejected: \(rejection)" }
    init(_ rejection: PreviewTaskIntentRejection) { self.rejection = rejection }
}

class HandlerCodeCopy: NSObject, WKScriptMessageHandler {
    public static var selectionString: String? {
        didSet {
            guard let copyBlock = selectionString else {
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyBlock, forType: .string)
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let message = (message.body as! String).trimmingCharacters(in: .whitespacesAndNewlines)
        HandlerCodeCopy.selectionString = message
    }
}

class HandlerSelection: NSObject, WKScriptMessageHandler {
    public static var selectionString: String?
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let message = (message.body as! String).trimmingCharacters(in: .whitespacesAndNewlines)
        HandlerSelection.selectionString = message
    }
}
// Used to solve the adaptation of the left border/title color change with background color in PPT mode.

class HandlerRevealBackgroundColor: NSObject, WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let vc = AppContext.shared.viewController else { return }
        let message = (message.body as! String).trimmingCharacters(in: .whitespacesAndNewlines)
        if message == "" {
            vc.titleLabel.backgroundColor = Theme.backgroundColor
        } else {
            vc.sidebarSplitView.setValue(NSColor(css: message), forKey: "dividerColor")
            vc.splitView.setValue(NSColor(css: message), forKey: "dividerColor")
        }
    }
}

class HandlerPreviewScroll: NSObject, WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let previewView = message.webView as? MPreviewView else {
            return
        }

        guard let dict = message.body as? [String: Any],
            let lineNum = (dict["line"] as? NSNumber)?.doubleValue
        else { return }
        Task { @MainActor in
            previewView.scrollDelegate?.previewDidScroll(line: CGFloat(lineNum))
        }
    }
}

class HandlerDiagramContextMenu: NSObject, WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let previewView = message.webView as? MPreviewView else { return }

        guard let dict = message.body as? [String: Any],
            let blockId = dict["blockId"] as? String,
            let kindRaw = dict["kind"] as? String,
            let kind = RenderedBlockKind(rawValue: kindRaw)
        else {
            Task { @MainActor in
                previewView.activeDiagramPreflight = nil
            }
            return
        }

        let revision = (dict["revision"] as? NSNumber)?.intValue ?? 1
        let width = (dict["naturalWidth"] as? NSNumber)?.doubleValue ?? 0
        let height = (dict["naturalHeight"] as? NSNumber)?.doubleValue ?? 0
        let isReady = (dict["isReady"] as? Bool) ?? true

        let noteId = previewView.displayedNote?.name ?? "unknown"
        let identity = RenderedBlockIdentity(
            noteId: noteId,
            previewGeneration: 1,
            blockId: blockId,
            renderRevision: revision
        )

        let preflight = RenderedBlockPreflight(
            identity: identity,
            kind: kind,
            isReady: isReady,
            naturalWidth: CGFloat(width),
            naturalHeight: CGFloat(height),
            supportsSvg: kind == .mermaid
        )

        Task { @MainActor in
            previewView.activeDiagramPreflight = preflight
        }
    }
}
