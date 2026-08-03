import Foundation
import AVFoundation
import AppKit
import CoreImage
import KSPlayer

struct PlaybackAudioTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
    let languageCode: String?
    let isSelected: Bool

    var displayName: String {
        guard let languageCode, !languageCode.isEmpty,
              !name.localizedCaseInsensitiveContains(languageCode) else { return name }
        return "\(name) · \(languageCode)"
    }
}

/// 基于 KSPlayer（FFmpeg 软解）的播放后端。
///
/// AVFoundation 无法解码的容器/编码（mkv / webm / ogg / oga / opus / ape / wma /
/// flv / avi / ts 等）统一走这里：内部用 `KSMEPlayer`，画面由它自带的
/// 视频输出 `NSView` 渲染（见 `playerView`）。
///
/// 注意：`KSOptions` 的若干静态配置项（isAutoPlay / isSecondOpen 等）非 public，
/// 不要设置；这里只用默认 `KSOptions()`，播放时机完全由本类通过 play()/pause() 控制。
///
/// 本类刻意**不加类级 @MainActor**：与 `EnginePlayer`/`VideoBackend` 一样是非隔离后端，
/// 由 `PlayerModel`（非隔离）在主线程驱动。仅 `MediaPlayerDelegate`（协议本身标了
/// @MainActor）的几个方法逐个标注 @MainActor 以满足一致性——Swift 5 语言模式下这只会
/// 产生隔离 warning，不影响编译。
final class FFmpegBackend: NSObject, PlaybackBackend {
    // MARK: - PlaybackBackend

    private(set) var duration: Double = 0

    var currentTime: Double {
        if let pendingSeek { return pendingSeek.seconds }
        if let activeSeek { return activeSeek.seconds }
        guard let player else { return 0 }
        let t = player.currentPlaybackTime
        return t.isFinite ? max(0, t) : 0
    }

    var isPlaying: Bool {
        (activeSeek?.resume ?? false) || (!isReady && playWhenReady) || (player?.isPlaying ?? false)
    }

    var rate: Float = 1.0 {
        didSet { player?.playbackRate = max(0.25, min(4, rate)) }
    }

    var volume: Float = 0.8 {
        didSet {
            if let player { applyPlaybackVolume(to: player) }
        }
    }

    var onTrackEnd: (() -> Void)?
    var onPlaybackError: ((Error) -> Void)?
    var onAudioTracksChange: (([PlaybackAudioTrack]) -> Void)?
    var onAudioTrackChange: ((Int32) -> Void)?

    // MARK: - 私有状态

    private var player: KSMEPlayer?
    /// 就绪后是否自动开播（load 时 play() 早于 readyToPlay，需在回调里补触发）。
    private var playWhenReady = false
    /// 已收到 readyToPlay：此后 play()/pause() 可直接作用于底层播放器。
    private var isReady = false
    private var wantsPlayback = false
    /// opening 阶段 KSPlayer 不保存 seek，先由外层记住最后一次目标。
    private var pendingSeek: (seconds: Double, resume: Bool, generation: UInt64)?
    /// ready 后仍在途的 seek；play/pause 可覆盖它最初捕获的恢复意图。
    private var activeSeek: (seconds: Double, generation: UInt64, resume: Bool)?
    private var seekGeneration: UInt64 = 0
    private(set) var selectedAudioStreamIndex: Int32?
    private var playbackWatchdog: DispatchSourceTimer?
    private var watchdogGeneration: UInt64 = 0
    private var watchdogLastTime = 0.0
    private var watchdogOpeningTicks = 0
    private var watchdogSeekTicks = 0
    private var watchdogStalledTicks = 0
    private var preferredAudioTrackOrdinal: Int?
    private var didReportPlaybackError = false
    private let detectorLock = NSLock()
    private var detector: BeatDetector?
    private weak var meteredAudioOutput: AudioEnginePlayer?
    private var meterTapInstalled = false
    private var audioConfigurationObserver: NSObjectProtocol?
    private let edgeColorQueue = DispatchQueue(label: "EchoPlayer.FFmpegEdgeColor", qos: .utility)
    private var softwareEdgeColors: [NSColor]?
    private var softwareEdgeSamplePending = false
    private var lastSoftwareEdgeSampleTime = -Double.greatestFiniteMagnitude
    private var edgeColorGeneration: UInt = 0

