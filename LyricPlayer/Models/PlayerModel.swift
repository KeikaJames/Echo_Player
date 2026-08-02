import Foundation
import Observation
import AVFoundation
import MediaPlayer
import AppKit
import UniformTypeIdentifiers

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var symbolName: String { self == .one ? "repeat.1" : "repeat" }
    var displayName: String {
        switch self {
        case .off: return "关闭循环"
        case .all: return "列表循环"
        case .one: return "单曲循环"
        }
    }
}

enum LyricsStatus: Equatable {
    case idle
    case recognizing(fraction: Double?, message: String?)
    case done(LyricsSource)
    case failed(String)
}

private struct MediaExpansion: Sendable {
    var urls: [URL]
    var reachedLimit: Bool
    var rejectedCount: Int
}

private struct SecurityScopedBookmark: Codable, Sendable {
    let path: String
    let isDirectory: Bool
    let data: Data
}

private struct RestoredSecurityScope {
    let originalURL: URL
    let resolvedURL: URL
    let isDirectory: Bool

    func remap(_ url: URL) -> URL? {
        let original = originalURL.standardizedFileURL
        let target = url.standardizedFileURL
        if !isDirectory {
            return original == target ? resolvedURL : nil
        }
        guard target.pathComponents.starts(with: original.pathComponents) else { return nil }
        return target.pathComponents.dropFirst(original.pathComponents.count).reduce(resolvedURL) {
            $0.appendingPathComponent($1)
        }
    }
}

private final class SecurityScopedAccessStore {
    private struct Access {
        let url: URL
        let isDirectory: Bool
        let shouldStop: Bool
    }

    private var roots: [String: Access] = [:]

    func adopt(_ urls: [URL]) {
        let sorted = urls.map { url -> (url: URL, isDirectory: Bool) in
            let standardized = url.standardizedFileURL
            let isDirectory = (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                ?? standardized.hasDirectoryPath
            return (standardized, isDirectory)
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.url.pathComponents.count < rhs.url.pathComponents.count
        }
        for item in sorted {
            let source = item.url
            if let data = try? source.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil, relativeTo: nil
            ), let readOnlyURL = resolve(data) {
                source.stopAccessingSecurityScopedResource()
                insert(readOnlyURL, isDirectory: item.isDirectory, shouldStop: true)
            } else {
                insert(source, isDirectory: item.isDirectory, shouldStop: true)
            }
        }
    }

    func restore(_ bookmarks: [SecurityScopedBookmark])
        -> (scopes: [RestoredSecurityScope], preserved: [SecurityScopedBookmark]) {
        var scopes: [RestoredSecurityScope] = []
        var preserved: [SecurityScopedBookmark] = []
        for bookmark in bookmarks {
            guard let url = resolve(bookmark.data) else {
                preserved.append(bookmark)
                continue
            }
            insert(url, isDirectory: bookmark.isDirectory, shouldStop: true)
            scopes.append(RestoredSecurityScope(
                originalURL: URL(fileURLWithPath: bookmark.path, isDirectory: bookmark.isDirectory),
                resolvedURL: url.standardizedFileURL,
                isDirectory: bookmark.isDirectory
            ))
            preserved.append(SecurityScopedBookmark(path: url.standardizedFileURL.path,
                                                     isDirectory: bookmark.isDirectory,
                                                     data: bookmark.data))
        }
        return (scopes, preserved)
    }

    func restoreLegacy(_ bookmarks: [Data]) -> [Data] {
        var unresolved: [Data] = []
        for bookmark in bookmarks {
            guard let url = resolve(bookmark) else {
                unresolved.append(bookmark)
                continue
            }
            insert(url, isDirectory: nil, shouldStop: true)
        }
        return unresolved
    }

    func bookmarks(covering urls: [URL]) -> [SecurityScopedBookmark] {
        let keys = Set(urls.compactMap { coveringKey(for: $0) })
        return keys.compactMap { roots[$0] }.sorted { $0.url.path < $1.url.path }.compactMap { access in
            guard let data = try? access.url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil, relativeTo: nil
            ) else { return nil }
            return SecurityScopedBookmark(path: access.url.standardizedFileURL.path,
                                          isDirectory: access.isDirectory, data: data)
        }
    }

    func reconcile(keeping urls: [URL]) {
        let wanted = Set(urls.compactMap { coveringKey(for: $0) })
        let unused = roots.keys.filter { !wanted.contains($0) }
        for key in unused {
            guard let access = roots.removeValue(forKey: key), access.shouldStop else { continue }
            access.url.stopAccessingSecurityScopedResource()
        }
    }

    private func insert(_ url: URL, isDirectory knownDirectory: Bool?, shouldStop: Bool) {
        let standardized = url.standardizedFileURL
        if coveringKey(for: standardized) != nil {
            if shouldStop { url.stopAccessingSecurityScopedResource() }
            return
        }

        let isDirectory = knownDirectory
            ?? (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
            ?? standardized.hasDirectoryPath
        roots[standardized.path] = Access(url: url, isDirectory: isDirectory, shouldStop: shouldStop)
    }

    private func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    private func coveringKey(for url: URL) -> String? {
        let target = url.standardizedFileURL
        let components = target.pathComponents
        for count in 1...components.count {
            let path = NSString.path(withComponents: Array(components.prefix(count)))
            if roots[path]?.isDirectory == true { return path }
        }
        return roots[target.path] == nil ? nil : target.path
    }

    deinit {
        for access in roots.values where access.shouldStop {
            access.url.stopAccessingSecurityScopedResource()
        }
    }
}

@Observable
final class PlayerModel {
    static let shared = PlayerModel()
    private static let maxImportFiles = 10_000
    private static let maxImportEntries = 100_000
    private static let maxImportDepth = 20

