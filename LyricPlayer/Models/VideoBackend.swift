import Foundation
import AVFoundation
import CoreImage
import AppKit

/// 播放后端抽象：音频文件走 EnginePlayer（AVAudioEngine，带实时电平/节拍），
/// 视频文件走 VideoBackend（AVPlayer，画面经 AVPlayerLayer 渲染）。
protocol PlaybackBackend: AnyObject {
    var duration: Double { get }
    var currentTime: Double { get }
    var isPlaying: Bool { get }
    var rate: Float { get set }
    var volume: Float { get set }
    var onTrackEnd: (() -> Void)? { get set }

    func load(url: URL) throws
    func unload()
    func play()
    func pause()
    func seek(to seconds: Double, resume: Bool)
    func audioLevel() -> Float
    func audioPulse() -> Float
}

extension EnginePlayer: PlaybackBackend {}

/// 视频播放后端：AVPlayer。
/// 实时电平/节拍返回 0——视频的光晕节拍由离线拍点网格（BeatGrid）驱动，
/// 网格分析读取的是视频的音轨，与播放路径无关。
final class VideoBackend: PlaybackBackend {
    let player = AVPlayer()

    private(set) var duration: Double = 0
    /// 原生悬浮控制条也能操作播放，因此播放态直接从 AVPlayer 推导
    var isPlaying: Bool { player.timeControlStatus != .paused }
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var mediaSelectionTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var playbackIntentObserver: NSObjectProtocol?
    private var audioSelectionTask: Task<CMPersistentTrackID?, Never>?
    private var openingTimeoutTask: Task<Void, Never>?
    private(set) var selectedAudioTrackID: CMPersistentTrackID?
    private(set) var selectedAudioTrackOrdinal: Int?
    private var didResolveAudioSelection = false
    private weak var failedItem: AVPlayerItem?
    // 画面边缘取色（氛围光）：低频率从视频帧采样
    private var videoOutput: AVPlayerItemVideoOutput?
    private var seekGeneration: UInt64 = 0
    private var seekResumeIntent: Bool?

    var onTrackEnd: (() -> Void)?
    var onPlaybackError: ((Error) -> Void)?
    /// 只上报用户或 AVKit 明确调用 play/pause 产生的播放意图。
    var onPlaybackIntentChange: ((Bool) -> Void)?
    /// AVKit HUD 改变倍速后，模型和其他播放后端需同步同一设置。
    var onRateChange: ((Float) -> Void)?
    /// AVKit HUD 切换音轨后，歌词和拍点需跟随实际正在播放的音轨重建。
    var onAudioTrackChange: ((CMPersistentTrackID?) -> Void)?
    /// 视频自然尺寸就绪回调（已应用旋转变换，主线程）。
    var onVideoSize: ((CGSize) -> Void)?

    var rate: Float = 1.0 {
        didSet {
            let value = max(0.25, min(4, rate))
            if player.defaultRate != value { player.defaultRate = value }
            if isPlaying, player.rate != value { player.rate = value }
        }
    }

    var volume: Float = 0.8 {
        didSet { player.volume = max(0, min(1, volume)) }
    }

    var currentTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    static func playbackIntent(rate: Float,
                               reason: AVPlayer.RateDidChangeReason?) -> Bool? {
        guard reason == .setRateCalled else { return nil }
        return rate != 0
    }