    /// 供画面渲染层挂载的原生视图（KSMEPlayer 的视频输出）。
    var playerView: NSView? { player?.view }

    // MARK: - 加载 / 播放控制

    func load(url: URL) throws {
        unload()
        let options = KSOptions()   // 静态项非 public，保持默认
        let me = KSMEPlayer(url: url, options: options)
        me.delegate = self
        applyPlaybackSettings(to: me)
        player = me
        duration = 0
        isReady = false
        playWhenReady = false
        wantsPlayback = false
        seekGeneration &+= 1
        pendingSeek = nil
        activeSeek = nil
        selectedAudioStreamIndex = nil
        preferredAudioTrackOrdinal = nil
        didReportPlaybackError = false
        startPlaybackWatchdog(for: me)
        me.prepareToPlay()
    }

    func unload() {
        stopPlaybackWatchdog()
        uninstallMeterTap()
        edgeColorGeneration &+= 1
        softwareEdgeColors = nil
        lastSoftwareEdgeSampleTime = -Double.greatestFiniteMagnitude
        player?.delegate = nil
        player?.shutdown()
        player = nil
        duration = 0
        isReady = false
        playWhenReady = false
        wantsPlayback = false
        seekGeneration &+= 1
        pendingSeek = nil
        activeSeek = nil
        selectedAudioStreamIndex = nil
        preferredAudioTrackOrdinal = nil
        onAudioTracksChange?([])
        didReportPlaybackError = false
    }

    func play() {
        guard let player else { return }
        wantsPlayback = true
        // 尚未就绪：记下意图，readyToPlay 到达后再开播
        guard isReady else {
            playWhenReady = true
            if let pendingSeek {
                self.pendingSeek = (pendingSeek.seconds, true, pendingSeek.generation)
            }
            return
        }
        if let activeSeek {
            self.activeSeek = (activeSeek.seconds, activeSeek.generation, true)
        }
        player.play()
    }

    func pause() {
        wantsPlayback = false
        playWhenReady = false
        if !isReady, let pendingSeek {
            self.pendingSeek = (pendingSeek.seconds, false, pendingSeek.generation)
        }
        if let activeSeek {
            self.activeSeek = (activeSeek.seconds, activeSeek.generation, false)
        }
        player?.pause()
    }

    func seek(to seconds: Double, resume: Bool) {
        guard let player else { return }
        let target = max(0, seconds)
        wantsPlayback = resume
        seekGeneration &+= 1
        let generation = seekGeneration
        guard isReady else {
            pendingSeek = (target, resume, generation)
            playWhenReady = resume
            return
        }
        performSeek(to: target, resume: resume, generation: generation, player: player)
    }

    private func performSeek(to target: Double, resume: Bool,
                             generation: UInt64, player: KSMEPlayer) {
        watchdogLastTime = target
        watchdogSeekTicks = 0
        watchdogStalledTicks = 0
        activeSeek = (target, generation, resume)
        player.seek(time: target) { [weak self] _ in
            // KSPlayer 的 seek 回调可能不在主线程：统一回主线程恢复播放态
            Task { @MainActor in
                guard let self, self.player === player,
                      self.seekGeneration == generation else { return }
                let shouldResume = self.activeSeek?.generation == generation
                    ? self.activeSeek?.resume ?? resume
                    : resume
                self.activeSeek = nil
                self.watchdogSeekTicks = 0
                if shouldResume {
                    self.play()
                } else {
                    player.pause()
                }
            }
        }
    }

