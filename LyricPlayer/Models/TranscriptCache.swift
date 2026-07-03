import Foundation
import CryptoKit

/// 识别结果缓存：同一文件（路径 + 大小 + 修改时间 + 识别语言）只识别一次。
enum TranscriptCache {
    private struct Entry: Codable {
        var version: Int
        var localeID: String
        var source: LyricsSource
        var lines: [LyricLine]
    }

    private static let currentVersion = 2

    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("LyricPlayer/Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(for audioURL: URL, localeID: String) -> URL? {
        guard let dir = directory else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        // 不含 mtime：iCloud 同步会反复改动修改时间，导致缓存假性失效
        let key = "\(audioURL.path)|\(size)|\(localeID)"
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name + ".json")
    }

    static func load(for audioURL: URL, localeID: String) -> (lines: [LyricLine], source: LyricsSource)? {
        guard let url = cacheURL(for: audioURL, localeID: localeID),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == currentVersion else { return nil }
        return (entry.lines, entry.source)
    }

    /// lines 允许为空：空结果作为"否定缓存"，避免纯音乐每次都重跑识别。
    static func save(lines: [LyricLine], source: LyricsSource, for audioURL: URL, localeID: String) {
        guard let url = cacheURL(for: audioURL, localeID: localeID),
              let data = try? JSONEncoder().encode(Entry(version: currentVersion, localeID: localeID,
                                                         source: source, lines: lines)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func remove(for audioURL: URL, localeID: String) {
        guard let url = cacheURL(for: audioURL, localeID: localeID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func removeAll() {
        guard let dir = directory else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
