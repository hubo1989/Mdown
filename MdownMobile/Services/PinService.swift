import Foundation

/// Note pinning for the iOS app. Mirrors the macOS app: a note is pinned by
/// writing a one-byte boolean into the extended attribute `com.mdown.app.pin`
/// (and mirroring to legacy `com.tw93.miaoyan.pin` for compatibility).
enum PinService {
    static let pinKey = "com.mdown.app.pin"
    static let legacyPinKey = "com.tw93.miaoyan.pin"

    static func isPinned(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { rawPath -> Bool in
            guard let rawPath else { return false }
            for key in [pinKey, legacyPinKey] {
                guard getxattr(rawPath, key, nil, 0, 0, 0) > 0 else { continue }
                var byte: UInt8 = 0
                let read = withUnsafeMutablePointer(to: &byte) {
                    getxattr(rawPath, key, $0, 1, 0, 0)
                }
                return read == 1 && byte != 0
            }
            return false
        }
    }

    static func setPinned(_ pinned: Bool, for url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { rawPath in
            guard let rawPath else { throw CocoaError(.fileNoSuchFile) }
            var value: UInt8 = pinned ? 1 : 0
            let result = withUnsafePointer(to: &value) {
                setxattr(rawPath, pinKey, $0, 1, 0, 0)
            }
            guard result == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
            _ = withUnsafePointer(to: &value) {
                setxattr(rawPath, legacyPinKey, $0, 1, 0, 0)
            }
        }
    }
}