    private func startPlaybackWatchdog(for player: KSMEPlayer) {
        stopPlaybackWatchdog()
        watchdogGeneration &+= 1
        let generation = watchdogGeneration
        watchdogLastTime = 0
        watchdogOpeningTicks = 0
        watchdogSeekTicks = 0
        watchdogStalledTicks = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self, weak player] in
            guard let self, let player,
                  self.watchdogGeneration == generation,
                  self.player === player,
                  !self.didReportPlaybackError else { return }

            guard self.isReady else {
                self.watchdogOpeningTicks += 1
                if self.watchdogOpeningTicks >= 60 {
                    self.reportPlaybackError(FFmpegBackendError.openingTimedOut, for: player)
                }
                return
            }
            self.watchdogOpeningTicks = 0
            if self.activeSeek != nil {
                self.watchdogSeekTicks += 1
                if self.watchdogSeekTicks >= 30 {
                    self.reportPlaybackError(FFmpegBackendError.seekTimedOut, for: player)
                }
                return
            }
            self.watchdogSeekTicks = 0
            guard self.wantsPlayback,
                  self.pendingSeek == nil else {
                self.watchdogLastTime = player.currentPlaybackTime
                self.watchdogStalledTicks = 0
                return
            }
            let current = player.currentPlaybackTime
            if current.isFinite, current > self.watchdogLastTime + 0.01 {
                self.watchdogLastTime = current
                self.watchdogStalledTicks = 0
            } else if !current.isFinite || self.duration <= 0 || current < self.duration - 0.5 {
                self.watchdogStalledTicks += 1
                if self.watchdogStalledTicks >= 15 {
                    self.reportPlaybackError(FFmpegBackendError.decoderStalled, for: player)
                }
            }
        }
        playbackWatchdog = timer
        timer.resume()
    }

    private func stopPlaybackWatchdog() {
        watchdogGeneration &+= 1
        playbackWatchdog?.cancel()
        playbackWatchdog = nil
        watchdogOpeningTicks = 0
        watchdogSeekTicks = 0
        watchdogStalledTicks = 0
    }

    private func reportPlaybackError(_ error: Error, for player: KSMEPlayer) {
        guard self.player === player, !didReportPlaybackError else { return }
        didReportPlaybackError = true
        wantsPlayback = false
        stopPlaybackWatchdog()
        onPlaybackError?(error)
    }

    func audioLevel() -> Float {
        detectorLock.lock()
        defer { detectorLock.unlock() }
        guard let detector else { return 0 }
        if !isPlaying { detector.decayWhilePaused() }
        return detector.level
    }

    func audioPulse() -> Float {
        detectorLock.lock()
        defer { detectorLock.unlock() }
        return detector?.pulse ?? 0
    }

    @MainActor
    func analysisAudioStreamIndex() async -> Int32? {
        guard let loadedPlayer = player else { return nil }
        while self.player === loadedPlayer, !isReady {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return nil
            }
        }
        guard self.player === loadedPlayer else { return nil }
        return selectedAudioStreamIndex
    }

    func selectAudioTrack(id: Int32) {
        guard isReady, let player,
              let track = player.tracks(mediaType: .audio).first(where: { $0.trackID == id }),
              !track.isEnabled else { return }
        let target = currentTime
        let shouldResume = wantsPlayback
        seekGeneration &+= 1
        let generation = seekGeneration
        pendingSeek = nil
        activeSeek = nil
        watchdogLastTime = target
        watchdogSeekTicks = 0
        watchdogStalledTicks = 0
        player.select(track: track)
        applyPlaybackSettings(to: player)
        performSeek(to: target, resume: shouldResume, generation: generation, player: player)
        publishAudioTracks(for: player)
        onAudioTrackChange?(id)
    }

    /// 原生视频降级到 FFmpeg 时按音轨顺序延续用户选择。
    /// AVAsset 的 trackID 与 FFmpeg stream index 不是同一命名空间，不能直接相等比较。
    func preferAudioTrack(at ordinal: Int?) {
        preferredAudioTrackOrdinal = ordinal
        if isReady, let player { publishAudioTracks(for: player) }
    }

    func sampleEdgeColors() -> [NSColor]? {
        guard let pixelBuffer = player?.videoOutput?.pixelBuffer else { return nil }
        if let buffer = pixelBuffer.cvPixelBuffer {
            return VideoEdgeColorSampler.sample(CIImage(cvPixelBuffer: buffer))
        }

        let cached = softwareEdgeColors
        let width = pixelBuffer.width
        let height = pixelBuffer.height
        let maximumPixels = 4096 * 2304
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= maximumPixels else { return cached }

        let now = ProcessInfo.processInfo.systemUptime
        guard !softwareEdgeSamplePending,
              now - lastSoftwareEdgeSampleTime >= 1 else { return cached }
        softwareEdgeSamplePending = true
        lastSoftwareEdgeSampleTime = now
        let generation = edgeColorGeneration
        edgeColorQueue.async { [weak self, pixelBuffer] in
            let colors = autoreleasepool {
                pixelBuffer.cgImage().flatMap { image in
                    VideoEdgeColorSampler.sample(CIImage(cgImage: image))
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.softwareEdgeSamplePending = false
                guard self.edgeColorGeneration == generation, let colors else { return }
                self.softwareEdgeColors = colors
            }
        }
        return cached
    }

    private func installMeterTap(for player: KSMEPlayer) {
        uninstallMeterTap()
        guard let output = player.audioOutput as? AudioEnginePlayer else { return }
        meteredAudioOutput = output
        audioConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: output.engine,
            queue: .main
        ) { [weak self, weak output] _ in
            guard let self, let output, let player = self.player,
                  self.meteredAudioOutput === output else { return }
            let shouldResume = player.isPlaying
            self.reinstallMeterTap(for: output)
            self.applyPlaybackSettings(to: player)
            if shouldResume { output.play() }
        }
        reinstallMeterTap(for: output)
    }

    private func applyPlaybackSettings(to player: KSMEPlayer) {
        applyPlaybackVolume(to: player)
        player.playbackRate = max(0.25, min(4, rate))
    }

    private func applyPlaybackVolume(to player: KSMEPlayer) {
        let value = max(0, min(1, volume))
        if let output = player.audioOutput as? AudioEnginePlayer {
            // sourceNode 会在音频格式变化时重建，音量放在不随之重建的 mixer 上。
            player.playbackVolume = 1
            output.engine.mainMixerNode.outputVolume = value
        } else {
            player.playbackVolume = value
        }
    }

    private func reinstallMeterTap(for output: AudioEnginePlayer) {
        let mixer = output.engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        detectorLock.lock()
        detector = nil
        detectorLock.unlock()
        guard format.sampleRate > 0, format.channelCount > 0 else {
            if meterTapInstalled {
                mixer.removeTap(onBus: 0)
                meterTapInstalled = false
            }
            return
        }

        if meterTapInstalled { mixer.removeTap(onBus: 0) }

        detectorLock.lock()
        detector = BeatDetector(sampleRate: format.sampleRate)
        detectorLock.unlock()
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            self.detectorLock.lock()
            self.detector?.process(channelData[0], count: Int(buffer.frameLength))
            self.detectorLock.unlock()
        }
        meterTapInstalled = true
    }

    private func uninstallMeterTap() {
        if let audioConfigurationObserver {
            NotificationCenter.default.removeObserver(audioConfigurationObserver)
        }
        audioConfigurationObserver = nil
        if let output = meteredAudioOutput, meterTapInstalled {
            output.engine.mainMixerNode.removeTap(onBus: 0)
        }
        meterTapInstalled = false
        meteredAudioOutput = nil
        detectorLock.lock()
        detector = nil
        detectorLock.unlock()
    }

    private func publishAudioTracks(for player: KSMEPlayer) {
        guard self.player === player else { return }
        let tracks = player.tracks(mediaType: .audio)
        if let ordinal = preferredAudioTrackOrdinal {
            preferredAudioTrackOrdinal = nil
            if tracks.indices.contains(ordinal), !tracks[ordinal].isEnabled {
                player.select(track: tracks[ordinal])
                applyPlaybackSettings(to: player)
            }
        }
        if !tracks.isEmpty, tracks.allSatisfy({ !$0.isEnabled }), let first = tracks.first {
            player.select(track: first)
        }
        selectedAudioStreamIndex = tracks.first(where: \.isEnabled)?.trackID
        onAudioTracksChange?(tracks.enumerated().map { index, track in
            let name = track.name.isEmpty ? "音轨 \(index + 1)" : track.name
            return PlaybackAudioTrack(id: track.trackID,
                                      name: name,
                                      languageCode: track.languageCode,
                                      isSelected: track.isEnabled)
        })
    }
}

