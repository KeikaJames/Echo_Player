import Foundation
import Darwin

/// 绑定一次媒体分析所读取的文件版本，防止同路径替换后串用结果。
struct MediaFileIdentity: Codable, Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var size: Int64
    var changeSeconds: Int64
    var changeNanoseconds: Int64
    var contentGeneration: Data?

    init?(url: URL) {
        var value = stat()
        guard stat(url.path, &value) == 0, value.st_size >= 0 else { return nil }
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        size = Int64(value.st_size)
        changeSeconds = Int64(value.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        contentGeneration = Self.contentGeneration(for: url)
    }

    func isCurrent(url: URL) -> Bool {
        self == MediaFileIdentity(url: url)
    }

    func isCurrentContent(url: URL) -> Bool {
        guard let current = MediaFileIdentity(url: url) else { return false }
        return hasSameContent(as: current)
    }

    /// APFS/iCloud 的内容代次不会被 mtime/xattr 变化扰动。
    func hasSameContent(as other: MediaFileIdentity) -> Bool {
        if self == other { return true }
        guard device == other.device,
              inode == other.inode,
              size == other.size,
              let contentGeneration,
              let otherGeneration = other.contentGeneration else { return false }
        return contentGeneration == otherGeneration
    }

    private static func contentGeneration(for url: URL) -> Data? {
        // 重建 URL，避免 Foundation 复用之前缓存的 resourceValues。
        let freshURL = URL(fileURLWithPath: url.path)
        guard let identifier = try? freshURL
            .resourceValues(forKeys: [.generationIdentifierKey])
            .generationIdentifier else { return nil }
        if let data = identifier as? Data { return data }
        return try? NSKeyedArchiver.archivedData(withRootObject: identifier,
                                                 requiringSecureCoding: true)
    }
}