    init() {
        player.defaultRate = rate
        rateObservation = player.observe(\.defaultRate, options: [.new]) { [weak self] player, _ in
            let value = max(0.25, min(4, player.defaultRate))
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.rate - value) > 0.001 else { return }
                self.rate = value
                self.onRateChange?(value)
            }
        }
    }

    func load(url: URL) throws {
        seekGeneration &+= 1
        seekResumeIntent = nil
        audioSelectionTask?.cancel()
        openingTimeoutTask?.cancel()
        selectedAudioTrackID = nil
        selectedAudioTrackOrdinal = nil
        didResolveAudioSelection = false
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain   // 倍速不变调
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        videoOutput = output
        failedItem = nil
        player.replaceCurrentItem(with: item)
        installPlaybackIntentObserver(for: item)
        player.volume = volume
        duration = 0

        openingTimeoutTask = Task { @MainActor [weak self, weak item] in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard let self, let item,
                  self.player.currentItem === item,
                  item.status == .unknown else { return }
            self.reportPlaybackError(VideoBackendError.openingTimedOut, for: item)
        }

        let selectionTask = Task { @MainActor [weak self] () -> CMPersistentTrackID? in
            guard let self else { return nil }
            if let group = try? await asset.loadMediaSelectionGroup(for: .audible),
               item.currentMediaSelection.selectedMediaOption(in: group) == nil,
               let fallback = group.defaultOption ?? group.options.first {
                item.select(fallback, in: group)
            }
            let becameReady = await Self.waitUntilReady(item)
            guard !Task.isCancelled, self.player.currentItem === item else { return nil }
            guard becameReady else {
                self.reportPlaybackError(item.error ?? VideoBackendError.openingTimedOut, for: item)
                return nil
            }
            self.openingTimeoutTask?.cancel()
            self.openingTimeoutTask = nil
            let selection = await Self.audioSelection(for: item)
            guard !Task.isCancelled, self.player.currentItem === item else { return nil }
            self.didResolveAudioSelection = true
            guard !selection.hasAudio || selection.trackID != nil else {
                self.reportPlaybackError(VideoBackendError.unsupportedAudioTrack, for: item)
                return nil
            }
            self.selectedAudioTrackID = selection.trackID
            self.selectedAudioTrackOrdinal = selection.trackOrdinal
            self.installMediaSelectionObserver(for: item)
            return selection.trackID
        }
        audioSelectionTask = selectionTask

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let d = try? await item.asset.load(.duration).seconds, d.isFinite {
                guard self.player.currentItem === item else { return }
                self.duration = d
            }
            // 自然尺寸（含旋转）→ 窗口宽高比绑定
            if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
               let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: size).applying(transform)
                let display = CGSize(width: abs(r.width), height: abs(r.height))
                guard self.player.currentItem === item else { return }
                self.onVideoSize?(display)
            }
        }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        mediaSelectionTask?.cancel()
        statusObservation?.invalidate()
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            guard let self, self.player.currentItem === item else { return }
            self.onTrackEnd?()
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                ?? item.error
                ?? CocoaError(.fileReadCorruptFile)
            self?.reportPlaybackError(error, for: item)
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard observedItem.status == .failed else { return }
            let error = observedItem.error ?? CocoaError(.fileReadCorruptFile)
            DispatchQueue.main.async { [weak self, weak observedItem] in
                guard let self, let observedItem else { return }
                self.reportPlaybackError(error, for: observedItem)
            }
        }
    }

    func unload() {
        seekGeneration &+= 1
        seekResumeIntent = nil
        audioSelectionTask?.cancel()
        audioSelectionTask = nil
        openingTimeoutTask?.cancel()
        openingTimeoutTask = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        mediaSelectionTask?.cancel()
        statusObservation?.invalidate()
        if let playbackIntentObserver {
            NotificationCenter.default.removeObserver(playbackIntentObserver)
        }
        endObserver = nil
        failureObserver = nil
        mediaSelectionTask = nil
        statusObservation = nil
        playbackIntentObserver = nil
        failedItem = nil
        selectedAudioTrackID = nil
        selectedAudioTrackOrdinal = nil
        didResolveAudioSelection = false
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        duration = 0
    }

    func play() {
        guard player.currentItem != nil else { return }
        if seekResumeIntent != nil { seekResumeIntent = true }
        player.playImmediately(atRate: max(0.25, min(4, rate)))
    }

    func pause() {
        if seekResumeIntent != nil { seekResumeIntent = false }
        player.pause()
    }

    func seek(to seconds: Double, resume: Bool) {
        guard let item = player.currentItem else { return }
        seekGeneration &+= 1
        let generation = seekGeneration
        seekResumeIntent = resume
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // 完成回调版本：seek 落定后才决定播/停，强制解码渲染目标帧——
        // 修复"播完回到开头黑屏"（无回调的 seek 在到达文件末尾后不会刷新画面）
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self,
                      self.seekGeneration == generation,
                      self.player.currentItem === item else { return }
                let shouldResume = self.seekResumeIntent ?? resume
                self.seekResumeIntent = nil
                guard finished else { return }
                shouldResume ? self.play() : self.player.pause()
            }
        }
    }

    func audioLevel() -> Float { 0 }
    func audioPulse() -> Float { 0 }

    @MainActor
    func analysisAudioTrackID() async -> CMPersistentTrackID? {
        if didResolveAudioSelection { return selectedAudioTrackID }
        _ = await audioSelectionTask?.value
        return selectedAudioTrackID
    }

    private struct AudioSelection {
        let trackID: CMPersistentTrackID?
        let trackOrdinal: Int?
        let hasAudio: Bool
    }

    @MainActor
    private static func waitUntilReady(_ item: AVPlayerItem) async -> Bool {
        // 本地损坏文件、失联网络卷和未完成的 iCloud 占位文件都可能永远停在 unknown。
        for _ in 0..<1_200 where item.status == .unknown {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return item.status == .readyToPlay
    }

    @MainActor
    private static func audioSelection(for item: AVPlayerItem) async -> AudioSelection {
        let audioTracks = (try? await item.asset.loadTracks(withMediaType: .audio)) ?? []
        let audioTrackIDs = Set(audioTracks.map(\.trackID))
        let itemTracks = item.tracks
        if let selected = itemTracks.first(where: {
            $0.isEnabled && $0.assetTrack.map { audioTrackIDs.contains($0.trackID) } == true
        })?.assetTrack {
            return AudioSelection(trackID: selected.trackID,
                                  trackOrdinal: audioTracks.firstIndex { $0.trackID == selected.trackID },
                                  hasAudio: true)
        }
        return AudioSelection(trackID: nil, trackOrdinal: nil, hasAudio: !audioTracks.isEmpty)
    }

    @MainActor
    private func installMediaSelectionObserver(for item: AVPlayerItem) {
        mediaSelectionTask?.cancel()
        mediaSelectionTask = Task { @MainActor [weak self, weak item] in
            guard let item else { return }
            for await _ in NotificationCenter.default.notifications(
                named: AVPlayerItem.mediaSelectionDidChangeNotification,
                object: item
            ) {
                guard !Task.isCancelled, let self, self.player.currentItem === item else { return }
                let selection = await Self.audioSelection(for: item)
                guard self.player.currentItem === item else { return }
                guard !selection.hasAudio || selection.trackID != nil else {
                    if await Self.isAudioExplicitlyMuted(item) {
                        guard self.selectedAudioTrackID != nil else { continue }
                        self.selectedAudioTrackID = nil
                        self.selectedAudioTrackOrdinal = nil
                        self.onAudioTrackChange?(nil)
                        continue
                    } else {
                        self.reportPlaybackError(VideoBackendError.unsupportedAudioTrack, for: item)
                        return
                    }
                }
                guard selection.trackID != self.selectedAudioTrackID else { continue }
                self.selectedAudioTrackID = selection.trackID
                self.selectedAudioTrackOrdinal = selection.trackOrdinal
                self.onAudioTrackChange?(selection.trackID)
            }
        }
    }

    @MainActor
    private static func isAudioExplicitlyMuted(_ item: AVPlayerItem) async -> Bool {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
              group.allowsEmptySelection else { return false }
        return item.currentMediaSelection.selectedMediaOption(in: group) == nil
    }

    private func reportPlaybackError(_ error: Error, for item: AVPlayerItem) {
        guard player.currentItem === item, failedItem !== item else { return }
        failedItem = item
        openingTimeoutTask?.cancel()
        openingTimeoutTask = nil
        audioSelectionTask?.cancel()
        onPlaybackError?(error)
    }

    private func installPlaybackIntentObserver(for item: AVPlayerItem) {
        if let playbackIntentObserver {
            NotificationCenter.default.removeObserver(playbackIntentObserver)
        }
        playbackIntentObserver = NotificationCenter.default.addObserver(
            forName: AVPlayer.rateDidChangeNotification,
            object: player,
            queue: .main
        ) { [weak self, weak item] notification in
            guard let self, let item,
                  self.player.currentItem === item,
                  self.failedItem !== item else { return }
            let reason = notification.userInfo?[AVPlayer.rateDidChangeReasonKey]
                as? AVPlayer.RateDidChangeReason
            guard let intent = Self.playbackIntent(rate: self.player.rate,
                                                   reason: reason) else { return }
            self.onPlaybackIntentChange?(intent)
        }
    }

    /// 采样当前视频帧的 8 个边缘区域平均色（氛围光用），顺时针从顶部开始。
    func sampleEdgeColors() -> [NSColor]? {
        guard let output = videoOutput else { return nil }
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
        return VideoEdgeColorSampler.sample(CIImage(cvPixelBuffer: buffer))
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        statusObservation?.invalidate()
        if let playbackIntentObserver {
            NotificationCenter.default.removeObserver(playbackIntentObserver)
        }
        rateObservation?.invalidate()
        audioSelectionTask?.cancel()
        openingTimeoutTask?.cancel()
        mediaSelectionTask?.cancel()
    }
}

