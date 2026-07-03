import Foundation
import AVFoundation
import AppKit
import KSPlayer

/// 基于 KSPlayer（FFmpeg 软解）的播放后端。
///
/// AVFoundation 无法解码的容器/编码（mkv / webm / ogg / oga / opus / ape / wma /
/// flv / avi / ts 等）统一走这里：内部用 `KSMEPlayer`，画面由它自带的
/// 视频输出 `NSView` 渲染（见 `playerView`）。
///
/// 实时电平/鼓点返回 0——与 `VideoBackend` 一致，光晕节拍由离线拍点网格驱动；
/// 但拍点网格读的是 `AVAudioFile`，对这些格式多半打不开，因此这类文件通常没有
/// 氛围光/节拍，属已知取舍（见文末 TODO）。
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
        guard let player else { return 0 }
        let t = player.currentPlaybackTime
        return t.isFinite ? max(0, t) : 0
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    var rate: Float = 1.0 {
        didSet { player?.playbackRate = max(0.25, min(4, rate)) }
    }

    var volume: Float = 0.8 {
        didSet { player?.playbackVolume = max(0, min(1, volume)) }
    }

    var onTrackEnd: (() -> Void)?

    // MARK: - 私有状态

    private var player: KSMEPlayer?
    /// 就绪后是否自动开播（load 时 play() 早于 readyToPlay，需在回调里补触发）。
    private var playWhenReady = false
    /// 已收到 readyToPlay：此后 play()/pause() 可直接作用于底层播放器。
    private var isReady = false

    /// 供画面渲染层挂载的原生视图（KSMEPlayer 的视频输出）。
    var playerView: NSView? { player?.view }

    // MARK: - 加载 / 播放控制

    func load(url: URL) throws {
        unload()
        let options = KSOptions()   // 静态项非 public，保持默认
        let me = KSMEPlayer(url: url, options: options)
        me.delegate = self
        me.playbackVolume = max(0, min(1, volume))
        me.playbackRate = max(0.25, min(4, rate))
        player = me
        duration = 0
        isReady = false
        playWhenReady = false
        me.prepareToPlay()
    }

    func unload() {
        player?.delegate = nil
        player?.shutdown()
        player = nil
        duration = 0
        isReady = false
        playWhenReady = false
    }

    func play() {
        guard let player else { return }
        // 尚未就绪：记下意图，readyToPlay 到达后再开播
        guard isReady else { playWhenReady = true; return }
        player.play()
    }

    func pause() {
        playWhenReady = false
        player?.pause()
    }

    func seek(to seconds: Double, resume: Bool) {
        guard let player else { return }
        let target = max(0, seconds)
        player.seek(time: target) { [weak self] _ in
            // KSPlayer 的 seek 回调可能不在主线程：统一回主线程恢复播放态
            Task { @MainActor in
                guard let self, self.player === player else { return }
                if resume {
                    self.play()
                } else {
                    player.pause()
                }
            }
        }
    }

    // 实时电平/鼓点：FFmpeg 软解路径暂不提供 tap，返回 0。
    // TODO: 若日后需要这些格式的氛围光/节拍，可挂 KSPlayer 的音频渲染回调取样。
    func audioLevel() -> Float { 0 }
    func audioPulse() -> Float { 0 }
}

// MARK: - MediaPlayerDelegate

extension FFmpegBackend: MediaPlayerDelegate {
    @MainActor
    func readyToPlay(player: some MediaPlayerProtocol) {
        isReady = true
        let d = player.duration
        if d.isFinite, d > 0 { duration = d }
        if playWhenReady {
            playWhenReady = false
            player.play()
        }
    }

    @MainActor
    func changeLoadState(player: some MediaPlayerProtocol) {
        // 时长可能在 loadState 变化后才可靠：补一次
        let d = player.duration
        if d.isFinite, d > 0, d != duration { duration = d }
    }

    @MainActor
    func changeBuffering(player _: some MediaPlayerProtocol, progress _: Int) {}

    @MainActor
    func playBack(player _: some MediaPlayerProtocol, loopCount _: Int) {}

    @MainActor
    func finish(player _: some MediaPlayerProtocol, error: Error?) {
        // 自然播完（error == nil）通知上层切下一首；
        // 出错时也走同一路径，交由 PlayerModel 的循环/跳曲逻辑处理。
        if let error {
            NSLog("FFmpegBackend 播放结束（含错误）：\(error.localizedDescription)")
        }
        onTrackEnd?()
    }
}