// MARK: - MediaPlayerDelegate

extension FFmpegBackend: MediaPlayerDelegate {
    @MainActor
    func readyToPlay(player: some MediaPlayerProtocol) {
        guard let mePlayer = player as? KSMEPlayer, mePlayer === self.player else { return }
        isReady = true
        // AudioEnginePlayer 到 ready 阶段才创建 sourceNode，load 时写入的音量可能尚未生效。
        applyPlaybackSettings(to: mePlayer)
        let d = player.duration
        if d.isFinite, d > 0 { duration = d }
        installMeterTap(for: mePlayer)
        publishAudioTracks(for: mePlayer)
        if let pendingSeek {
            self.pendingSeek = nil
            playWhenReady = false
            performSeek(to: pendingSeek.seconds, resume: pendingSeek.resume,
                        generation: pendingSeek.generation, player: mePlayer)
            return
        }
        if playWhenReady {
            playWhenReady = false
            player.play()
        }
    }

    @MainActor
    func changeLoadState(player: some MediaPlayerProtocol) {
        guard let mePlayer = player as? KSMEPlayer, mePlayer === self.player else { return }
        // 时长可能在 loadState 变化后才可靠：补一次
        let d = player.duration
        if d.isFinite, d > 0, d != duration { duration = d }
    }

