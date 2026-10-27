import Foundation

/// Search reads local files in chunks so cancellation can stop disk work.
/// Matching still receives the full UTF-8 text, including chunk boundaries.
enum NoteSearchReader {
    static func read(_ url: URL) throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        try Task.checkCancellation()
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}