private enum VideoBackendError: LocalizedError {
    case unsupportedAudioTrack
    case openingTimedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedAudioTrack:
            return "原生视频后端无法解码当前音轨。"
        case .openingTimedOut:
            return "原生视频后端打开媒体超时。"
        }
    }
}

enum VideoEdgeColorSampler {
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    static func sample(_ image: CIImage) -> [NSColor]? {
        let e = image.extent
        guard e.width > 8, e.height > 8 else { return nil }

        // 一次把整帧缩成 8×8 再单次回读（256 字节）：
        // 旧做法是 8 个 CIAreaAverage 各建滤镜、各做一次 1×1 GPU→CPU 同步回读，
        // 每次回读都要等 GPU 排空，实测每帧阻塞 2-8ms；合并后 <1ms
        let grid = 8
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(grid) / e.width,
                                                             y: CGFloat(grid) / e.height))
        var pixels = [UInt8](repeating: 0, count: grid * grid * 4)
        ciContext.render(scaled, toBitmap: &pixels, rowBytes: grid * 4,
                         bounds: CGRect(x: 0, y: 0, width: grid, height: grid),
                         format: .BGRA8, colorSpace: nil)

        // 位图第 0 行对应画面顶部；每块取 2×2 网格均值
        func band(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>) -> NSColor {
            var r = 0, g = 0, b = 0, n = 0
            for y in ys {
                for x in xs {
                    let i = (y * grid + x) * 4
                    b += Int(pixels[i]); g += Int(pixels[i + 1]); r += Int(pixels[i + 2])
                    n += 1
                }
            }
            let scale = CGFloat(n * 255)
            return NSColor(red: CGFloat(r) / scale, green: CGFloat(g) / scale,
                           blue: CGFloat(b) / scale, alpha: 1)
        }
        // 顺时针：顶、右上、右、右下、底、左下、左、左上（与光晕的取色顺序约定一致）
        return [band(3...4, 0...1), band(6...7, 0...1), band(6...7, 3...4), band(6...7, 6...7),
                band(3...4, 6...7), band(0...1, 6...7), band(0...1, 3...4), band(0...1, 0...1)]
    }
}
