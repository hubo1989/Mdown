import Foundation
import ImageIO

enum MarkdownAttachmentWriter {
    enum Input: Sendable {
        case file(URL)
        case image(Data)
    }

    struct Written: Sendable {
        let url: URL
        let markdown: String
    }

    enum Failure: Error {
        case missingOwner, invalidFile, oversizedFile, unsafeDirectory
    }

    static func write(_ input: Input, noteURL: URL) throws -> Written {
        let manager = FileManager.default
        guard manager.fileExists(atPath: noteURL.path) else { throw Failure.missingOwner }
        let data: Data
        let name: String
        let originalExtension: String
        switch input {
        case .file(let url):
            guard url.isFileURL else { throw Failure.invalidFile }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw Failure.invalidFile }
            guard let size = values.fileSize, size <= 100 * 1024 * 1024 else { throw Failure.oversizedFile }
            data = try Data(contentsOf: url)
            name = url.deletingPathExtension().lastPathComponent
            originalExtension = url.pathExtension
        case .image(let bytes):
            guard !bytes.isEmpty, bytes.count <= 100 * 1024 * 1024 else { throw Failure.oversizedFile }
            data = bytes
            name = ""
            originalExtension = "png"
        }
        let image = CGImageSourceCreateWithData(data as CFData, nil)
        let isImage = image.map { CGImageSourceGetCount($0) > 0 } ?? false
        if case .image = input, !isImage { throw Failure.invalidFile }
        let fileExtension: String
        if isImage, let image, let type = CGImageSourceGetType(image) {
            fileExtension = (type as String).utiFileExtension ?? originalExtension
        } else {
            fileExtension = originalExtension
        }
        let safeExtension = fileExtension.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        let fileName = UUID().uuidString.lowercased() + (safeExtension.isEmpty ? "" : "." + safeExtension)
        let root = noteURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let folder = root.appendingPathComponent(isImage ? "i" : "files", isDirectory: true)
        guard folder.resolvingSymlinksInPath().standardizedFileURL.path == folder.standardizedFileURL.path else { throw Failure.unsafeDirectory }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard manager.fileExists(atPath: noteURL.path) else { throw Failure.missingOwner }
        let destination = folder.appendingPathComponent(fileName)
        try data.write(to: destination, options: .withoutOverwriting)
        let label = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let prefix = isImage ? "!" : ""
        return Written(url: destination, markdown: "\(prefix)[\(label)](/\(isImage ? "i" : "files")/\(fileName))")
    }

    @MainActor
    static func discard(_ written: Written) {
        do {
            try FileManager.default.removeItem(at: written.url)
        } catch {
            AppDelegate.trackError(error, context: "MarkdownAttachmentWriter.discard")
        }
    }
}
