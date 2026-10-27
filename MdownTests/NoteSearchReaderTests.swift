import XCTest

final class NoteSearchReaderTests: XCTestCase {
    func testReadsMatchBeyondFormerSearchLimitAndAcrossUTF8ChunkBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let text = String(repeating: "a", count: 65_535) + "中文 café" + String(repeating: "b", count: 65_536)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let result = try NoteSearchReader.read(url)
        XCTAssertEqual(result, text)
        XCTAssertNotNil(result.range(of: "中文 CAFE", options: [.caseInsensitive, .diacriticInsensitive]))
    }

    func testEmptyFileRemainsReadableForTitleSearch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        XCTAssertEqual(try NoteSearchReader.read(url), "")
    }

    func testCancellationStopsBeforeOpeningFile() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try NoteSearchReader.read(URL(fileURLWithPath: "/nonexistent-mdown-search-test"))
                XCTFail("Cancelled reads must stop before opening a file")
            } catch is CancellationError {
                // Expected, rather than a file-not-found error.
            } catch {
                XCTFail("Expected cancellation, got \(error)")
            }
        }
        await task.value
    }
}
