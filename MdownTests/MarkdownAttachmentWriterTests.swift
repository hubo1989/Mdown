import XCTest
@testable import Mdown

/// `MarkdownAttachmentWriter` must land attachments in the directory that
/// `Note.getImageUrl` resolves `/i/...` and `/files/...` against:
/// `note.project.url`, picked by `Storage.getProjectBy` as the deepest
/// registered sidebar project containing the note. Writing next to the note
/// only matches notes that sit directly inside their project; notes in deeper
/// nested folders would leave the copy orphaned.
@MainActor
final class MarkdownAttachmentWriterTests: XCTestCase {
    /// Builds `<root>/<relativePath>` note on disk and registers `<root>` as a
    /// sidebar project the way Storage bootstraps real ones: root projects scan
    /// one level of subfolders into child projects (`checkSub`), deeper folders
    /// stay unregistered. `sub/` therefore becomes a registered project while
    /// `sub/deeper/` does not.
    private func makeNote(at relativePath: String, registerProject: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MdownAttachment-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let noteURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "before after".write(to: noteURL, atomically: true, encoding: .utf8)

        addTeardownBlock { [root] in
            if registerProject {
                let storage = AppEnvironment.current.storage
                for project in storage.getProjects()
                where project.url == root || project.url.path.hasPrefix(root.path + "/") {
                    storage.removeBy(project: project)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        if registerProject {
            _ = AppEnvironment.current.storage.add(
                project: Project(url: root, label: root.lastPathComponent, isRoot: true))
        }
        return noteURL
    }

    private func imageBytes() throws -> Data {
        let image = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }

    /// The exact resolution `Note.getImageUrl` performs for an emitted
    /// `/i/...` or `/files/...` reference.
    private func resolvedAttachmentURL(
        prefix: String, fileName: String, noteURL: URL
    ) throws -> URL {
        let project = try XCTUnwrap(
            AppEnvironment.current.storage.getProjectBy(url: noteURL),
            "note must sit inside a registered project")
        let note = Note(url: noteURL, with: project)
        return try XCTUnwrap(note.getImageUrl(imageName: "/\(prefix)/\(fileName)"))
    }

    private func assertWrittenFileResolves(
        _ written: MarkdownAttachmentWriter.Written,
        prefix: String,
        noteURL: URL,
        expectedDirectory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(
            written.markdown.hasSuffix("](/\(prefix)/\(written.url.lastPathComponent))"),
            "reference must stay root-relative /\(prefix)/ form",
            file: file, line: line)
        XCTAssertEqual(
            written.url.deletingLastPathComponent().path,
            expectedDirectory.resolvingSymlinksInPath().path,
            "attachment must be written where the URL resolves",
            file: file, line: line)
        let resolved = try resolvedAttachmentURL(
            prefix: prefix, fileName: written.url.lastPathComponent, noteURL: noteURL)
        XCTAssertEqual(
            written.url.resolvingSymlinksInPath().standardizedFileURL.path,
            resolved.resolvingSymlinksInPath().standardizedFileURL.path,
            "written file must equal the Note.getImageUrl resolution",
            file: file, line: line)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: written.url.path),
            file: file, line: line)
    }

    func testNestedNoteWritesImageIntoDeepestRegisteredProject() throws {
        let noteURL = try makeNote(at: "sub/deeper/note.md")
        let written = try MarkdownAttachmentWriter.write(.image(imageBytes()), noteURL: noteURL)

        // deepest registered project is <root>/sub; deeper/ is unregistered
        let expected = noteURL.deletingLastPathComponent().deletingLastPathComponent()
        try assertWrittenFileResolves(written, prefix: "i", noteURL: noteURL, expectedDirectory: expected.appendingPathComponent("i"))
    }

    func testNestedNoteWritesFileAttachmentIntoDeepestRegisteredProject() throws {
        let noteURL = try makeNote(at: "sub/deeper/note.md")
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("brief-\(UUID().uuidString).pdf")
        try Data("%PDF-fixture".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let written = try MarkdownAttachmentWriter.write(.file(source), noteURL: noteURL)

        let expected = noteURL.deletingLastPathComponent().deletingLastPathComponent()
        try assertWrittenFileResolves(written, prefix: "files", noteURL: noteURL, expectedDirectory: expected.appendingPathComponent("files"))
    }

    func testFlatNoteInProjectRootKeepsSiblingAttachmentDirectory() throws {
        let noteURL = try makeNote(at: "note.md")
        let written = try MarkdownAttachmentWriter.write(.image(imageBytes()), noteURL: noteURL)

        try assertWrittenFileResolves(
            written, prefix: "i", noteURL: noteURL,
            expectedDirectory: noteURL.deletingLastPathComponent().appendingPathComponent("i"))
    }

    func testNoteInsideRegisteredSubfolderKeepsItsOwnAttachmentDirectory() throws {
        // sub/ is itself a registered project (checkSub scans one level), so
        // /i/ resolves against sub, not the fixture root.
        let noteURL = try makeNote(at: "sub/note.md")
        let written = try MarkdownAttachmentWriter.write(.image(imageBytes()), noteURL: noteURL)

        try assertWrittenFileResolves(
            written, prefix: "i", noteURL: noteURL,
            expectedDirectory: noteURL.deletingLastPathComponent().appendingPathComponent("i"))
    }

    func testNoteOutsideAnyRegisteredProjectFallsBackToNoteDirectory() throws {
        // No registered project contains the note, so there is nothing to
        // resolve against; the writer must keep the pre-existing behavior of
        // the sibling directory next to the note.
        let noteURL = try makeNote(at: "plain/note.md", registerProject: false)
        let written = try MarkdownAttachmentWriter.write(.image(imageBytes()), noteURL: noteURL)

        XCTAssertTrue(written.markdown.hasSuffix("](/i/\(written.url.lastPathComponent))"))
        XCTAssertEqual(
            written.url.deletingLastPathComponent().path,
            noteURL.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent("i").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.url.path))
    }
}
