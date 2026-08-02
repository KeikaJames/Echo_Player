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

@Observable
final class PlayerModel {
    static let shared = PlayerModel()

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
            ffmpegBackend.volume = volume
            UserDefaults.standard.set(volume, forKey: "playerVolume")
        }
    }

    var playbackRate: Float = 1.0 {
        didSet {
            audioBackend.rate = playbackRate
            videoBackend.rate = playbackRate
            ffmpegBackend.rate = playbackRate
            updateNowPlayingInfo()
        }
    }

    /// 当前曲目是「AVFoundation 原生视频」时，供画面渲染层使用的 AVPlayer。
    /// FFmpeg 后端的视频（mkv/webm/flv/avi/ts）不走这里，画面由 ffmpegPlayerView 提供。
    var videoPlayer: AVPlayer? {
        guard let track = currentTrack, track.isVideo, !track.needsFFmpeg else { return nil }
        return videoBackend.player
    }

    /// 当前曲目是「FFmpeg 视频」时，KSPlayer 自带的画面渲染 NSView。
    var ffmpegPlayerView: NSView? {
        guard let track = currentTrack, track.isVideo, track.needsFFmpeg else { return nil }
        return ffmpegBackend.playerView
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
    // FFmpeg（KSPlayer）后端：mkv/webm/ogg/opus/ape/wma/flv/avi/ts 等 AVFoundation 打不开的格式
    @ObservationIgnored private let ffmpegBackend = FFmpegBackend()
    @ObservationIgnored private var player: PlaybackBackend
    @ObservationIgnored private var consecutiveLoadFailures = 0
    @ObservationIgnored private var displayTimer: Timer?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
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
        ffmpegBackend.volume = volume
        let endHandler: () -> Void = { [weak self] in
            self?.handleTrackEnded()
        }
        audioBackend.onTrackEnd = endHandler
        videoBackend.onTrackEnd = endHandler
        ffmpegBackend.onTrackEnd = endHandler
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
            // 兜底时长：FFmpeg 后端的 duration 在异步 readyToPlay 后才可用，
            // load 时读到的是 0——这里发现后端已给出有效时长时补上，进度条才有终点
            let backendDuration = self.player.duration
            if backendDuration > 0, abs(backendDuration - self.duration) > 0.5 {
                self.duration = backendDuration
                self.updateNowPlayingInfo()
            }
            ticks += 1
            if ticks % 50 == 0, self.isPlaying {   // 每 5 秒持久化一次进度
                self.saveState()
            }
            // 原生视频控制条可直接操作 AVPlayer：把播放态同步回模型
            if self.isPlaying != self.player.isPlaying {
                self.isPlaying = self.player.isPlaying
                self.updateNowPlayingInfo()
            }
            // 视频氛围光：每 0.3 秒采样一次画面边缘色（仅 AVFoundation 原生视频有取样能力）
            if ticks % 3 == 0 {
                let sampleable = self.currentTrack?.isVideo == true && self.currentTrack?.needsFFmpeg != true
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
        panel.allowedContentTypes = [.audio, .movie]
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
        let expanded = Self.expandAudioURLs(urls)
        guard !expanded.isEmpty else { return }

        let existing = Set(playlist.map { $0.url.standardizedFileURL })
        var firstNewID: Track.ID?
        for url in expanded where !existing.contains(url.standardizedFileURL) {
            let track = Track(url: url)
            playlist.append(track)
            if firstNewID == nil { firstNewID = track.id }
            loadMetadata(for: track.id)
        }

        defer { saveState() }
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

    private static func expandAudioURLs(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles])
                var found: [URL] = []
                while let child = enumerator?.nextObject() as? URL {
                    if Track.isMediaFile(child) { found.append(child) }
                }
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                result.append(contentsOf: found)
            } else if Track.isMediaFile(url) {
                result.append(url)
            }
        }
        return result
    }

    private func loadMetadata(for trackID: Track.ID) {
        guard let url = playlist.first(where: { $0.id == trackID })?.url else { return }
        Task {
            let meta = await Track.loadMetadata(from: url)
            await MainActor.run {
                guard let index = self.playlist.firstIndex(where: { $0.id == trackID }) else { return }
                if let title = meta.title, !title.isEmpty { self.playlist[index].title = title }
                if let artist = meta.artist { self.playlist[index].artist = artist }
                self.playlist[index].duration = meta.duration
                if let data = meta.artworkData { self.playlist[index].artwork = NSImage(data: data) }
                if self.currentTrackID == trackID {
                    if self.duration == 0 { self.duration = meta.duration }
                    self.updateNowPlayingInfo()
                }
            }
        }
    }

    // MARK: - 播放控制

    func play(trackID: Track.ID) {
        guard playlist.contains(where: { $0.id == trackID }) else { return }
        currentTrackID = trackID
        sidebarSelection = trackID
        loadCurrentTrack(playWhenReady: true)
    }

    private func loadCurrentTrack(playWhenReady: Bool) {
        guard let track = currentTrack else {
            stop()
            return
        }
        // 三分支：AVFoundation 打不开的格式走 FFmpeg，原生视频走 AVPlayer，其余音频走 AVAudioEngine
        let wanted: PlaybackBackend
        if track.needsFFmpeg {
            wanted = ffmpegBackend
        } else if track.isVideo {
            wanted = videoBackend
        } else {
            wanted = audioBackend
        }
        if wanted !== player {
            player.unload()
            player = wanted
            player.rate = playbackRate
        }
        ambientEdgeColors = nil
        // FFmpeg 视频不上报自然尺寸，也没有氛围光采样，沿用纯黑底，不做窗口比例绑定
        if !track.isVideo || track.needsFFmpeg { clearWindowAspect() }
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
        saveState()
        WindowChromeController.shared.noteActivity()
    }

    func stop() {
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
        if let selection = sidebarSelection, trackIDs.contains(selection) {
            sidebarSelection = nil
        }
        saveState()
    }

    func move(from source: IndexSet, to destination: Int) {
        playlist.move(fromOffsets: source, toOffset: destination)
        saveState()
    }

    func revealInFinder(trackID: Track.ID) {
        guard let track = playlist.first(where: { $0.id == trackID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([track.url])
    }

    // MARK: - 歌词流水线

    private func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
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
            TranscriptCache.remove(for: track.url, localeID: variantID)
        }

        recognize(track: track, variantID: variantID)
    }

    /// 缓存里是识别结果时，静默尝试用在线歌词升级替换。
    private func upgradeFromOnlineIfPossible(track: Track, variantID: String) {
        let trackID = track.id
        let url = track.url
        Task {
            let meta = await Track.loadMetadata(from: url)
            let title = meta.title ?? url.deletingPathExtension().lastPathComponent
            guard case .synced(let online)? = await OnlineLyrics.fetch(title: title,
                                                                       artist: meta.artist ?? "",
                                                                       duration: meta.duration) else { return }
            await MainActor.run {
                guard self.currentTrackID == trackID else { return }
                self.lyricLines = online
                self.lyricsStatus = .done(.online)
                TranscriptCache.save(lines: online, source: .online, for: url, localeID: variantID)
                self.updateCurrentLine()
            }
        }
    }

    private func recognize(track: Track, variantID: String) {
        lyricsStatus = .recognizing(fraction: nil, message: nil)
        let trackID = track.id
        let url = track.url

        transcriptionTask = Task {
            // 第一优先：在线歌词库（秒出、准确），识别模型只做兜底
            let meta = await Track.loadMetadata(from: url)
            if Task.isCancelled { return }
            let title = meta.title ?? url.deletingPathExtension().lastPathComponent
            if let result = await OnlineLyrics.fetch(title: title,
                                                     artist: meta.artist ?? "",
                                                     duration: meta.duration) {
                await MainActor.run {
                    guard self.currentTrackID == trackID else { return }
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
            if Task.isCancelled { return }

            do {
                let lines = try await AutoTranscriber.transcribe(url: url) { snapshot in
                    Task { @MainActor in
                        guard self.currentTrackID == trackID else { return }
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
                    guard self.currentTrackID == trackID else { return }
                    self.lyricLines = lines
                    if lines.isEmpty {
                        self.lyricsStatus = .failed("未在音频中识别到语音内容")
                        // 否定缓存：纯音乐/无人声文件不再每次重跑识别
                        TranscriptCache.save(lines: [], source: .recognized, for: url, localeID: variantID)
                    } else {
                        self.lyricsStatus = .done(.recognized)
                        TranscriptCache.save(lines: lines, source: .recognized, for: url, localeID: variantID)
                        // 在线歌词库时通时不通：稍后在本次会话内自动重试升级
                        Task {
                            try? await Task.sleep(for: .seconds(90))
                            guard self.currentTrackID == trackID else { return }
                            self.upgradeFromOnlineIfPossible(track: track, variantID: variantID)
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
private struct PersistedState: Codable {
    var paths: [String]
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
        let state = PersistedState(paths: playlist.map { $0.url.path },
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

        let existing = state.paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }

        repeatMode = RepeatMode(rawValue: state.repeatMode) ?? .off
        shuffleEnabled = state.shuffle
        playbackRate = state.rate
        showLyrics = state.showLyrics

        for path in existing {
            let track = Track(url: URL(fileURLWithPath: path))
            playlist.append(track)
            loadMetadata(for: track.id)
        }
        // 有意不恢复上次的曲目/画面：启动永远是干净的"拖拽以播放"空态，
        // 播放列表在侧栏待命，点一下即从头开始。
    }
}

// MARK: - 时间格式化

enum TimeFormatter {
    static func string(from seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