    // MARK: - 播放状态
    var playlist: [Track] = []
    var currentTrackID: Track.ID?
    var sidebarSelection: Track.ID?
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var repeatMode: RepeatMode = .off
    var shuffleEnabled = false
    var showLyrics = true
    var allowOnlineLyrics = UserDefaults.standard.bool(forKey: "allowOnlineLyrics") {
        didSet {
            UserDefaults.standard.set(allowOnlineLyrics, forKey: "allowOnlineLyrics")
            onlineConsentGeneration &+= 1
            if !allowOnlineLyrics {
                onlineLyricsTask?.cancel()
                onlineLyricsTask = nil
                onlineRequestID = nil
                onlineUpgradeTask?.cancel()
                onlineUpgradeTask = nil
                onlineRetryTask?.cancel()
                onlineRetryTask = nil
            }
        }
    }

    /// 边缘光晕开关（窗内 + 窗外一起控制）。
    var glowEnabled: Bool = UserDefaults.standard.object(forKey: "glowEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(glowEnabled, forKey: "glowEnabled")
            GlowHaloController.shared.enabled = glowEnabled
        }
    }

    var volume: Float = UserDefaults.standard.object(forKey: "playerVolume") as? Float ?? 0.8 {
        didSet {
            audioBackend.volume = volume
            videoBackend.volume = volume
            UserDefaults.standard.set(volume, forKey: "playerVolume")
        }
    }

    var playbackRate: Float = 1.0 {
        didSet {
            audioBackend.rate = playbackRate
            videoBackend.rate = playbackRate
            updateNowPlayingInfo()
        }
    }

    /// 当前曲目是视频时，供画面渲染层使用的 AVPlayer。
    var videoPlayer: AVPlayer? {
        guard currentTrack?.isVideo == true else { return nil }
        return videoBackend.player
    }

    // MARK: - 歌词状态
    var lyricLines: [LyricLine] = []
    var lyricsStatus: LyricsStatus = .idle
    var currentLineIndex: Int?

    var currentTrack: Track? {
        currentTrackID.flatMap { id in playlist.first { $0.id == id } }
    }

    // MARK: - 私有
    @ObservationIgnored private let audioBackend = EnginePlayer()
    @ObservationIgnored private let videoBackend = VideoBackend()
    @ObservationIgnored private var player: PlaybackBackend
    @ObservationIgnored private var consecutiveLoadFailures = 0
    @ObservationIgnored private var displayTimer: Timer?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var restorationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingImportURLs: [URL] = []
    @ObservationIgnored private var metadataBatchTask: Task<Void, Never>?
    @ObservationIgnored private var metadataLoadedIDs: Set<Track.ID> = []
    @ObservationIgnored private let securityAccess = SecurityScopedAccessStore()
    @ObservationIgnored private var deferredAccessGrants: [SecurityScopedBookmark] = []
    @ObservationIgnored private var deferredLegacyBookmarks: [Data] = []
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var onlineLyricsTask: Task<OnlineLyrics.FetchResult?, Never>?
    @ObservationIgnored private var onlineUpgradeTask: Task<Void, Never>?
    @ObservationIgnored private var onlineRetryTask: Task<Void, Never>?
    @ObservationIgnored private var onlineRequestID: UUID?
    @ObservationIgnored private var onlineConsentGeneration = 0
    @ObservationIgnored private var cacheGeneration = 0
    // 离线拍点网格：就绪后光晕按网格零延迟触发；未就绪时用实时检测器过渡
    @ObservationIgnored private var beatGrid: [Double]?
    @ObservationIgnored private var beatGridTask: Task<Void, Never>?
    // 视频氛围光：低频采样画面边缘色，光晕用它替代彩虹
    @ObservationIgnored private var ambientEdgeColors: [NSColor]?
    // 识别快照限频，避免高频回调刷爆 UI
    @ObservationIgnored private var lastSnapshotAt = Date.distantPast
    @ObservationIgnored private var lastSnapshotMessage: String??

    private init() {
        player = audioBackend
        audioBackend.volume = volume
        videoBackend.volume = volume
        let endHandler: () -> Void = { [weak self] in
            self?.handleTrackEnded()
        }
        audioBackend.onTrackEnd = endHandler
        videoBackend.onTrackEnd = endHandler
        videoBackend.onVideoSize = { [weak self] size in
            self?.applyWindowAspect(size)
        }

        var ticks = 0
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.currentTrackID != nil else { return }
            let seconds = self.player.currentTime
            if abs(seconds - self.currentTime) > 0.02 {
                self.currentTime = seconds
                self.updateCurrentLine()
            }
            // AVPlayer 的 duration 异步就绪；后端给出有效值后补上进度条终点
            let backendDuration = self.player.duration
            if backendDuration > 0, abs(backendDuration - self.duration) > 0.5 {
                self.duration = backendDuration
                self.updateNowPlayingInfo()
            }
            ticks += 1
            // 原生视频控制条可直接操作 AVPlayer：把播放态同步回模型
            if self.isPlaying != self.player.isPlaying {
                self.isPlaying = self.player.isPlaying
                self.updateNowPlayingInfo()
            }
            // 视频氛围光：每 0.3 秒采样一次画面边缘色
            if ticks % 3 == 0 {
                let sampleable = self.currentTrack?.isVideo == true
                if sampleable, let colors = self.videoBackend.sampleEdgeColors() {
                    self.ambientEdgeColors = colors
                } else if !sampleable {
                    self.ambientEdgeColors = nil
                }
            }
        }

        setupRemoteCommands()
    }

    deinit {
        importTask?.cancel()
        restorationTask?.cancel()
        metadataBatchTask?.cancel()
        transcriptionTask?.cancel()
        onlineLyricsTask?.cancel()
        onlineUpgradeTask?.cancel()
        onlineRetryTask?.cancel()
        beatGridTask?.cancel()
        displayTimer?.invalidate()
    }

    /// 实时音量电平（0...1），供动态背景与边缘光晕读取；不触发视图观察。
    func audioLevel() -> Float {
        player.audioLevel()
    }

    /// 视频播放时的画面边缘氛围色（顺时针 8 点）；非视频返回 nil（光晕回到彩虹模式）。
    func glowAmbientColors() -> [NSColor]? {
        currentTrack?.isVideo == true ? ambientEdgeColors : nil
    }

    /// 鼓点脉冲（0...1）：优先按离线拍点网格查表（零延迟），网格未就绪时用实时检测。
    func audioPulse() -> Float {
        guard isPlaying else { return player.audioPulse() }
        guard let grid = beatGrid, !grid.isEmpty else { return player.audioPulse() }
        let t = livePlaybackTime() + 0.03   // 轻微前瞻，补偿渲染管线延迟
        // 二分找最后一个 ≤ t 的拍点
        var low = 0, high = grid.count - 1, idx = -1
        while low <= high {
            let mid = (low + high) / 2
            if grid[mid] <= t { idx = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard idx >= 0 else { return 0 }
        let age = t - grid[idx]
        guard age < 0.6 else { return 0 }
        return Float(exp(-6 * age))
    }

    // MARK: - 打开文件

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Track.supportedContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "选择音频/视频文件或所在文件夹"
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            open(urls: panel.urls)
        }
    }

    /// 添加文件/文件夹到播放列表。autoplay 为 true 时自动播放新增的第一首。
    func open(urls: [URL], autoplay: Bool = true) {
        var seen: Set<URL> = []
        var selected: [URL] = []
        var reachedInputLimit = false
        for url in urls {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized).inserted else { continue }
            guard selected.count < Self.maxImportFiles else {
                reachedInputLimit = true
                url.stopAccessingSecurityScopedResource()
                continue
            }
            selected.append(url)
        }
        guard !selected.isEmpty else { return }

        importTask?.cancel()
        pendingImportURLs = []
        securityAccess.reconcile(keeping: playlist.map(\.url))
        securityAccess.adopt(selected)
        pendingImportURLs = selected
        let worker = Task.detached(priority: .userInitiated) {
            var expansion = Self.expandMediaURLs(selected)
            if reachedInputLimit { expansion.reachedLimit = true }
            return expansion
        }
        importTask = Task { @MainActor [weak self] in
            let expansion = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            self.finishOpening(expansion, autoplay: autoplay)
        }
    }

    @MainActor
    private func finishOpening(_ expansion: MediaExpansion, autoplay: Bool) {
        defer {
            pendingImportURLs = []
            securityAccess.reconcile(keeping: playlist.map(\.url))
            saveState()
        }
        let expanded = expansion.urls
        if expansion.reachedLimit || expansion.rejectedCount > 0 {
            let alert = NSAlert()
            alert.messageText = expansion.reachedLimit ? "本次只添加了部分文件" : "有文件未添加"
            var messages: [String] = []
            if expansion.reachedLimit {
                messages.append("为避免应用卡住，本次最多添加 10,000 个媒体文件。")
            }
            if expansion.rejectedCount > 0 {
                messages.append("已跳过 \(expansion.rejectedCount) 个不支持或无法读取的文件。")
            }
            alert.informativeText = messages.joined(separator: "\n")
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
        guard !expanded.isEmpty else { return }

        var existing = Set(playlist.map { $0.url.standardizedFileURL })
        var firstNewID: Track.ID?
        for url in expanded where existing.insert(url.standardizedFileURL).inserted {
            let track = Track(url: url)
            playlist.append(track)
            if firstNewID == nil { firstNewID = track.id }
        }
        let pendingMetadata = playlist
            .filter { !metadataLoadedIDs.contains($0.id) && FileManager.default.fileExists(atPath: $0.url.path) }
            .map { ($0.id, $0.url) }
        loadMetadata(for: pendingMetadata)

        if autoplay, let id = firstNewID {
            play(trackID: id)
        } else if autoplay, firstNewID == nil,
                  let existingURL = expanded.first?.standardizedFileURL,
                  let existingTrack = playlist.first(where: { $0.url.standardizedFileURL == existingURL }) {
            // 拖入的都是已在列表中的文件：直接播放第一个，而不是毫无反应
            play(trackID: existingTrack.id)
        } else if currentTrackID == nil, let first = playlist.first {
            // 不自动播放时也载入第一首，便于随时按空格开播
            currentTrackID = first.id
            loadCurrentTrack(playWhenReady: false)
        }
    }

    private static func expandMediaURLs(_ urls: [URL]) -> MediaExpansion {
        var result: [URL] = []
        var seen: Set<URL> = []
        var scannedEntries = 0
        var rejectedCount = 0
        for url in urls {
            if Task.isCancelled { break }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                rejectedCount += 1
                continue
            }
            if isDir.boolValue {
                let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey,
                                              .isSymbolicLinkKey, .isPackageKey]
                let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                var found: [URL] = []
                while let child = enumerator?.nextObject() as? URL {
                    if Task.isCancelled { break }
                    scannedEntries += 1
                    if scannedEntries > maxImportEntries {
                        found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                        result.append(contentsOf: found)
                        return MediaExpansion(urls: result, reachedLimit: true, rejectedCount: rejectedCount)
                    }
                    if enumerator?.level ?? 0 > maxImportDepth {
                        enumerator?.skipDescendants()
                        continue
                    }
                    guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
                    if values.isSymbolicLink == true {
                        enumerator?.skipDescendants()
                        continue
                    }
                    guard values.isRegularFile == true, Track.isMediaFile(child) else { continue }
                    let standardized = child.standardizedFileURL
                    if seen.insert(standardized).inserted { found.append(child) }
                    if result.count + found.count >= maxImportFiles {
                        found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                        result.append(contentsOf: found.prefix(maxImportFiles - result.count))
                        return MediaExpansion(urls: result, reachedLimit: true, rejectedCount: rejectedCount)
                    }
                }
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                result.append(contentsOf: found)
            } else if Track.isMediaFile(url) {
                let standardized = url.standardizedFileURL
                if seen.insert(standardized).inserted { result.append(url) }
            } else {
                rejectedCount += 1
            }
            if result.count >= maxImportFiles {
                return MediaExpansion(urls: Array(result.prefix(maxImportFiles)), reachedLimit: true,
                                      rejectedCount: rejectedCount)
            }
        }
        return MediaExpansion(urls: result, reachedLimit: false, rejectedCount: rejectedCount)
    }

    private func loadMetadata(for trackID: Track.ID, includeArtwork: Bool = false) {
        guard let url = playlist.first(where: { $0.id == trackID })?.url else { return }
        Task {
            guard !Task.isCancelled else { return }
            let meta = await Track.loadMetadata(from: url, includeArtwork: includeArtwork)
            guard !Task.isCancelled else { return }
            await self.applyMetadata(meta, to: trackID)
        }
    }

    private func loadMetadata(for tracks: [(id: Track.ID, url: URL)]) {
        metadataBatchTask?.cancel()
        guard !tracks.isEmpty else { return }
        metadataBatchTask = Task { [weak self] in
            await withTaskGroup(of: (Track.ID, Track.Metadata)?.self) { group in
                var iterator = tracks.makeIterator()
                for _ in 0..<4 {
                    guard let track = iterator.next() else { break }
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let metadata = await Track.loadMetadata(from: track.url, includeArtwork: false)
                        return Task.isCancelled ? nil : (track.id, metadata)
                    }
                }

                while let result = await group.next() {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    if let (trackID, metadata) = result {
                        await self?.applyMetadata(metadata, to: trackID)
                    }
                    if let track = iterator.next() {
                        group.addTask {
                            guard !Task.isCancelled else { return nil }
                            let metadata = await Track.loadMetadata(from: track.url, includeArtwork: false)
                            return Task.isCancelled ? nil : (track.id, metadata)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func applyMetadata(_ metadata: Track.Metadata, to trackID: Track.ID) {
        guard let index = playlist.firstIndex(where: { $0.id == trackID }) else { return }
        metadataLoadedIDs.insert(trackID)
        if let title = metadata.title, !title.isEmpty { playlist[index].title = title }
        if let artist = metadata.artist { playlist[index].artist = artist }
        playlist[index].duration = metadata.duration
        if let data = metadata.artworkData { playlist[index].artwork = NSImage(data: data) }
        if currentTrackID == trackID {
            if duration == 0 { duration = metadata.duration }
            updateNowPlayingInfo()
        }
    }

    // MARK: - 播放控制

    func play(trackID: Track.ID) {
        guard playlist.contains(where: { $0.id == trackID }) else { return }
        retryDeferredAccess()
        currentTrackID = trackID
        sidebarSelection = trackID
        loadMetadata(for: trackID, includeArtwork: true)
        loadCurrentTrack(playWhenReady: true)
    }

    private func loadCurrentTrack(playWhenReady: Bool) {
        guard let track = currentTrack else {
            stop()
            return
        }
        let wanted: PlaybackBackend = track.isVideo ? videoBackend : audioBackend
        player.unload()
        if wanted !== player {
            player = wanted
            player.rate = playbackRate
        }
        ambientEdgeColors = nil
        if !track.isVideo { clearWindowAspect() }
        do {
            try player.load(url: track.url)
            consecutiveLoadFailures = 0
        } catch {
            // 保留曲目上下文并明确报错，然后自动跳下一首（整列表都坏时停下防死循环）
            isPlaying = false
            cancelTranscription()
            lyricLines = []
            currentLineIndex = nil
            lyricsStatus = .failed("无法播放「\(track.title)」：文件已损坏或格式不受支持")
            consecutiveLoadFailures += 1
            if playWhenReady, consecutiveLoadFailures < playlist.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, self.currentTrackID == track.id else { return }
                    self.next()
                }
            }
            return
        }

        currentTime = 0
        duration = player.duration > 0 ? player.duration : track.duration

        if playWhenReady {
            player.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
        updateNowPlayingInfo()
        startLyricsPipeline(forceRecognize: false)
        startBeatGridAnalysis(for: track)
    }

    /// 后台预分析整首歌的拍点网格。
    private func startBeatGridAnalysis(for track: Track) {
        beatGridTask?.cancel()
        beatGrid = nil
        let trackID = track.id
        let url = track.url
        beatGridTask = Task {
            let grid = await BeatGrid.analyze(url: url)
            guard !Task.isCancelled, !grid.isEmpty else { return }
            await MainActor.run {
                guard self.currentTrackID == trackID else { return }
                self.beatGrid = grid
            }
        }
    }

    func togglePlayPause() {
        if currentTrack == nil {
            if let first = playlist.first { play(trackID: first.id) }
            return
        }
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard currentTrack != nil else { return }
        // 已经播到结尾：从头重播（seek 携带播放态，画面必定刷新）
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
        WindowChromeController.shared.noteActivity()
    }

    func stop() {
        beatGridTask?.cancel()
        beatGridTask = nil
        beatGrid = nil
        player.unload()
        isPlaying = false
        currentTime = 0
        duration = 0
        currentTrackID = nil
        cancelTranscription()
        lyricLines = []
        lyricsStatus = .idle
        currentLineIndex = nil
        updateNowPlayingInfo()
    }

    func next() {
        guard let index = currentIndex else { return }
        if shuffleEnabled, playlist.count > 1 {
            var candidate = index
            while candidate == index { candidate = Int.random(in: 0..<playlist.count) }
            play(trackID: playlist[candidate].id)
            return
        }
        let nextIndex = index + 1
        if nextIndex < playlist.count {
            play(trackID: playlist[nextIndex].id)
        } else if repeatMode == .all, let first = playlist.first {
            play(trackID: first.id)
        }
    }

    func previous() {
        // 播放超过 3 秒时回到开头，否则跳上一首（与“音乐”App 一致）
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard let index = currentIndex else { return }
        if index > 0 {
            play(trackID: playlist[index - 1].id)
        } else if repeatMode == .all, let last = playlist.last {
            play(trackID: last.id)
        } else {
            seek(to: 0)
        }
    }

    private var currentIndex: Int? {
        currentTrackID.flatMap { id in playlist.firstIndex { $0.id == id } }
    }

    private func handleTrackEnded() {
        switch repeatMode {
        case .one:
            seek(to: 0)
            resume()
        case .all:
            next()
        case .off:
            if let index = currentIndex, index + 1 < playlist.count {
                next()
            } else {
                pause()
                // 视频停在最后一帧（暂停态 seek 回 0 会触发 AVPlayer 黑屏怪癖）；
                // 音频回到开头便于重播
                if currentTrack?.isVideo != true {
                    seek(to: 0)
                }
            }
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.seek(to: clamped, resume: isPlaying)
        currentTime = clamped
        updateCurrentLine()
        updateNowPlayingInfo()
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func adjustVolume(by delta: Float) {
        volume = max(0, min(1, volume + delta))
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    /// 供逐词高亮使用的精确播放时间（不触发视图整体刷新）。
    func livePlaybackTime() -> Double {
        player.currentTime
    }

    // MARK: - 播放列表管理

    func remove(trackIDs: Set<Track.ID>) {
        guard !trackIDs.isEmpty else { return }
        if let currentID = currentTrackID, trackIDs.contains(currentID) {
            stop()
        }
        playlist.removeAll { trackIDs.contains($0.id) }
        metadataLoadedIDs.subtract(trackIDs)
        if let selection = sidebarSelection, trackIDs.contains(selection) {
            sidebarSelection = nil
        }
        securityAccess.reconcile(keeping: playlist.map(\.url) + pendingImportURLs)
        saveState()
    }

    func clearTranscriptCache() {
        let alert = NSAlert()
        alert.messageText = "清除识别缓存？"
        alert.informativeText = "本机保存的转写结果会被删除，之后播放时需要重新识别。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cacheGeneration &+= 1
        cancelTranscription()
        TranscriptCache.removeAll()
        if case .recognizing = lyricsStatus {
            lyricsStatus = lyricLines.isEmpty ? .idle : .done(.recognized)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        playlist.move(fromOffsets: source, toOffset: destination)
        saveState()
    }

    func revealInFinder(trackID: Track.ID) {
        retryDeferredAccess()
        guard let track = playlist.first(where: { $0.id == trackID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([track.url])
    }

    // MARK: - 歌词流水线

    private func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        onlineLyricsTask?.cancel()
        onlineLyricsTask = nil
        onlineRequestID = nil
        onlineUpgradeTask?.cancel()
        onlineUpgradeTask = nil
        onlineRetryTask?.cancel()
        onlineRetryTask = nil
    }

    /// 打开曲目后自动执行：LRC 文件 → 缓存 → 自动识别。
    func startLyricsPipeline(forceRecognize: Bool) {
        cancelTranscription()
        lyricLines = []
        currentLineIndex = nil
        lyricsStatus = .idle

        guard let track = currentTrack else { return }
        let variantID = "auto|\(AutoTranscriber.systemLocale().identifier)"

        if !forceRecognize {
            if let lrcLines = LRCFile.sidecarLines(for: track.url) {
                lyricLines = lrcLines
                lyricsStatus = .done(.lrcFile)
                updateCurrentLine()
                return
            }
            if let cached = TranscriptCache.load(for: track.url, localeID: variantID) {
                lyricLines = cached.lines
                lyricsStatus = .done(cached.source)
                updateCurrentLine()
                // 识别出的结果视为草稿：后台查在线歌词，命中则静默升级
                if cached.source == .recognized {
                    upgradeFromOnlineIfPossible(track: track, variantID: variantID)
                }
                return
            }
        } else {
            cacheGeneration &+= 1
            TranscriptCache.remove(for: track.url, localeID: variantID)
        }

        recognize(track: track, variantID: variantID, cacheGeneration: cacheGeneration)
    }

    private func fetchOnlineLyrics(title: String, artist: String, duration: Double) async
        -> OnlineLyrics.FetchResult? {
        let consent = onlineConsentGeneration
        guard allowOnlineLyrics else { return nil }
        let requestID = UUID()
        let task = Task {
            await OnlineLyrics.fetch(title: title, artist: artist, duration: duration)
        }
        onlineLyricsTask?.cancel()
        onlineLyricsTask = task
        onlineRequestID = requestID
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if onlineRequestID == requestID {
            onlineLyricsTask = nil
            onlineRequestID = nil
        }
        guard !Task.isCancelled, allowOnlineLyrics,
              onlineConsentGeneration == consent else { return nil }
        return result
    }

    /// 缓存里是识别结果时，静默尝试用在线歌词升级替换。
    private func upgradeFromOnlineIfPossible(track: Track, variantID: String,
                                             cacheGeneration: Int? = nil) {
        guard allowOnlineLyrics else { return }
        let trackID = track.id
        let url = track.url
        let expectedCacheGeneration = cacheGeneration ?? self.cacheGeneration
        onlineUpgradeTask?.cancel()
        onlineUpgradeTask = Task { [weak self] in
            guard let self else { return }
            let meta = await Track.loadMetadata(from: url)
            guard !Task.isCancelled, self.allowOnlineLyrics else { return }
            guard let title = meta.title, !title.isEmpty else { return }
            guard case .synced(let online)? = await self.fetchOnlineLyrics(
                title: title, artist: meta.artist ?? "", duration: meta.duration
            ) else { return }
            await MainActor.run {
                guard self.currentTrackID == trackID,
                      self.cacheGeneration == expectedCacheGeneration else { return }
                self.lyricLines = online
                self.lyricsStatus = .done(.online)
                TranscriptCache.save(lines: online, source: .online, for: url, localeID: variantID)
                self.updateCurrentLine()
            }
        }
    }

    private func recognize(track: Track, variantID: String, cacheGeneration expectedCacheGeneration: Int) {
        lyricsStatus = .recognizing(fraction: nil, message: nil)
        let trackID = track.id
        let url = track.url

        transcriptionTask = Task {
            if self.allowOnlineLyrics {
                // 在线查询只使用文件内元数据；本地文件名不会发送给第三方。
                let meta = await Track.loadMetadata(from: url)
                if Task.isCancelled { return }
                if self.allowOnlineLyrics, let title = meta.title, !title.isEmpty,
                   let result = await self.fetchOnlineLyrics(title: title,
                                                             artist: meta.artist ?? "",
                                                             duration: meta.duration) {
                    await MainActor.run {
                        guard self.currentTrackID == trackID,
                              self.cacheGeneration == expectedCacheGeneration else { return }
                        switch result {
                        case .synced(let online):
                            self.lyricLines = online
                            self.lyricsStatus = .done(.online)
                            TranscriptCache.save(lines: online, source: .online, for: url, localeID: variantID)
                        case .instrumental:
                            // 曲库确认是纯音乐：不再浪费算力识别，写入否定缓存
                            self.lyricLines = []
                            self.lyricsStatus = .done(.online)
                            TranscriptCache.save(lines: [], source: .online, for: url, localeID: variantID)
                        }
                        self.updateCurrentLine()
                    }
                    return
                }
            }
            if Task.isCancelled { return }

            do {
                let lines = try await AutoTranscriber.transcribe(url: url) { snapshot in
                    Task { @MainActor in
                        guard self.currentTrackID == trackID,
                              self.cacheGeneration == expectedCacheGeneration else { return }
                        // 限频：行数和文案都没变化时，至多每 0.25 秒应用一次
                        let now = Date()
                        let significant = snapshot.lines.count != self.lyricLines.count
                            || snapshot.message != self.lastSnapshotMessage
                            || now.timeIntervalSince(self.lastSnapshotAt) >= 0.25
                        guard significant else { return }
                        self.lastSnapshotAt = now
                        self.lastSnapshotMessage = snapshot.message
                        self.lyricLines = snapshot.lines
                        self.lyricsStatus = .recognizing(fraction: snapshot.fraction, message: snapshot.message)
                        self.updateCurrentLine()
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.currentTrackID == trackID,
                          self.cacheGeneration == expectedCacheGeneration else { return }
                    self.lyricLines = lines
                    if lines.isEmpty {
                        self.lyricsStatus = .failed("未在音频中识别到语音内容")
                        // 否定缓存：纯音乐/无人声文件不再每次重跑识别
                        TranscriptCache.save(lines: [], source: .recognized, for: url, localeID: variantID)
                    } else {
                        self.lyricsStatus = .done(.recognized)
                        TranscriptCache.save(lines: lines, source: .recognized, for: url, localeID: variantID)
                        // 在线歌词库时通时不通：稍后在本次会话内自动重试升级
                        self.onlineRetryTask?.cancel()
                        self.onlineRetryTask = Task { [weak self] in
                            try? await Task.sleep(for: .seconds(90))
                            guard let self, !Task.isCancelled,
                                  self.currentTrackID == trackID,
                                  self.cacheGeneration == expectedCacheGeneration else { return }
                            self.upgradeFromOnlineIfPossible(track: track, variantID: variantID,
                                                             cacheGeneration: expectedCacheGeneration)
                        }
                    }
                    self.updateCurrentLine()
                }
            } catch is CancellationError {
                // 切歌导致的取消，忽略
            } catch {
                await MainActor.run {
                    guard self.currentTrackID == trackID else { return }
                    self.lyricsStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func updateCurrentLine() {
        guard !lyricLines.isEmpty else {
            if currentLineIndex != nil { currentLineIndex = nil }
            return
        }
        let t = currentTime + 0.05
        var newIndex: Int?
        var low = 0, high = lyricLines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if lyricLines[mid].start <= t {
                newIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
        }
    }

    // MARK: - 窗口与视频宽高比绑定（QuickTime 式）

    @ObservationIgnored private var pendingAspect: CGSize?

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.titled) && $0.title != "实时字幕" && $0.isVisible }
    }

    /// 窗口就绪后补挂（启动恢复时视频尺寸可能先于窗口到达）。
    func flushPendingAspectIfNeeded() {
        if let size = pendingAspect { applyWindowAspect(size) }
    }

    /// 视频尺寸就绪后：窗口贴合视频宽高比，且缩放时锁定比例（黑边消失）。
    private func applyWindowAspect(_ size: CGSize) {
        guard size.width > 0, size.height > 0, currentTrack?.isVideo == true else { return }
        guard let window = mainWindow, !window.styleMask.contains(.fullScreen) else {
            pendingAspect = size   // 窗口未就绪：挂起，出现后补挂
            return
        }
        pendingAspect = nil
        window.contentAspectRatio = size

        let aspect = size.width / size.height
        var frame = window.frame
        var width = frame.width
        var height = width / aspect
        if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            if height > visible.height { height = visible.height; width = height * aspect }
            if width > visible.width { width = visible.width; height = width / aspect }
        }
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: true, animate: true)
    }

    private func clearWindowAspect() {
        pendingAspect = nil
        mainWindow?.contentAspectRatio = .zero
    }

    // MARK: - 导出

    func exportLRC() {
        guard let track = currentTrack, !lyricLines.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText]
        panel.nameFieldStringValue = track.title + ".lrc"
        panel.title = "导出歌词"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = LRCFile.export(lines: lyricLines, title: track.title, artist: track.artist)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 系统“正在播放”与媒体键

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.resume(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous(); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0.0,
        ]
        if let artwork = track.artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}

// MARK: - 播放状态持久化

/// 退出后恢复：播放列表、当前曲目、进度、循环/随机/倍速/歌词开关。
private struct PersistedState: Codable, Sendable {
    var paths: [String]
    var accessBookmarks: [Data]?
    var accessGrants: [SecurityScopedBookmark]?
    var currentPath: String?
    var position: Double
    var repeatMode: String
    var shuffle: Bool
    var rate: Float
    var showLyrics: Bool
}

extension PlayerModel {
    private static let stateKey = "playerState.v1"

    func saveState() {
        let urls = playlist.map(\.url)
        let activeGrants = securityAccess.bookmarks(covering: urls)
        let activePaths = Set(activeGrants.map(\.path))
        let exactPaths = Set(urls.map { $0.standardizedFileURL.path })
        let ancestorPaths = Self.ancestorPaths(for: urls)
        deferredAccessGrants = deferredAccessGrants.filter { grant in
            let path = URL(fileURLWithPath: grant.path, isDirectory: grant.isDirectory).standardizedFileURL.path
            let needed = grant.isDirectory ? ancestorPaths.contains(path) : exactPaths.contains(path)
            return !activePaths.contains(path) && needed
        }
        if urls.isEmpty {
            deferredLegacyBookmarks = []
        }
        var grantsByPath: [String: SecurityScopedBookmark] = [:]
        for grant in deferredAccessGrants { grantsByPath[grant.path] = grant }
        for grant in activeGrants { grantsByPath[grant.path] = grant }
        let grants = grantsByPath.values.sorted { $0.path < $1.path }
        let state = PersistedState(paths: urls.map(\.path),
                                   accessBookmarks: deferredLegacyBookmarks.isEmpty ? nil : deferredLegacyBookmarks,
                                   accessGrants: grants.isEmpty ? nil : grants,
                                   currentPath: currentTrack?.url.path,
                                   position: currentTime,
                                   repeatMode: repeatMode.rawValue,
                                   shuffle: shuffleEnabled,
                                   rate: playbackRate,
                                   showLyrics: showLyrics)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }

    /// 启动时恢复上次的播放列表与进度（不自动播放）。
    func restoreState() {
        guard playlist.isEmpty,
              let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }

        let grants = state.accessGrants ?? []
        let legacyBookmarks = state.accessBookmarks ?? []
        let savedURLs = state.paths.map { URL(fileURLWithPath: $0) }
        let supportedURLs = savedURLs.filter(Track.isMediaFile)
        let unsupportedCount = savedURLs.count - supportedURLs.count
        if unsupportedCount > 0 {
            let alert = NSAlert()
            alert.messageText = "有曲目不再支持"
            alert.informativeText = "已从旧播放列表中移除 \(unsupportedCount) 个非系统原生格式文件。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
        guard !supportedURLs.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.stateKey)
            return
        }

        if !grants.isEmpty {
            let restoration = securityAccess.restore(grants)
            deferredAccessGrants = restoration.preserved
            let restoredURLs = Self.remap(supportedURLs, using: restoration.scopes)
            applyRestoredState(state, urls: restoredURLs)
        } else if !legacyBookmarks.isEmpty {
            _ = securityAccess.restoreLegacy(legacyBookmarks)
            deferredLegacyBookmarks = legacyBookmarks
            applyRestoredState(state, urls: supportedURLs)
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = Track.supportedContentTypes
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = true
            panel.message = "Echo Player 现在使用沙盒保护文件。请选择原来的媒体文件或所在文件夹，以恢复播放列表。"
            panel.prompt = "恢复"
            panel.directoryURL = supportedURLs[0].deletingLastPathComponent()
            guard panel.runModal() == .OK else { return }
            let selections = panel.urls
            securityAccess.adopt(selections)
            let worker = Task.detached(priority: .userInitiated) {
                Self.expandMediaURLs(selections)
            }
            restorationTask = Task { @MainActor [weak self] in
                let expansion = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, !Task.isCancelled else { return }
                self.finishLegacyMigration(state, savedURLs: supportedURLs,
                                           selections: selections, discovered: expansion.urls)
            }
        }
    }

    @MainActor
    private func finishLegacyMigration(_ state: PersistedState, savedURLs: [URL],
                                       selections: [URL], discovered: [URL]) {
        restorationTask = nil
        let remapped = Self.remapLegacyURLs(savedURLs, selections: selections, discovered: discovered)
        let available = remapped.filter { FileManager.default.fileExists(atPath: $0.path) }
        if available.count != savedURLs.count {
            let alert = NSAlert()
            alert.messageText = "播放列表未完整恢复"
            alert.informativeText = "仍有 \(savedURLs.count - available.count) 个文件未获得访问权限或已被移动。"
            alert.addButton(withTitle: "稍后再试")
            alert.addButton(withTitle: "移除未恢复项")
            guard alert.runModal() == .alertSecondButtonReturn else {
                securityAccess.reconcile(keeping: [])
                return
            }
        }
        guard !available.isEmpty else {
            securityAccess.reconcile(keeping: [])
            UserDefaults.standard.removeObject(forKey: Self.stateKey)
            return
        }
        applyRestoredState(state, urls: available)
    }

    private func applyRestoredState(_ state: PersistedState, urls: [URL]) {
        var seen: Set<URL> = []
        let unique = urls.filter { seen.insert($0.standardizedFileURL).inserted }

        repeatMode = RepeatMode(rawValue: state.repeatMode) ?? .off
        shuffleEnabled = state.shuffle
        playbackRate = state.rate
        showLyrics = state.showLyrics

        var restored: [(id: Track.ID, url: URL)] = []
        for url in unique {
            let track = Track(url: url)
            playlist.append(track)
            if FileManager.default.fileExists(atPath: url.path) {
                restored.append((track.id, track.url))
            }
        }
        loadMetadata(for: restored)
        securityAccess.reconcile(keeping: playlist.map(\.url))
        saveState()
        // 有意不恢复上次的曲目/画面：启动永远是干净的"拖拽以播放"空态，
        // 播放列表在侧栏待命，点一下即从头开始。
    }

    private func retryDeferredAccess() {
        guard !deferredAccessGrants.isEmpty else { return }
        let restoration = securityAccess.restore(deferredAccessGrants)
        deferredAccessGrants = restoration.preserved
        guard !restoration.scopes.isEmpty else { return }
        let remapped = Self.remap(playlist.map(\.url), using: restoration.scopes)
        for index in playlist.indices {
            playlist[index].url = remapped[index]
        }
        securityAccess.reconcile(keeping: playlist.map(\.url))
        saveState()
    }

    private static func remapLegacyURLs(_ urls: [URL], selections: [URL],
                                        discovered: [URL]) -> [URL] {
        let manager = FileManager.default
        let missing = urls.filter { !manager.fileExists(atPath: $0.path) }
        let directFiles = selections.filter { selection in
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: selection.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        let directories = selections.filter { selection in
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: selection.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let commonRoot = commonDirectory(for: urls)
        var directPairs: [URL: URL] = [:]
        if directFiles.count == missing.count {
            for (old, new) in zip(missing, directFiles) { directPairs[old] = new }
        }
        let discoveredByName = Dictionary(grouping: discovered, by: \.lastPathComponent)
        var used: Set<URL> = []

        return urls.map { old in
            if manager.fileExists(atPath: old.path) {
                used.insert(old.standardizedFileURL)
                return old
            }
            let sameNameDirect = directFiles.first {
                !used.contains($0.standardizedFileURL) && $0.lastPathComponent == old.lastPathComponent
            }
            if let sameNameDirect {
                used.insert(sameNameDirect.standardizedFileURL)
                return sameNameDirect
            }
            if let commonRoot,
               old.pathComponents.starts(with: commonRoot.pathComponents) {
                let suffix = old.pathComponents.dropFirst(commonRoot.pathComponents.count)
                for directory in directories {
                    let candidate = suffix.reduce(directory) { $0.appendingPathComponent($1) }
                    if manager.fileExists(atPath: candidate.path),
                       used.insert(candidate.standardizedFileURL).inserted {
                        return candidate
                    }
                }
            }
            let candidates = (discoveredByName[old.lastPathComponent] ?? []).filter {
                !used.contains($0.standardizedFileURL) && $0.lastPathComponent == old.lastPathComponent
            }
            if let best = candidates.max(by: {
                commonSuffixCount($0.deletingLastPathComponent(), old.deletingLastPathComponent())
                    < commonSuffixCount($1.deletingLastPathComponent(), old.deletingLastPathComponent())
            }) {
                used.insert(best.standardizedFileURL)
                return best
            }
            if let direct = directPairs[old], used.insert(direct.standardizedFileURL).inserted {
                return direct
            }
            return old
        }
    }

    private static func remap(_ urls: [URL], using scopes: [RestoredSecurityScope]) -> [URL] {
        var files: [String: RestoredSecurityScope] = [:]
        var directories: [String: RestoredSecurityScope] = [:]
        for scope in scopes {
            let path = scope.originalURL.standardizedFileURL.path
            if scope.isDirectory {
                directories[path] = scope
            } else {
                files[path] = scope
            }
        }
        return urls.map { url in
            let target = url.standardizedFileURL
            if let scope = files[target.path] { return scope.resolvedURL }
            var match: RestoredSecurityScope?
            let components = target.pathComponents
            for count in 1...components.count {
                let path = NSString.path(withComponents: Array(components.prefix(count)))
                if let scope = directories[path] { match = scope }
            }
            return match?.remap(target) ?? target
        }
    }

    private static func ancestorPaths(for urls: [URL]) -> Set<String> {
        var result: Set<String> = []
        for url in urls {
            let components = url.standardizedFileURL.pathComponents
            for count in 1...components.count {
                result.insert(NSString.path(withComponents: Array(components.prefix(count))))
            }
        }
        return result
    }

    private static func commonDirectory(for urls: [URL]) -> URL? {
        guard var components = urls.first?.deletingLastPathComponent().pathComponents else { return nil }
        for url in urls.dropFirst() {
            let other = url.deletingLastPathComponent().pathComponents
            while !other.starts(with: components), !components.isEmpty { components.removeLast() }
        }
        guard !components.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: components), isDirectory: true)
    }

    private static func commonSuffixCount(_ lhs: URL, _ rhs: URL) -> Int {
        zip(lhs.pathComponents.reversed(), rhs.pathComponents.reversed())
            .prefix { $0.0 == $0.1 }.count
    }

    func prepareForTermination() {
        importTask?.cancel()
        if let restorationTask {
            restorationTask.cancel()
            self.restorationTask = nil
            securityAccess.reconcile(keeping: [])
            return
        }
        pendingImportURLs = []
        securityAccess.reconcile(keeping: playlist.map(\.url))
        saveState()
    }
}

// MARK: - 时间格式化

enum TimeFormatter {
    static func string(from seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
