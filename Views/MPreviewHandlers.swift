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
class HandlerCheckbox: NSObject, WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let position = message.body as? String else { return }
        guard let note = EditTextView.note else { return }
        let content = note.content.unLoadCheckboxes().unLoadImages()
        let string = content.string
        let range = NSRange(0..<string.count)
        var i = 0
        NotesTextProcessor.allTodoInlineRegex.matches(string, range: range) { result in
            guard let range = result?.range else { return }
            if i == Int(position) {
                let substring = content.mutableString.substring(with: range)
                if substring.contains("- [x] ") {
                    content.replaceCharacters(in: range, with: "- [ ] ")
                } else {
                    content.replaceCharacters(in: range, with: "- [x] ")
                }
                note.save(content: content)
            }
            i += 1
        }
    }
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
