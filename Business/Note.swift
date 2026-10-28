import Cocoa
import Darwin
import Foundation
import LocalAuthentication

/// T07 (SPEC §7.1): a write attempt is only allowed to clear dirty when the
/// write succeeded AND the captured identity/generation/revision/digest still
/// matches the note's current state. Anything else is reported, never hidden.
public enum NoteSaveOutcome: Equatable {
    /// Disk write succeeded and the pending write still matches the current
    /// identity/revision/digest; dirty is cleared.
    case saved
    /// Nothing to persist; dirty was already clear.
    case noChanges
    /// Note is retired (removed/trashed); the write is rejected.
    case retired
    /// Disk write failed; dirty is retained and retry is possible.
    case failed
    /// Disk write succeeded but the note moved on (new revision/generation/
    /// URL/digest) before completion. The file holds this older write, but
    /// dirty is retained so the newer committed content is still pending.
    case superseded
}

/// Captured at save-request time; matched at write-completion time so a
/// same-URL rebind or same-numbered revision cannot clear a newer draft's
/// dirty state (SPEC §7.1).
struct NotePendingWriteIdentity: Equatable {
    let url: URL
    let generation: Int
    let revision: Int
    let digest: String
}

@MainActor
public class Note: NSObject {
    @objc var title: String = ""
    var project: Project
    var container: NoteContainer = .none
    var type: NoteType = .markdown
    var url: URL

    var content: NSMutableAttributedString = .init()
    var creationDate: Date? = Date()
    var sharedStorage = Storage.sharedInstance()
    private static let dateFormatter = DateFormatter()
    let undoManager = UndoManager()
    public var originalExtension: String?

    public var name: String = ""
    public var preview: String = ""

    public var isPinned: Bool = false
    public var modifiedLocalAt = Date()

    public var imageUrl: [URL]?
    public var isParsed = false
    private(set) var isContentLoaded = false

    // Debounce for save operations
    private var saveWorkItem: DispatchWorkItem?
    private var hasUnpersistedChanges = false
    private var isRetired = false
    private var allowsInitialFileCreation = false

    // T07: identity/generation/revision bookkeeping for verifiable write
    // outcomes. generation moves on rebind/rename/retire; revision moves on
    // every commit of new content; digest guards content equality.
    private(set) var editGeneration = 0
    private(set) var committedRevision = 0
    private var inFlightWrite: NotePendingWriteIdentity?

    var saveErrorPresenter: (Error) -> Void = { error in
        Task { @MainActor in
            MdownAlert.show(
                message: I18n.str("Save Failed"),
                informativeText: I18n.str(error.localizedDescription),
                style: .warning
            )
        }
    }

    public var hasPendingSave: Bool {
        guard !isRetired else { return false }
        return saveWorkItem.map { !$0.isCancelled } == true
    }
    var needsSave: Bool {
        !isRetired && hasUnpersistedChanges
    }

    /// T05: 源码会话接线用（EditTextView+EditingSession）；存储保持 private。
    var isRetiredForEditing: Bool { isRetired }

    #if DEBUG
        /// T07: 测试接缝——模拟“初始创建被拒”的失败写与 rebind 后同号 revision。
        var allowsInitialFileCreationForTesting: Bool {
            get { allowsInitialFileCreation }
            set { allowsInitialFileCreation = newValue }
        }

        var committedRevisionForTesting: Int {
            get { committedRevision }
            set { committedRevision = newValue }
        }
    #endif

    private var decryptedTemporarySrc: URL?
    public var ciphertextWriter = OperationQueue()

    private var lastSelectedRange: NSRange?

    init(url: URL, with project: Project) {
        ciphertextWriter.maxConcurrentOperationCount = 1
        ciphertextWriter.qualityOfService = .userInteractive

        self.url = url
        self.project = project
        allowsInitialFileCreation = !FileManager.default.fileExists(atPath: url.path)

        super.init()

        parseURL(loadProject: false)
    }

