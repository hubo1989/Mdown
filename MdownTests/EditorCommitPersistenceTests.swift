import XCTest

@testable import Mdown

/// T07 (SPEC §7.1): verifiable write outcomes. A save attempt is only
/// allowed to clear dirty when the disk write succeeded AND the captured
/// identity/generation/revision/digest still matches the note's current
/// committed state. Same-URL rebinds with equal numeric revisions must not
/// let stale completions clear a newer draft.
final class EditorCommitPersistenceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiaoYanEditorCommitTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    @MainActor
    private func makeNote(named: String = "note.md") -> Note {
        let project = Project(url: tempDir, label: "test", isRoot: true)
        return Note(url: tempDir.appendingPathComponent(named), with: project)
    }

    // MARK: - commit marks dirty immediately, not on the timer

    @MainActor
    func testCommitMarksDirtyAndRevisionImmediately() {
        let note = makeNote()

        note.commit(content: NSMutableAttributedString(string: "draft v1"))

        XCTAssertTrue(note.needsSave, "commit must set dirty immediately, not wait for the timer")
        XCTAssertEqual(note.committedRevision, 1)
        XCTAssertTrue(note.hasPendingSave)
    }

    @MainActor
    func testCommitBumpsRevisionPerCommit() {
        let note = makeNote()

        note.commit(content: NSMutableAttributedString(string: "v1"))
        note.commit(content: NSMutableAttributedString(string: "v2"))
        note.commit(content: NSMutableAttributedString(string: "v3"))

        XCTAssertEqual(note.committedRevision, 3)
    }

    // MARK: - save(globalStorage:) compatibility with observable outcome

    @MainActor
    func testSaveReturningOutcomeSavesAndClearsDirty() throws {
        let note = makeNote()
        note.commit(content: NSMutableAttributedString(string: "body"))

        let outcome = note.saveReturningOutcome(globalStorage: false)

        XCTAssertEqual(outcome, .saved)
        XCTAssertFalse(note.needsSave)
        let written = try String(contentsOf: note.getURL(), encoding: .utf8)
        XCTAssertTrue(written.contains("body"))
    }

    @MainActor
    func testSaveOnRetiredNoteReturnsRetired() {
        let note = makeNote()
        note.retireAfterRemoval()

        XCTAssertEqual(note.saveReturningOutcome(globalStorage: false), .retired)
        XCTAssertEqual(note.flushPendingSaveOutcome(globalStorage: false), .retired)
    }

    @MainActor
    func testFlushWithNoDirtyReturnsNoChanges() {
        let note = makeNote()

        XCTAssertEqual(note.flushPendingSaveOutcome(globalStorage: false), .noChanges)
    }

    // MARK: - in-flight race: rev1 write completing after rev2 committed

    @MainActor
    func testStaleWriteCompletionCannotClearNewerDraftDirty() throws {
        let note = makeNote()
        note.commit(content: NSMutableAttributedString(string: "revision one"))
        // Simulate a write captured for rev1 that has not landed yet: bypass
        // performDiskWrite by calling the internal completion seam directly.
        let stalePending = NotePendingWriteIdentity(
            url: note.getURL(),
            generation: note.editGeneration,
            revision: note.committedRevision,
            digest: "revision one".md5)

        // Newer draft arrives (rev2) while rev1 is "in flight".
        note.commit(content: NSMutableAttributedString(string: "revision two"))
        XCTAssertTrue(note.needsSave)

        let outcome = note.completeSave(stalePending, writeSucceeded: true, globalStorage: false)

        XCTAssertEqual(outcome, .superseded)
        XCTAssertTrue(
            note.needsSave,
            "a rev1 completion must not clear rev2's dirty state")
    }

    @MainActor
    func testMatchingWriteCompletionClearsDirty() {
        let note = makeNote()
        note.commit(content: NSMutableAttributedString(string: "same body"))
        let pending = NotePendingWriteIdentity(
            url: note.getURL(),
            generation: note.editGeneration,
            revision: note.committedRevision,
            digest: "same body".md5)

        let outcome = note.completeSave(pending, writeSucceeded: true, globalStorage: false)

        XCTAssertEqual(outcome, .saved)
        XCTAssertFalse(note.needsSave)
    }

    @MainActor
    func testFailedWriteKeepsDirtyAndRetryCanSucceed() throws {
        // A missing destination file with initial creation disallowed makes
        // the real disk path fail deterministically.
        let note = makeNote(named: "missing.md")
        note.allowsInitialFileCreationForTesting = false
        note.commit(content: NSMutableAttributedString(string: "doomed draft"))

        let outcome = note.saveReturningOutcome(globalStorage: false)

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(note.needsSave, "failed write keeps dirty so retry is possible")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.getURL().path))

        // Retry after the file can be created must succeed.
        note.allowsInitialFileCreationForTesting = true
        XCTAssertEqual(note.saveReturningOutcome(globalStorage: false), .saved)
        XCTAssertTrue(
            try String(contentsOf: note.getURL(), encoding: .utf8).contains("doomed draft"))
    }

    // MARK: - generation invalidates stale completions (same-URL rebind)

    @MainActor
    func testSameURLRebindWithEqualRevisionRejectsStaleCompletion() {
        let note = makeNote()
        note.commit(content: NSMutableAttributedString(string: "before rebind"))
        let pending = NotePendingWriteIdentity(
            url: note.getURL(),
            generation: note.editGeneration,
            revision: note.committedRevision,
            digest: "before rebind".md5)

        // Rebind to a different URL but force the revision number to match,
        // as a watcher reload could; the generation must still gate it.
        let oldRevision = note.committedRevision
        note.overwrite(url: tempDir.appendingPathComponent("rebound.md"))
        XCTAssertEqual(note.committedRevision, oldRevision)
        note.commit(content: NSMutableAttributedString(string: "after rebind"))
        note.committedRevisionForTesting = oldRevision

        let outcome = note.completeSave(pending, writeSucceeded: true, globalStorage: false)

        XCTAssertEqual(outcome, .superseded)
        XCTAssertTrue(note.needsSave)
    }

    @MainActor
    func testRenameBumpsGeneration() {
        let note = makeNote()
        let before = note.editGeneration

        note.overwrite(url: tempDir.appendingPathComponent("renamed.md"))

        XCTAssertEqual(note.editGeneration, before + 1)
    }

    // MARK: - byte-level round trip: BOM / CRLF / no final newline

    @MainActor
    func testSaveRoundTripPreservesCRLFAndNoFinalNewline() throws {
        let note = makeNote(named: "crlf.md")
        try Data("line one\r\nline two\r\nno trailing newline".utf8)
            .write(to: note.getURL())
        let project = Project(url: tempDir, label: "test", isRoot: true)
        let loaded = Note(url: note.getURL(), with: project)
        loaded.load()

        loaded.commit(
            content: NSMutableAttributedString(
                string: (loaded.content.string as NSString)
                    .replacingOccurrences(of: "one", with: "ONE")))
        XCTAssertEqual(loaded.saveReturningOutcome(globalStorage: false), .saved)

        let bytes = try Data(contentsOf: loaded.getURL())
        let text = String(bytes: bytes, encoding: .utf8) ?? ""
        XCTAssertTrue(
            text.contains("\r\n"),
            "CRLF line endings on disk must survive a save round trip")
        XCTAssertFalse(
            text.hasSuffix("\n"),
            "a missing final newline must not gain one by accident")
        XCTAssertTrue(text.contains("line ONE"))
    }

    @MainActor
    func testSaveRoundTripPreservesUTF8BOM() throws {
        let note = makeNote(named: "bom.md")
        var original = Data([0xEF, 0xBB, 0xBF])
        original.append(Data("bom body".utf8))
        try original.write(to: note.getURL())
        let project = Project(url: tempDir, label: "test", isRoot: true)
        let loaded = Note(url: note.getURL(), with: project)
        loaded.load()

        XCTAssertEqual(loaded.saveReturningOutcome(globalStorage: false), .saved)

        let bytes = try Data(contentsOf: loaded.getURL())
        XCTAssertEqual(
            bytes.prefix(3), Data([0xEF, 0xBB, 0xBF]),
            "a UTF-8 BOM on the original file must survive a save round trip")
    }

    // MARK: - commit cost and real source mirror

    @MainActor
    func testCommitUpdatesRealSourceMirrorWithBoundedCost() {
        let note = makeNote()
        let paragraph = String(repeating: "word ", count: 40) + "\n"
        note.commit(
            content: NSMutableAttributedString(
                string: String(repeating: paragraph, count: 200)))
        let baseline = note.content.string

        // Simulate keystroke-sized commits over a large document: each commit
        // must update the real mirror (not leave a stale copy behind) and the
        // whole run must stay far below a save-per-keystroke cost profile.
        let start = Date()
        for i in 0..<500 {
            note.commit(
                content: NSMutableAttributedString(
                    string: baseline + "k\(i)\n"))
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(
            note.content.string.hasSuffix("k499\n"),
            "the committed mirror must reflect the latest commit, not a stale copy")
        XCTAssertEqual(note.committedRevision, 501)
        XCTAssertLessThan(
            elapsed, 2.0,
            "500 keystroke commits on a ~40KB doc took \(elapsed)s; the commit path regressed to a full resave cost")
    }
}
