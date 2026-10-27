import Foundation

final class NoteVersionManager: @unchecked Sendable {
    static let shared = NoteVersionManager()

    let versionsRoot: URL
    let legacyVersionsRoot: URL
    private let maxVersions = 20
    private let minInterval: TimeInterval = 300
    private var lastSaved: [String: Date] = [:]
    private let queue = DispatchQueue(label: "com.mdown.app.versions")

    static var defaultVersionsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("\(AppIdentifier.bundleID)/Versions")
    }

    static var defaultLegacyVersionsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("\(AppIdentifier.legacyBundleID)/Versions")
    }

    private init() {
        versionsRoot = Self.defaultVersionsRoot
        legacyVersionsRoot = Self.defaultLegacyVersionsRoot
        try? FileManager.default.createDirectory(at: versionsRoot, withIntermediateDirectories: true)
        Self.copyMissingVersionDirectories(from: legacyVersionsRoot, to: versionsRoot)
    }

    static func storageKey(forNoteURL url: URL) -> String {
        var hash: UInt64 = 5381
        for byte in url.path.utf8 { hash = hash &* 31 &+ UInt64(byte) }
        return "\(url.deletingPathExtension().lastPathComponent)-\(String(hash, radix: 16))"
    }

    static func copyMissingVersionDirectories(from sourceRoot: URL, to targetRoot: URL) {
        let fm = FileManager.default
        guard sourceRoot.standardizedFileURL != targetRoot.standardizedFileURL,
            let dirs = try? fm.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil)
        else { return }
        try? fm.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        for srcDir in dirs {
            let dstDir = targetRoot.appendingPathComponent(srcDir.lastPathComponent, isDirectory: true)
            copyMissingFiles(from: srcDir, to: dstDir)
        }
    }

    static func rebindVersions(
        relativePaths: Set<String>,
        fromLibrary oldLibraryURL: URL,
        toLibrary newLibraryURL: URL,
        sourceVersionsRoot: URL,
        targetVersionsRoot: URL
    ) {
        copyMissingVersionDirectories(from: sourceVersionsRoot, to: targetVersionsRoot)
        for rel in relativePaths where !rel.isEmpty {
            let oldURL = oldLibraryURL.appendingPathComponent(rel)
            let newURL = newLibraryURL.appendingPathComponent(rel)
            let oldKey = storageKey(forNoteURL: oldURL)
            let newKey = storageKey(forNoteURL: newURL)
            let srcDir = sourceVersionsRoot.appendingPathComponent(oldKey, isDirectory: true)
            let dstDir = targetVersionsRoot.appendingPathComponent(newKey, isDirectory: true)
            copyMissingFiles(from: srcDir, to: dstDir)
        }
    }

    private static func copyMissingFiles(from srcDir: URL, to dstDir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil),
            !files.isEmpty
        else { return }
        try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        for file in files {
            let dstFile = dstDir.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: dstFile.path) {
                try? fm.copyItem(at: file, to: dstFile)
            }
        }
    }

    @MainActor
    func saveVersionIfNeeded(for note: Note, force: Bool = false, completion: (@MainActor @Sendable () -> Void)? = nil) {
        let key = versionKey(for: note.url)
        let text = note.content.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion?()
            return
        }
        saveVersion(key: key, text: text, force: force, completion: completion)
    }

    private func saveVersion(key: String, text: String, force: Bool, completion: (@MainActor @Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            defer { DispatchQueue.main.async { completion?() } }
            guard let self else { return }
            if !force, let last = self.lastSaved[key], Date().timeIntervalSince(last) < self.minInterval {
                return
            }

            let dir = self.versionsRoot.appendingPathComponent(key)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            if let latest = self.versionsInDir(dir).first,
                let prev = try? String(contentsOf: latest.url, encoding: .utf8),
                self.normalizeForComparison(prev) == self.normalizeForComparison(text)
            {
                return
            }

            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            fmt.locale = Locale(identifier: "en_US_POSIX")
            let name = fmt.string(from: Date())
            let dest = dir.appendingPathComponent(name + ".md")
            try? text.write(to: dest, atomically: true, encoding: .utf8)

            self.lastSaved[key] = Date()
            self.prune(dir: dir)
        }
    }

    @MainActor
    func versions(for note: Note) -> [(date: Date, url: URL)] {
        let key = versionKey(for: note.url)
        let primaryDir = versionsRoot.appendingPathComponent(key)
        let primary = versionsInDir(primaryDir)
        if !primary.isEmpty {
            return primary
        }
        let legacyDir = legacyVersionsRoot.appendingPathComponent(key)
        return versionsInDir(legacyDir)
    }

    private func versionsInDir(_ dir: URL) -> [(date: Date, url: URL)] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .compactMap { url -> (Date, URL)? in
                guard let d = fmt.date(from: url.deletingPathExtension().lastPathComponent) else { return nil }
                return (d, url)
            }
            .sorted { $0.0 > $1.0 } ?? []
    }

    @MainActor
    func hasVersions(for note: Note) -> Bool {
        let key = versionKey(for: note.url)
        let primaryDir = versionsRoot.appendingPathComponent(key)
        if !((try? FileManager.default.contentsOfDirectory(atPath: primaryDir.path)) ?? []).isEmpty {
            return true
        }
        let legacyDir = legacyVersionsRoot.appendingPathComponent(key)
        return !((try? FileManager.default.contentsOfDirectory(atPath: legacyDir.path)) ?? []).isEmpty
    }

    @MainActor
    func removeVersions(for note: Note) {
        let key = versionKey(for: note.url)
        let dir = versionsRoot.appendingPathComponent(key)
        let legacyDir = legacyVersionsRoot.appendingPathComponent(key)
        queue.async {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: legacyDir)
        }
    }

    private func versionKey(for url: URL) -> String {
        Self.storageKey(forNoteURL: url)
    }

    private func normalizeForComparison(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func prune(dir: URL) {
        guard let all = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
            all.count > maxVersions
        else { return }
        all.sorted { $0.lastPathComponent > $1.lastPathComponent }
            .dropFirst(maxVersions)
            .forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
