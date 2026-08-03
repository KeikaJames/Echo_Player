import Foundation
import CryptoKit

/// 识别结果缓存：同一文件（路径 + 大小 + 内容指纹 + 识别语言）只识别一次。
enum TranscriptCache {
    private final class Coordinator: @unchecked Sendable {
        private let lock = NSLock()
        private var generation: UInt64 = 0

        func currentGeneration() -> UInt64 {
            lock.withLock { generation }
        }

        func read(from url: URL) -> (data: Data, generation: UInt64)? {
            lock.withLock {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return (data, generation)
            }
        }

        func isCurrent(_ expected: UInt64) -> Bool {
            lock.withLock { generation == expected }
        }

        func write(_ data: Data, to url: URL, generation expected: UInt64) {
            lock.withLock {
                guard generation == expected else { return }
                try? data.write(to: url, options: .atomic)
            }
        }

        func remove(at url: URL) {
            lock.withLock {
                generation &+= 1
                try? FileManager.default.removeItem(at: url)
            }
        }

        func removeAll(at url: URL) {
            lock.withLock {
                generation &+= 1
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private struct Entry: Codable {
        var version: Int
        var localeID: String
        var snapshot: MediaFileIdentity
        var fingerprint: String?
        var source: LyricsSource
        var lines: [LyricLine]
    }

    private static let currentVersion = 5
    private static let fingerprintChunkSize = 1024 * 1024
    private static let maximumFingerprintBytes: Int64 = 512 * 1024 * 1024
    private static let coordinator = Coordinator()
    #if DEBUG
    private static let testingHookLock = NSLock()
    private static var beforeGenerationHookForTesting: (@Sendable () -> Void)?
    private static var beforeWriteHookForTesting: (@Sendable () -> Void)?

    static func setBeforeGenerationHookForTesting(_ hook: (@Sendable () -> Void)?) {
        testingHookLock.withLock { beforeGenerationHookForTesting = hook }
    }

    static func setBeforeWriteHookForTesting(_ hook: (@Sendable () -> Void)?) {
        testingHookLock.withLock { beforeWriteHookForTesting = hook }
    }

    private static func runBeforeGenerationHookForTesting() {
        let hook = testingHookLock.withLock { beforeGenerationHookForTesting }
        hook?()
    }

    private static func runBeforeWriteHookForTesting() {
        let hook = testingHookLock.withLock { beforeWriteHookForTesting }
        hook?()
    }
    #endif

    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("LyricPlayer/Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(for audioURL: URL,
                                 localeID: String,
                                 snapshot: MediaFileIdentity? = nil) -> URL? {
        guard let dir = directory else { return nil }
        let size = snapshot?.size ?? MediaFileIdentity(url: audioURL)?.size ?? 0
        // 不含 mtime：iCloud 同步会反复改动修改时间，导致缓存假性失效
        let key = "\(audioURL.path)|\(size)|\(localeID)"
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name + ".json")
    }

    private static func fingerprint(for audioURL: URL,
                                    snapshot: MediaFileIdentity) -> String? {
        guard snapshot.size <= maximumFingerprintBytes,
              !Task.isCancelled,
              snapshot.isCurrent(url: audioURL),
              let file = try? FileHandle(forReadingFrom: audioURL) else { return nil }
        defer { try? file.close() }

        var hasher = SHA256()
        while true {
            guard !Task.isCancelled else { return nil }
            let data: Data
            do {
                data = try file.read(upToCount: fingerprintChunkSize) ?? Data()
            } catch {
                return nil
            }
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        guard snapshot.isCurrent(url: audioURL) else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func load(for audioURL: URL,
                     localeID: String,
                     sourceIdentity: MediaFileIdentity? = nil) async -> (lines: [LyricLine], source: LyricsSource)? {
        let worker = Task.detached(priority: .utility) { () -> (lines: [LyricLine], source: LyricsSource)? in
            guard let snapshot = MediaFileIdentity(url: audioURL),
                  sourceIdentity?.hasSameContent(as: snapshot) != false,
                  let url = cacheURL(for: audioURL, localeID: localeID, snapshot: snapshot),
                  let cached = coordinator.read(from: url),
                  !Task.isCancelled else { return nil }
            guard let entry = try? JSONDecoder().decode(Entry.self, from: cached.data),
                  entry.version == currentVersion,
                  entry.localeID == localeID else { return nil }

            if entry.snapshot == snapshot {
                guard snapshot.isCurrent(url: audioURL),
                      coordinator.isCurrent(cached.generation) else { return nil }
                return (entry.lines, entry.source)
            }
            let verifiedFingerprint: String?
            if entry.snapshot.hasSameContent(as: snapshot) {
                verifiedFingerprint = entry.fingerprint
            } else {
                guard let expectedFingerprint = entry.fingerprint,
                      let fingerprint = fingerprint(for: audioURL, snapshot: snapshot),
                      expectedFingerprint == fingerprint else { return nil }
                verifiedFingerprint = fingerprint
            }
            guard !Task.isCancelled,
                  snapshot.isCurrent(url: audioURL) else { return nil }

            let refreshed = Entry(version: currentVersion,
                                  localeID: localeID,
                                  snapshot: snapshot,
                                  fingerprint: verifiedFingerprint,
                                  source: entry.source,
                                  lines: entry.lines)
            if let refreshedData = try? JSONEncoder().encode(refreshed) {
                coordinator.write(refreshedData, to: url, generation: cached.generation)
            }
            guard !Task.isCancelled,
                  snapshot.isCurrent(url: audioURL),
                  coordinator.isCurrent(cached.generation) else { return nil }
            return (entry.lines, entry.source)
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        return Task.isCancelled ? nil : result
    }

    /// lines 允许为空：空结果作为"否定缓存"，避免纯音乐每次都重跑识别。
    static func save(lines: [LyricLine],
                     source: LyricsSource,
                     for audioURL: URL,
                     localeID: String,
                     sourceIdentity: MediaFileIdentity? = nil) async {
        #if DEBUG
        runBeforeGenerationHookForTesting()
        #endif
        let generation = coordinator.currentGeneration()
        guard !Task.isCancelled,
              let snapshot = MediaFileIdentity(url: audioURL),
              sourceIdentity?.hasSameContent(as: snapshot) != false else { return }
        let worker = Task.detached(priority: .utility) {
            guard snapshot.isCurrent(url: audioURL),
                  let url = cacheURL(for: audioURL, localeID: localeID, snapshot: snapshot),
                  !Task.isCancelled else { return }
            let fileFingerprint: String?
            if snapshot.size <= maximumFingerprintBytes {
                guard let fingerprint = fingerprint(for: audioURL, snapshot: snapshot) else { return }
                fileFingerprint = fingerprint
            } else {
                // 卷不支持内容代次时，快照变化即失效，避免扫描整部视频。
                fileFingerprint = nil
            }
            guard !Task.isCancelled,
                  snapshot.isCurrent(url: audioURL),
                  let data = try? JSONEncoder().encode(Entry(version: currentVersion,
                                                             localeID: localeID,
                                                             snapshot: snapshot,
                                                             fingerprint: fileFingerprint,
                                                             source: source,
                                                             lines: lines)) else { return }
            #if DEBUG
            runBeforeWriteHookForTesting()
            #endif
            coordinator.write(data, to: url, generation: generation)
        }
        await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func remove(for audioURL: URL, localeID: String) {
        guard let url = cacheURL(for: audioURL, localeID: localeID) else { return }
        coordinator.remove(at: url)
    }

    static func removeAll() {
        guard let dir = directory else { return }
        coordinator.removeAll(at: dir)
    }
}
