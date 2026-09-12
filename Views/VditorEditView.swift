import Cocoa
import WebKit

private final class VditorScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var owner: VditorEditView?

    init(_ owner: VditorEditView) {
        self.owner = owner
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handleScriptMessage(message)
    }
}

@MainActor
public final class VditorEditView: WKWebView, WKNavigationDelegate {
    public private(set) weak var currentNote: Note?
    public private(set) var hasUnsavedChanges = false
    private var pendingNote: Note?
    private var isEditorReady = false
    nonisolated(unsafe) private var saveWorkItem: DispatchWorkItem?
    private var lastLoadedMarkdown: String?

    public init() {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        configuration.userContentController = contentController
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        super.init(frame: .zero, configuration: configuration)

        let handler = VditorScriptMessageHandler(self)
        contentController.add(handler, name: "vditorReady")
        contentController.add(handler, name: "vditorChange")

        navigationDelegate = self
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setValue(false, forKey: "drawsBackground")
        alphaValue = 1.0

        configureScrollView()
        loadEditorHTML()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        saveWorkItem?.cancel()
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            flushPendingSave()
            configuration.userContentController.removeScriptMessageHandler(forName: "vditorReady")
            configuration.userContentController.removeScriptMessageHandler(forName: "vditorChange")
        }
    }

    private func configureScrollView() {
        if let scrollView = subviews.compactMap({ $0 as? NSScrollView }).first {
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
        }
    }

    private func loadEditorHTML() {
        guard let bundle = HtmlManager.getDownViewBundle(),
              let editorURL = bundle.url(forResource: "editor", withExtension: "html") else {
            AppDelegate.trackError(
                NSError(domain: "VditorEditView", code: 1, userInfo: [NSLocalizedDescriptionKey: "editor.html not found"]),
                context: "VditorEditView.loadEditorHTML"
            )
            return
        }

        // Allow access to root directory to support absolute path images and user attachments
        let accessURL = URL(fileURLWithPath: "/")
        loadFileURL(editorURL, allowingReadAccessTo: accessURL)
    }

    private func getViewController() -> ViewController? {
        if let vc = window?.contentViewController as? ViewController {
            return vc
        }
        return AppContext.shared.viewController
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let isDark = AppEnvironment.current.userData.isDark
        let targetNote = pendingNote ?? currentNote
        let initialMarkdown = (targetNote?.isContentLoaded == true) ? (targetNote?.content.string ?? "") : ""
        let jsSafeContent = serializeToJSON(initialMarkdown)

        let initScript = "initEditor(\(jsSafeContent), \(isDark));"
        evaluateJavaScript(initScript, completionHandler: nil)
    }

    fileprivate func handleScriptMessage(_ message: WKScriptMessage) {
        if message.name == "vditorReady" {
            isEditorReady = true
            if let pending = pendingNote {
                pendingNote = nil
                loadNote(pending)
            }
        } else if message.name == "vditorChange" {
            guard let body = message.body as? [String: Any],
                  let markdown = body["markdown"] as? String else {
                return
            }
            handleContentChanged(markdown)
        }
    }

    public func loadNote(_ note: Note) {
        // Only persist outgoing note if the user has actually made edits in Vditor.
        // Pure navigation/browsing across notes must never touch disk.
        if let outgoingNote = currentNote, hasUnsavedChanges {
            saveWorkItem?.cancel()
            saveWorkItem = nil
            persistNote(outgoingNote)
        } else {
            saveWorkItem?.cancel()
            saveWorkItem = nil
        }
        hasUnsavedChanges = false

        currentNote = note

        if note.isContentLoaded {
            applyNoteToEditor(note)
        } else {
            pendingNote = note
            Task { @MainActor in
                await note.ensureContentLoadedAsync()
                guard self.currentNote === note else { return }
                self.applyNoteToEditor(note)
            }
        }
    }

    private func applyNoteToEditor(_ note: Note) {
        lastLoadedMarkdown = note.content.string

        guard isEditorReady else {
            pendingNote = note
            return
        }

        pendingNote = nil
        let jsSafeContent = serializeToJSON(note.content.string)
        evaluateJavaScript("setMarkdown(\(jsSafeContent));", completionHandler: nil)
    }

    private func handleContentChanged(_ markdown: String) {
        guard let note = currentNote else { return }
        guard markdown != lastLoadedMarkdown else { return }
        lastLoadedMarkdown = markdown
        hasUnsavedChanges = true

        note.content = NSMutableAttributedString(string: markdown)

        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak note] in
            guard let self = self, let note = note else { return }
            self.persistNote(note)
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func persistNote(_ note: Note) {
        guard hasUnsavedChanges else { return }
        hasUnsavedChanges = false
        getViewController()?.blockFSUpdates()
        note.save(content: note.content)
    }

    public func flushPendingSave(completion: (() -> Void)? = nil) {
        saveWorkItem?.cancel()
        saveWorkItem = nil

        guard hasUnsavedChanges, let note = currentNote else {
            completion?()
            return
        }

        persistNote(note)
        completion?()
    }

    public func updateAppearance() {
        let isDark = AppEnvironment.current.userData.isDark
        evaluateJavaScript("setTheme(\(isDark));", completionHandler: nil)
    }

    public func focus() {
        evaluateJavaScript("focusEditor();", completionHandler: nil)
    }

    private func serializeToJSON(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: []),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "''"
        }
        // Extract string from JSON array [ "..." ]
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            let startIndex = trimmed.index(after: trimmed.startIndex)
            let endIndex = trimmed.index(before: trimmed.endIndex)
            return String(trimmed[startIndex..<endIndex])
        }
        return "''"
    }
}