    init(
        name: String? = nil,
        project: Project? = nil,
        type: NoteType? = nil
    ) {
        ciphertextWriter.maxConcurrentOperationCount = 1
        ciphertextWriter.qualityOfService = .userInteractive

        let resolvedProject = project ?? Storage.sharedInstance().getMainProject()
        let resolvedName =
            (name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? name!
            : String()

        self.project = resolvedProject
        self.name = resolvedName

        self.type = type ?? .markdown
        let ext = self.type.fileExtension

        url = NameHelper.getUniqueFileName(
            name: resolvedName,
            project: resolvedProject,
            ext: ext)
        allowsInitialFileCreation = true

        super.init()
        parseURL()
    }

    public func setLastSelectedRange(value: NSRange) {
        lastSelectedRange = value
    }

    public func getLastSelectedRange() -> NSRange? {
        lastSelectedRange
    }

    public func hasTitle() -> Bool {
        true
    }

    public func getURL() -> URL {
        decryptedTemporarySrc ?? url
    }

    public func loadProject(url: URL) {
        self.url = url

        if let project = sharedStorage.getProjectBy(url: url) {
            self.project = project
        }
    }

    func load() {
        if let attributedString = getContent() {
            content = NSMutableAttributedString(attributedString: attributedString)
            isContentLoaded = true
            return
        }
        isContentLoaded = false
    }

    func loadAsync() async {
        if let attributedString = await getContentAsync() {
            content = NSMutableAttributedString(attributedString: attributedString)
            isContentLoaded = true
            return
        }
        isContentLoaded = false
    }

    func reload() -> Bool {
        guard let modifiedAt = getFileModifiedDate() else {
            return false
        }

        if modifiedAt != modifiedLocalAt {
            if let attributedString = getContent() {
                content = NSMutableAttributedString(attributedString: attributedString)
                isContentLoaded = true
            } else {
                isContentLoaded = false
            }
            loadModifiedLocalAt()
            return true
        }

        return false
    }

    public func forceReload() {
        if let attributedString = getContent() {
            content = NSMutableAttributedString(attributedString: attributedString)
            isContentLoaded = true
            return
        }
        isContentLoaded = false
    }

    func loadModifiedLocalAt() {
        guard let modifiedAt = getFileModifiedDate() else {
            modifiedLocalAt = Date()
            return
        }

        modifiedLocalAt = modifiedAt
    }

    // Populates creation/modification dates and pin state directly from disk.
    // Used by Storage's sandbox fallback path (App Store builds whose deferred
    // directory enumeration drops the security-scoped extension) so a note
    // built outside loadProjects ends up with the same metadata fields set.
    func loadMetadataFromDisk() {
        loadModifiedLocalAt()
        creationDate = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate

        #if CLOUDKIT
        #else
            let pinData =
                (try? url.extendedAttribute(forName: AppIdentifier.pinKey))
                ?? (try? url.extendedAttribute(forName: AppIdentifier.legacyPinKey))
            if let data = pinData {
                isPinned = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Bool in
                    ptr.load(as: Bool.self)
                }
            }
        #endif
    }

    public func getExtensionForContainer() -> String {
        type.fileExtension
    }

    public func getFileModifiedDate() -> Date? {
        do {
            let url = getURL()
            let path = url.path

            let attr = try FileManager.default.attributesOfItem(atPath: path)

            return attr[FileAttributeKey.modificationDate] as? Date
        } catch {
            AppDelegate.trackError(error, context: "Note.loadModificationDate")
            AppDelegate.trackError(error, context: "Note.getModificationDate")
            return nil
        }
    }

    func move(to: URL, project: Project? = nil) -> Bool {
        do {
            var destination = to

            if FileManager.default.fileExists(atPath: to.path) {
                guard let project = project ?? sharedStorage.getProjectBy(url: to) else { return false }

                let ext = getExtensionForContainer()
                destination = NameHelper.getUniqueFileName(name: title, project: project, ext: ext)
            }

            try FileManager.default.moveItem(at: url, to: destination)

            let restorePin = isPinned
            if isPinned {
                removePin()
            }

            overwrite(url: destination)

            if restorePin {
                addPin()
            }

        } catch {
            AppDelegate.trackError(error, context: "Note.moveFile")
            return false
        }

        return true
    }

    func getNewURL(name: String) -> URL {
        let escapedName =
            name
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: ":")