    @MainActor
    func changeBuffering(player _: some MediaPlayerProtocol, progress _: Int) {}

    @MainActor
    func playBack(player _: some MediaPlayerProtocol, loopCount _: Int) {}

    @MainActor
    func finish(player: some MediaPlayerProtocol, error: Error?) {
        guard let mePlayer = player as? KSMEPlayer, mePlayer === self.player else { return }
        // 解码失败不能套用单曲循环，否则坏文件会无限重试。
        if let error {
            NSLog("FFmpegBackend 播放结束（含错误）：\(error.localizedDescription)")
            reportPlaybackError(error, for: mePlayer)
            return
        }
        if !isReady {
            reportPlaybackError(FFmpegBackendError.cannotOpen, for: mePlayer)
            return
        }
        // KSPlayer 只会在所有已选轨道都到达 EOF 后以 error == nil 回调这里。
        // 纯音频 EOF 会把主时钟切到空的视频时钟，不能再用 currentTime 反推是否播完。
        onTrackEnd?()
    }
}

private enum FFmpegBackendError: LocalizedError {
    case cannotOpen
    case openingTimedOut
    case seekTimedOut
    case decoderStalled

    var errorDescription: String? {
        switch self {
        case .cannotOpen:
            return "FFmpeg 无法打开该媒体。"
        case .openingTimedOut:
            return "FFmpeg 打开媒体超时。"
        case .seekTimedOut:
            return "FFmpeg 定位媒体超时。"
        case .decoderStalled:
            return "FFmpeg 解码器已停止响应。"
        }
    }
}