        var newUrl = url.deletingLastPathComponent()
        newUrl.appendPathComponent(escapedName + "." + url.pathExtension)
        return newUrl
    }

    public func remove() {
        if !isTrash(), !isEmpty() {
            _ = removeFile()
        } else {
            _ = removeFile()

            if isPinned {
                removePin()
            }
        }
    }

    public func getCursorPosition() -> Int? {
        var position: Int?

        let cursorData =
            (try? url.extendedAttribute(forName: AppIdentifier.cursorKey))
            ?? (try? url.extendedAttribute(forName: AppIdentifier.legacyCursorKey))
        if let data = cursorData {
            position = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                ptr.load(as: Int.self)
            }

            return position
        }

        return nil
    }

    public func isEmpty() -> Bool {
        content.length == 0
    }

    enum FileRemovalResult {
        case moved(destination: URL, original: URL)
        case hiddenFromMdownTrash
    }

    func removeFile(completely: Bool = false) -> FileRemovalResult? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        if isTrash() {
            do {
                if Storage.isSystemTrashProject(project) {
                    // The app Trash is already the volume's system Trash.
                    // Calling trashItem again only renames the file in place
                    // ("note.md" -> "note 2.md"), so FSEvents imports it as
                    // a new note. Mark it as removed from Mdown instead; it
                    // stays recoverable in Finder's Trash and scans ignore the
                    // marker only while the file remains in a Trash project.
                    try url.setExtendedAttribute(
                        data: Data([1]),
                        forName: AppIdentifier.removedFromTrashKey)
                    try? url.setExtendedAttribute(
                        data: Data([1]),
                        forName: AppIdentifier.legacyRemovedFromTrashKey)
                } else {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                NoteVersionManager.shared.removeVersions(for: self)
            } catch {
                AppDelegate.trackError(error, context: "Note.systemTrashError")
                return nil
            }
            return .hiddenFromMdownTrash
        }

        do {
            // A note restored from Finder keeps its xattrs. Clear the marker
            // before a later soft delete so it appears in Mdown Trash again.
            try? url.removeExtendedAttribute(forName: AppIdentifier.removedFromTrashKey)
            try? url.removeExtendedAttribute(forName: AppIdentifier.legacyRemovedFromTrashKey)

            guard let dst = Storage.sharedInstance().trashItem(url: url) else {
                var resultingItemUrl: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItemUrl)

                guard let dst = resultingItemUrl else { return nil }

                let originalURL = url
                overwrite(url: dst as URL)
                return .moved(destination: url, original: originalURL)
            }

            try FileManager.default.moveItem(at: url, to: dst)

            let originalURL = url
            overwrite(url: dst)
            return .moved(destination: url, original: originalURL)

        } catch {
            AppDelegate.trackError(error, context: "Note.trashError")
        }

        return nil
    }

    public func getPreviewLabel(with text: String? = nil) -> String {
        var preview = ""
        let content = text ?? content.string
        let length = text?.count ?? self.content.string.count

        if length > 250 {
            if text == nil {
                let startIndex = content.index(content.startIndex, offsetBy: 0)
                let endIndex = content.index(content.startIndex, offsetBy: 250)
                preview = String(content[startIndex...endIndex])
            } else {
                preview = String(content.prefix(250))
            }
        } else {
            preview = content
        }

        preview = preview.replacingOccurrences(of: "\n", with: " ")

        preview = preview.condenseWhitespace()

        if preview.starts(with: "![") {
            return ""
        }

        return preview
    }

    @objc public func getPreviewForLabel() -> String {
        getPreviewLabel()
    }

    @objc func getDateForLabel() -> String {
        guard
            let date = (project.sortBy == .creationDate || UserDefaultsManagement.sort == .creationDate)
                ? creationDate
                : modifiedLocalAt
        else { return String() }
        return Self.dateFormatter.formatTimeForDisplay(date)
    }

    @objc func getCreationDateForLabel() -> String? {
        guard let creationDate = creationDate else { return nil }
        return Self.dateFormatter.formatTimeForDisplay(creationDate)
    }

    @objc func getCreateTime() -> String? {
        guard let createDate = creationDate else { return nil }
        return Self.dateFormatter.formatTimeForDisplay(createDate)
    }

    @objc func getUpdateTime() -> String? {
        guard let updateDate = getFileModifiedDate() else { return nil }
        return Self.dateFormatter.formatTimeForDisplay(updateDate)
    }

    @objc func getRelativePath() -> String? {
        url.path.replacingOccurrences(of: UserDefaultsManagement.storagePath!, with: "")
    }

    func getContent() -> NSAttributedString? {
        guard let url = getContentFileURL() else { return nil }

        do {
            let options = getDocOptions()

            return try NSAttributedString(url: url, options: options, documentAttributes: nil)
        } catch {
            if let data = try? Data(contentsOf: url) {
                let encoding = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: nil, usedLossyConversion: nil)

                let options = getDocOptions(with: String.Encoding(rawValue: encoding))
                return try? NSAttributedString(url: url, options: options, documentAttributes: nil)
            }
        }

        return nil
    }

    func getContentAsync() async -> NSAttributedString? {
        guard let url = getContentFileURL() else { return nil }

        let stringContent = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                return try String(contentsOf: url, encoding: .utf8)
            } catch {
                if let data = try? Data(contentsOf: url) {
                    let encoding = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: nil, usedLossyConversion: nil)
                    if let fallbackString = try? String(contentsOf: url, encoding: String.Encoding(rawValue: encoding)) {
                        return fallbackString
                    }
                }
            }
            return nil
        }.value

        guard let string = stringContent else { return nil }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UserDefaultsManagement.noteFont as Any
        ]
        return NSAttributedString(string: string, attributes: attrs)
    }

    func isMarkdown() -> Bool {
        type == .markdown
    }

    func addPin(cloudSave: Bool = true) {
        sharedStorage.pinned += 1
        isPinned = true
        var pin = true
        let data = Data(bytes: &pin, count: 1)
        try? url.setExtendedAttribute(data: data, forName: AppIdentifier.pinKey)
        try? url.setExtendedAttribute(data: data, forName: AppIdentifier.legacyPinKey)
    }

    func removePin(cloudSave: Bool = true) {
        if isPinned {
            sharedStorage.pinned -= 1
            isPinned = false
            var pin = false
            let data = Data(bytes: &pin, count: 1)
            try? url.setExtendedAttribute(data: data, forName: AppIdentifier.pinKey)
            try? url.setExtendedAttribute(data: data, forName: AppIdentifier.legacyPinKey)
        }
    }

    func togglePin() {
        if !isPinned {
            addPin()
        } else {
            removePin()
        }
    }

    /// Strips a leading YAML-style frontmatter block (`---\n…\n---`) for preview,
    /// export, and word count. Mirrors `MobileHtmlRenderer.stripFrontmatter` so the
    /// macOS preview and the iOS reader hide the same block. Documents that don't
    /// open with a `---` fence are untouched; three dashes alone stay a horizontal rule.
    func cleanMetaData(content: String) -> String {
        guard content.hasPrefix("---\n") || content.hasPrefix("---\r\n") else { return content }

        // "---\n" and "---\r\n" are both 4 Characters: \r\n is a single grapheme.
        let afterOpening = content.index(content.startIndex, offsetBy: 4)
        // Grapheme-aware search never matches the "\n" inside a "\r\n" cluster,
        // so CRLF documents need their own needle.
        guard
            let closingRange = content.range(of: "\n---", range: afterOpening..<content.endIndex)
                ?? content.range(of: "\r\n---", range: afterOpening..<content.endIndex)
        else {
            return content
        }

        // Closing fence must be its own line: end-of-string or followed by a newline
        // (which is the "\r\n" grapheme in CRLF documents).
        let afterClose = closingRange.upperBound
        if afterClose == content.endIndex {
            return ""
        }
        let nextChar = content[afterClose]
        guard nextChar == "\n" || nextChar == "\r" || nextChar == "\r\n" else {
            return content
        }
        let bodyStart = content.index(after: afterClose)
        return String(content[bodyStart...])
    }

    func getPrettifiedContent() -> String {
        ensureContentLoaded()
        let content = NotesTextProcessor.convertAppLinks(in: content)
        return cleanMetaData(content: content.string)
    }

    public func overwrite(url: URL) {
        self.url = url
        // T07: any identity change invalidates writes captured for the old
        // location; they may still land on disk but cannot clear dirty.
        editGeneration += 1

        parseURL()
    }

    func parseURL(loadProject: Bool = true) {
        if !url.pathComponents.isEmpty {
            container = .none
            name = url.pathComponents.last!

            if container == .none {
                type = .markdown
            }

            loadTitle()
        }

        if loadProject {
            self.loadProject(url: url)
        }
    }

    private func loadTitle() {
        title =
            url
            .deletingPathExtension()
            .pathComponents
            .last!
            .replacingOccurrences(of: ":", with: "/")
    }

    public func save(attributed: NSAttributedString) {
        let mutable = NSMutableAttributedString(attributedString: attributed)

        save(content: mutable)
    }

    public func save(content: NSMutableAttributedString) {
        commit(content: content)
    }

    /// T07: minimal commit interface. Updates the committed source mirror,
    /// marks dirty immediately (never waiting for the 1.5s timer), and
    /// schedules the debounced write. Uses the existing mutable-attr buffer;
    /// no full unLoad/rescan on the per-keystroke path.
    public func commit(content: NSMutableAttributedString) {
        guard !isRetired else { return }
        self.content = content.unLoad()
        hasUnpersistedChanges = true
        committedRevision += 1

        debounceSave(attributedString: self.content)
    }

    public func save(globalStorage: Bool = true) {
        saveReturningOutcome(globalStorage: globalStorage)
    }

    /// Result-returning immediate save (SPEC §7.1): all committed-content
    /// commands should be able to observe the real outcome, not just the
    /// debounced branch.
    @discardableResult
    public func saveReturningOutcome(globalStorage: Bool = true) -> NoteSaveOutcome {
        guard !isRetired else { return .retired }
        if isMarkdown() {
            content = content.unLoadCheckboxes()
        }
        hasUnpersistedChanges = true

        // Immediate save for manual requests or structure changes
        return executeSave(attributedString: content, globalStorage: globalStorage)
    }

    /// Synchronously runs any pending debounced save and clears the work item.
    /// Use from app/window lifecycle hooks (terminate, will-close, resign-key)
    /// and from explicit Cmd+S so unsaved edits cannot disappear in the 1.5s
    /// debounce window. If a previous write failed after its timer fired, this
    /// retries the still-dirty content even though no work item remains.
    ///
    /// Note on the worst-case race: if the debounce timer fires at almost
    /// exactly the same instant a caller invokes flushPendingSave, both can
    /// end up calling executeSave with the same content (`workItem.cancel()`
    /// is documented to only prevent execution that has not yet started).
    /// The double-write is harmless because executeSave is idempotent for the
    /// same `content` value, costing one extra atomic disk write at most. The
    /// debounceSave hook below also clears `saveWorkItem` from inside its own
    /// handler so the second branch becomes a no-op as soon as the workItem
    /// finishes naturally.
    @discardableResult
    public func flushPendingSaveOutcome(globalStorage: Bool = true) -> NoteSaveOutcome {
        guard !isRetired else { return .retired }
        if let workItem = saveWorkItem, !workItem.isCancelled {
            workItem.cancel()
            saveWorkItem = nil
        }
        guard hasUnpersistedChanges else { return .noChanges }
        return executeSave(attributedString: content, globalStorage: globalStorage)
    }

    /// Bool compatibility shim for existing callers; see flushPendingSaveOutcome.
    @discardableResult
    public func flushPendingSave(globalStorage: Bool = true) -> Bool {
        switch flushPendingSaveOutcome(globalStorage: globalStorage) {
        case .saved, .noChanges: return true
        case .retired, .failed, .superseded: return false
        }
    }

    /// T08: abandon the in-session draft without touching the disk file.
    /// Discard is the explicit user choice from the transition gate — it only
    /// drops this session's uncommitted changes (the debounced/failed draft),
    /// reloads `content` from the on-disk truth, and bumps the generation so a
    /// write that raced with the discard completes as `.superseded` instead of
    /// resurrecting the dropped draft or clearing dirty state.
    public func discardUnsavedChanges() {
        guard !isRetired else { return }
        if let workItem = saveWorkItem, !workItem.isCancelled {
            workItem.cancel()
            saveWorkItem = nil
        }
        editGeneration += 1
        committedRevision = 0
        inFlightWrite = nil
        hasUnpersistedChanges = false
        forceReload()
    }

    private func debounceSave(attributedString: NSAttributedString, globalStorage: Bool = true) {
        guard !isRetired else { return }
        saveWorkItem?.cancel()

        // Two-step bind so the closure can compare against its own
        // DispatchWorkItem identity. After the timer fires naturally we
        // clear `saveWorkItem` if it still points at us; that turns a
        // subsequent successful flushPendingSave call into a no-op. A failed
        // write remains retryable through hasUnpersistedChanges.
        var pending: DispatchWorkItem!
        pending = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.saveWorkItem === pending {
                self.saveWorkItem = nil
            }
            _ = self.executeSave(attributedString: attributedString, globalStorage: globalStorage)
        }

        saveWorkItem = pending
        // Debounce for 1.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: pending)
    }

    @discardableResult
    private func executeSave(attributedString: NSAttributedString, globalStorage: Bool = true) -> NoteSaveOutcome {
        guard !isRetired else { return .retired }
        // Cancel pending debounce if we are saving immediately
        saveWorkItem?.cancel()

        // T07: capture the full identity/revision/digest of what we are about
        // to write. Completion is only allowed to clear dirty against this
        // exact tuple plus the note's current digest.
        let pending = NotePendingWriteIdentity(
            url: getURL(),
            generation: editGeneration,
            revision: committedRevision,
            digest: attributedString.string.md5)
        inFlightWrite = pending

        let writeSucceeded = performDiskWrite(
            attributedString: attributedString,
            destination: pending.url)

        return completeSave(pending, writeSucceeded: writeSucceeded, globalStorage: globalStorage)
    }

    /// Internal test seam: complete a previously captured write without going
    /// through the disk path, so the in-flight race (rev1 completing after
    /// rev2 was committed) is directly exercised.
    func completeSave(
        _ pending: NotePendingWriteIdentity,
        writeSucceeded: Bool,
        globalStorage: Bool = true
    ) -> NoteSaveOutcome {
        guard inFlightWrite == nil || inFlightWrite == pending else {
            // A newer write request replaced ours; it owns the outcome.
            return .superseded
        }
        inFlightWrite = nil

        guard writeSucceeded else { return .failed }

        // Same-URL rebind or same-numbered revision after rebind must not
        // clear a newer draft's dirty state.
        let currentDigest = content.string.md5
        guard
            pending.url == getURL(),
            pending.generation == editGeneration,
            pending.revision == committedRevision,
            pending.digest == currentDigest
        else {
            return .superseded
        }

        if globalStorage {
            sharedStorage.add(self)
        }
        allowsInitialFileCreation = false
        hasUnpersistedChanges = false
        return .saved
    }

    /// Disk-write half of executeSave; returns success. Kept free of dirty
    /// bookkeeping so capture/complete ownership is unambiguous.
    private func performDiskWrite(
        attributedString: NSAttributedString,
        destination: URL
    ) -> Bool {
        let attributes = getFileAttributes()

        do {
            let fileWrapper = getFileWrapper(attributedString: attributedString)

            // NSAttributedString's plain-text writer always emits bare UTF-8,
            // which silently strips a UTF-8 BOM the user's file carried. If
            // the on-disk file had one, rebuild the wrapper bytes with it so
            // the round trip is byte-honest (PLAN T07: fix the byte encoding
            // path, don't fake the memory-only test).
            let finalWrapper: FileWrapper
            if destinationHasUTF8BOM(destination),
                !fileWrapperBytesStartWithBOM(fileWrapper),
                let bytes = fileWrapper.regularFileContents
            {
                var bommed = Data([0xEF, 0xBB, 0xBF])
                bommed.append(bytes)
                finalWrapper = FileWrapper(regularFileWithContents: bommed)
                finalWrapper.filename = fileWrapper.filename
            } else {
                finalWrapper = fileWrapper
            }

            let contentSrc: URL? = getContentFileURL()
            guard contentSrc != nil || allowsInitialFileCreation else {
                let error = NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.fileNoSuchFile.rawValue,
                    userInfo: [NSFilePathErrorKey: getURL().path])
                AppDelegate.trackError(error, context: "Note.writeMissingFile")
                return false
            }
            let dst = contentSrc ?? destination

            var originalContentsURL: URL?
            if let contentSrc = contentSrc {
                originalContentsURL = contentSrc
            }

            if let originalContentsURL = originalContentsURL {
                try writeReplacingExistingFile(
                    finalWrapper,
                    at: dst,
                    originalContentsURL: originalContentsURL)
            } else {
                try finalWrapper.write(to: dst, options: .atomic, originalContentsURL: nil)
            }
            try FileManager.default.setAttributes(attributes, ofItemAtPath: dst.path)

            modifiedLocalAt = Date()
            NoteVersionManager.shared.saveVersionIfNeeded(for: self)
            WikilinkIndex.shared.updateNote(title: title, content: attributedString.string)
        } catch {
            AppDelegate.trackError(error, context: "Note.writeError")
            AppDelegate.trackError(error, context: "Note.write")

            saveErrorPresenter(error)
            return false
        }

        return true
    }

    /// True when the file at `url` currently begins with a UTF-8 BOM.
    private func destinationHasUTF8BOM(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 3), head.count == 3 else { return false }
        return head == Data([0xEF, 0xBB, 0xBF])
    }

    /// True when a plain-text FileWrapper's bytes already carry a UTF-8 BOM.
    private func fileWrapperBytesStartWithBOM(_ wrapper: FileWrapper) -> Bool {
        guard let bytes = wrapper.regularFileContents else { return false }
        return bytes.prefix(3) == Data([0xEF, 0xBB, 0xBF])
    }

    /// Writes through a sibling temporary item, then swaps it with the live
    /// file only while that destination still exists. FileWrapper's atomic
    /// write recreates a missing destination, even with originalContentsURL,
    /// which lets an external delete race resurrect a note. RENAME_SWAP
    /// requires both paths to exist at the instant of the exchange.
    private func writeReplacingExistingFile(
        _ fileWrapper: FileWrapper,
        at destination: URL,
        originalContentsURL: URL
    ) throws {
        let replacement =
            destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).mdown-save-\(UUID().uuidString)")

        defer {
            if FileManager.default.fileExists(atPath: replacement.path) {
                do {
                    try FileManager.default.removeItem(at: replacement)
                } catch {
                    AppDelegate.trackError(error, context: "Note.cleanupReplacementFile")
                }
            }
        }

        try fileWrapper.write(to: replacement, options: .atomic, originalContentsURL: nil)

        let metadataResult = originalContentsURL.path.withCString { source in
            replacement.path.withCString { target in
                copyfile(source, target, nil, UInt32(COPYFILE_METADATA))
            }
        }
        guard metadataResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        try Self.swapExistingFile(at: destination, with: replacement)
    }

    /// Atomically exchanges two existing filesystem items. Kept internal so
    /// the fail-closed missing-destination behavior has direct test coverage.
    static func swapExistingFile(at destination: URL, with replacement: URL) throws {
        let result = replacement.path.withCString { source in
            destination.path.withCString { target in
                renamex_np(source, target, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Permanently closes the write lifecycle of a Note instance after its
    /// filesystem removal succeeds. Watcher, editor, and upload callbacks may
    /// still hold the old object, so the final save sink must reject them.
    func retireAfterRemoval() {
        guard !isRetired else { return }
        isRetired = true
        hasUnpersistedChanges = false
        editGeneration += 1
        inFlightWrite = nil
        saveWorkItem?.cancel()
        saveWorkItem = nil
    }

    public func getContentFileURL() -> URL? {
        let url = getURL()

        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        return nil
    }

    public func getFileWrapper(with imagesWrapper: FileWrapper? = nil) -> FileWrapper {
        let fileWrapper = getFileWrapper(attributedString: content)

        fileWrapper.filename = name

        return fileWrapper
    }

    func getFileAttributes() -> [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [:]

        modifiedLocalAt = Date()

        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {}

        attributes[.modificationDate] = modifiedLocalAt
        return attributes
    }

    func getFileWrapper(attributedString: NSAttributedString) -> FileWrapper {
        do {
            let range = NSRange(location: 0, length: attributedString.length)
            let documentAttributes = getDocAttributes()
            return try attributedString.fileWrapper(from: range, documentAttributes: documentAttributes)
        } catch {
            return FileWrapper()
        }
    }

    func getTitleWithoutLabel() -> String {
        let title = url.deletingPathExtension().pathComponents.last!.replacingOccurrences(of: ":", with: "/")

        if title.isValidUUID {
            return ""
        }

        return title
    }

    func getDocOptions(with encoding: String.Encoding = .utf8) -> [NSAttributedString.DocumentReadingOptionKey: Any] {

        return [
            .documentType: NSAttributedString.DocumentType.plain,
            .characterEncoding: NSNumber(value: encoding.rawValue),
        ]
    }

    func getDocAttributes() -> [NSAttributedString.DocumentAttributeKey: Any] {
        var options: [NSAttributedString.DocumentAttributeKey: Any]

        options = [
            .documentType: NSAttributedString.DocumentType.plain,
            .characterEncoding: NSNumber(value: String.Encoding.utf8.rawValue),
        ]

        return options
    }

    func isTrash() -> Bool {
        project.isTrash
    }

    public func contains<S: StringProtocol>(terms: [S]) -> Bool {
        ensureContentLoaded()
        return name.localizedStandardContains(terms) || content.string.localizedStandardContains(terms)
    }

    public func getImageUrl(imageName: String) -> URL? {
        if imageName.starts(with: "http://") || imageName.starts(with: "https://") {
            return URL(string: imageName)
        }

        if imageName.starts(with: "/i/") {
            return project.url.appendingPathComponent(imageName)
        }

        if type == .markdown {
            return project.url.appendingPathComponent(imageName)
        }

        return nil
    }

    public func getImageCacheUrl() -> URL? {
        project.url.appendingPathComponent("/.cache/")
    }

    public func getAllImages(content: NSMutableAttributedString? = nil) -> [(url: URL, path: String)] {
        let content = content ?? self.content
        var res = [(url: URL, path: String)]()

        NotesTextProcessor.imageInlineRegex.regularExpression.enumerateMatches(
            in: content.string, options: NSRegularExpression.MatchingOptions(rawValue: 0), range: NSRange(0..<content.length),
            using: { result, _, _ in

                guard let range = result?.range(at: 3), content.length >= range.location else { return }

                let imagePath = content.attributedSubstring(from: range).string.removingPercentEncoding

                if let imagePath = imagePath, let url = self.getImageUrl(imageName: imagePath), !url.isRemote() {
                    res.append((url: url, path: imagePath))
                }
            })

        return res
    }

    public func getReferencedAttachmentPaths() -> Set<String> {
        var referenced = Set<String>()

        for image in getAllImages() {
            referenced.insert(image.url.path)
        }

        let noteString = content.string
        guard !noteString.isEmpty else { return referenced }

        let nsString = noteString as NSString
        let noteRange = NSRange(location: 0, length: nsString.length)

        Note.attachmentPathRegex.enumerateMatches(in: noteString, options: [], range: noteRange) { result, _, _ in
            guard let range = result?.range else { return }

            let rawPath = nsString.substring(with: range)
            for absolutePath in resolveAttachmentAbsolutePaths(for: rawPath) {
                referenced.insert(absolutePath)
            }
        }

        return referenced
    }

    private func resolveAttachmentAbsolutePaths(for rawPath: String) -> [String] {
        var variants = Set<String>()
        variants.insert(rawPath)

        if let decoded = rawPath.removingPercentEncoding {
            variants.insert(decoded)
        }

        var results = [String]()

        for variant in variants {
            if let absolute = resolveAttachmentAbsolutePath(forNormalizedPath: variant) {
                results.append(absolute)
            }
        }

        return results
    }

    private func resolveAttachmentAbsolutePath(forNormalizedPath path: String) -> String? {
        guard !path.isEmpty else { return nil }

        let projectPath = project.url.path

        if path.hasPrefix("/") {
            let resolved = NSString(string: projectPath + path).standardizingPath
            guard resolved.hasPrefix(projectPath) else { return nil }
            return resolved
        }

        var normalizedPath = path
        if normalizedPath.hasPrefix("./") {
            normalizedPath = String(normalizedPath.dropFirst(2))
        }

        if normalizedPath.hasPrefix("i/") || normalizedPath.hasPrefix("files/") {
            let resolved = NSString(string: projectPath + "/" + normalizedPath).standardizingPath
            guard resolved.hasPrefix(projectPath) else { return nil }
            return resolved
        }

        let noteDirectory = url.deletingLastPathComponent().path
        let resolvedRelative = NSString(string: noteDirectory).appendingPathComponent(normalizedPath)
        let standardized = NSString(string: resolvedRelative).standardizingPath
        guard standardized.hasPrefix(projectPath) else { return nil }

        return standardized
    }

    private static let attachmentPathRegex: NSRegularExpression = {
        let pattern = #"(?:(?:\.\./|\./|/)*)(?:i|files)/[^)\s'"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            preconditionFailure("Note.attachmentPathRegex literal is invalid: \(pattern)")
        }
        return regex
    }()

    public func duplicate() {
        guard let duplicateName = getDupeName() else { return }

        let directory = url.deletingLastPathComponent()
        let duplicateURL = directory.appendingPathComponent(duplicateName).appendingPathExtension(url.pathExtension)

        try? FileManager.default.copyItem(at: self.url, to: duplicateURL)
    }

    public func getDupeName() -> String? {
        let fileName = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()

        let baseName: String
        if fileName.hasSuffix(" Copy") {
            baseName = String(fileName.dropLast(5))  // Remove " Copy"
        } else if let range = fileName.range(of: " Copy ") {
            baseName = String(fileName[..<range.lowerBound])
        } else {
            baseName = fileName
        }

        var copyName = baseName + " Copy"
        var copyNumber = 2

        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(copyName).appendingPathExtension(url.pathExtension).path) {
            copyName = baseName + " Copy \(copyNumber)"
            copyNumber += 1
        }

        return copyName
    }

    public func dealContent() {
        loadTitleFromFileName()
        isParsed = true
    }

    private func loadTitleFromFileName() {
        let fileName = url.deletingPathExtension().pathComponents.last!.replacingOccurrences(of: ":", with: "/")

        title = fileName
    }

    public func invalidateCache() {
        imageUrl = nil
        preview = String()
        title = String()
        isParsed = false
        isContentLoaded = false
    }

    // Synchronous load. Blocks the calling thread for the entire file read; on
    // large notes that means main-thread stalls. Prefer ensureContentLoadedAsync()
    // for new code and limit this to paths where async is impractical (search
    // iteration, save/unload of already-resident notes) or content is known small.
    public func ensureContentLoaded() {
        if !isContentLoaded {
            load()
        }
    }

    public func ensureContentLoadedAsync() async {
        if !isContentLoaded {
            await loadAsync()
        }
    }

    public func markContentAsLoaded() {
        isContentLoaded = true
    }

    public func getMdImagePath(name: String) -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        let name = encoded ?? name

        return "/i/\(name)"
    }

    public func isEqualURL(url: URL) -> Bool {
        url.path == self.url.path
    }

    public func append(string: NSMutableAttributedString) {
        content.append(string)
    }

    public func append(image data: Data, url: URL? = nil) {
        guard let path = ImagesProcessor.writeFile(data: data, url: url, note: self) else { return }

        var prefix = "\n\n"
        if content.length == 0 {
            prefix = String()
        }

        let markdown = NSMutableAttributedString(string: "\(prefix)![](\(path))")
        append(string: markdown)
    }

    @objc public func getName() -> String {
        if title.isValidUUID {
            return "Untitled Note"
        }

        return title
    }

    public func getCacheForPreviewImage(at url: URL) -> URL? {
        var temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        temporary.appendPathComponent("Preview")

        if let filePath = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) {
            return temporary.appendingPathComponent(filePath)
        }

        return nil
    }

    private func moveFilesFlatToAssets(note: Note, from imageURL: URL, imagePath: String, to dest: URL) {
        let dest = dest.appendingPathComponent("assets")
        let fileName = imageURL.lastPathComponent

        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false, attributes: nil)
        }

        do {
            try FileManager.default.moveItem(at: imageURL, to: dest.appendingPathComponent(fileName))

            let prefix = "]("
            let postfix = ")"

            let find = prefix + imagePath + postfix
            let replace = prefix + "assets/" + imageURL.lastPathComponent + postfix

            guard find != replace else { return }

            while note.content.mutableString.contains(find) {
                let range = note.content.mutableString.range(of: find)
                note.content.replaceCharacters(in: range, with: replace)
            }
        } catch {
            AppDelegate.trackError(error, context: "Note.encrypt")
        }
    }

    private func moveFilesAssetsToFlat(content: URL, src: URL, project: Project) {
        guard let content = try? String(contentsOf: content) else { return }

        let mutableContent = NSMutableAttributedString(attributedString: NSAttributedString(string: content))

        let imagesMeta = getAllImages(content: mutableContent)
        for imageMeta in imagesMeta {
            let fileName = imageMeta.url.lastPathComponent
            var dst: URL?
            var prefix = "/files/"

            if imageMeta.url.isImage {
                prefix = "/i/"
            }

            dst = project.url.appendingPathComponent(prefix + fileName)

            guard let moveTo = dst else { continue }

            let dstDir = project.url.appendingPathComponent(prefix)
            let moveFrom = src.appendingPathComponent("assets/" + fileName)

            do {
                if !FileManager.default.fileExists(atPath: dstDir.path) {
                    try? FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: false, attributes: nil)
                }

                try FileManager.default.moveItem(at: moveFrom, to: moveTo)

            } catch {
                if let fileName = ImagesProcessor.getFileName(from: moveTo, to: dstDir, ext: moveTo.pathExtension) {
                    let moveTo = dstDir.appendingPathComponent(fileName)
                    try? FileManager.default.moveItem(at: moveFrom, to: moveTo)
                }
            }

            let find = "](assets/" + fileName + ")"
            let replace = "](" + prefix + fileName + ")"

            guard find != replace else { return }

            while mutableContent.mutableString.contains(find) {
                let range = mutableContent.mutableString.range(of: find)
                mutableContent.replaceCharacters(in: range, with: replace)
            }

            try? mutableContent.string.write(to: url, atomically: true, encoding: String.Encoding.utf8)
        }
    }

    private func cleanOut() {
        imageUrl = nil
        content = NSMutableAttributedString(string: String())
        preview = String()
        title = String()
    }

    private func removeTempContainer() {
        if let url = decryptedTemporarySrc {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func showIconInList() -> Bool {
        isPinned
    }

    public func getFileName() -> String {
        let fileName = url.deletingPathExtension().pathComponents.last!.replacingOccurrences(of: ":", with: "/")
        return fileName
    }

    public func getShortTitle() -> String {
        let fileName = getFileName()

        if fileName.isValidUUID {
            return ""
        }

        return fileName
    }

    public func getDefaultTitle() -> String? {
        return I18n.str("Untitled Note")
    }

    public func getTitle() -> String? {
        if !title.isEmpty {
            if title.isValidUUID {
                return getDefaultTitle()
            }

            if title.starts(with: "![") {
                return nil
            }

            return title
        }

        if getFileName().isValidUUID {
            let previewCharsQty = preview.count
            if previewCharsQty > 0 {
                return getDefaultTitle()
            }
        }

        return nil
    }

    public func getExportTitle() -> String {

        let title = getTitle() ?? getFileName()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedTitle = trimmedTitle.replacingOccurrences(of: "/", with: "_")

        return sanitizedTitle
    }

}
