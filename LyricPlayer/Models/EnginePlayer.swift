import Foundation
import AVFoundation

/// 基于 AVAudioEngine 的播放内核。
/// 相比 AVPlayer 的关键能力：在混音节点上安装 tap，实时取得音量电平，
/// 用于驱动动态背景与 Siri 式边缘光晕；变速经 AVAudioUnitTimePitch，不变调。
final class EnginePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    private var file: AVAudioFile?
    private var scheduleGeneration = 0
    private var baseFrame: AVAudioFramePosition = 0   // 本次调度的起始帧
    private var pausedAtSeconds: Double = 0           // 未播放时的当前位置

    private(set) var duration: Double = 0
    private(set) var isPlaying = false

    /// 曲目自然播完时回调（主线程）。
    var onTrackEnd: (() -> Void)?

    var rate: Float = 1.0 {
        didSet { timePitch.rate = max(0.25, min(4, rate)) }
    }

    var volume: Float = 0.8 {
        didSet { engine.mainMixerNode.outputVolume = max(0, min(1, volume)) }
    }

    // 实时电平与鼓点（谱通量检测，见 BeatDetector）
    private let levelLock = NSLock()
    private var detector: BeatDetector?

    private var configObserver: NSObjectProtocol?
    private var lastKnownSeconds: Double = 0   // 最近一次有效播放位置（设备切换恢复用）

    init() {
        engine.attach(node)
        engine.attach(timePitch)
        timePitch.rate = rate
        engine.mainMixerNode.outputVolume = volume
        installMeterTap()

        // 输出设备变化（44.1↔48kHz 耳机/音箱切换）：系统会停掉引擎，
        // mixer 输出格式可能改变——不重装 tap 的话，拍点时间轴按旧采样率算
        //（光晕节奏漂移），极端情况触发 AVFoundation 格式断言
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - 加载 / 播放控制

    func load(url: URL) throws {
        let audioFile = try AVAudioFile(forReading: url)
        stopNodeQuietly()
        engine.stop()

        file = audioFile
        duration = audioFile.processingFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.processingFormat.sampleRate
            : 0

        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(node, to: timePitch, format: audioFile.processingFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: audioFile.processingFormat)

        pausedAtSeconds = 0
        lastKnownSeconds = 0
        scheduleSegment(fromSeconds: 0)

        // 检测器提前就位：首个 tap 回调里建的话，vDSP FFT setup 的分配会落在音频线程上
        levelLock.lock()
        if detector == nil {
            detector = BeatDetector(sampleRate: engine.mainMixerNode.outputFormat(forBus: 0).sampleRate)
        }
        levelLock.unlock()
    }

    func unload() {
        stopNodeQuietly()
        engine.stop()
        file = nil
        duration = 0
        pausedAtSeconds = 0
        isPlaying = false
    }

    func play() {
        guard file != nil else { return }
        guard ensureEngineRunning() else { return }
        node.play()
        isPlaying = true
    }

    func pause() {
        pausedAtSeconds = currentTime
        node.pause()
        isPlaying = false
        // 挂起整个引擎：暂停时不再让音频 IO 电源域空转
        //（否则 tap 以 ~43 次/秒对纯静音做 FFT，还阻止音频硬件休眠）
        engine.pause()
    }

    func seek(to seconds: Double, resume: Bool) {
        guard file != nil else { return }
        let target = max(0, min(seconds, duration))
        node.stop()   // 旧调度的完成回调被 generation 挡掉
        scheduleSegment(fromSeconds: target)
        pausedAtSeconds = target
        if resume {
            guard ensureEngineRunning() else { return }
            node.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
    }

    var currentTime: Double {
        guard isPlaying, let file,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return pausedAtSeconds
        }
        let sampleRate = file.processingFormat.sampleRate
        let seconds = Double(baseFrame) / sampleRate + Double(playerTime.sampleTime) / playerTime.sampleRate
        let clamped = max(0, min(duration, seconds))
        lastKnownSeconds = clamped
        return clamped
    }

    /// 供可视化读取的实时电平；暂停时自然衰减到 0。
    func audioLevel() -> Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        guard let detector else { return 0 }
        if !isPlaying { detector.decayWhilePaused() }
        return detector.level
    }

    /// 鼓点脉冲（0...1）：检测到 onset 瞬间跳到 1，随后指数衰减。
    func audioPulse() -> Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return detector?.pulse ?? 0
    }

    // MARK: - 内部

    private func ensureEngineRunning() -> Bool {
        guard !engine.isRunning else { return true }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            NSLog("音频引擎启动失败：\(error.localizedDescription)")
            return false
        }
    }

    private func stopNodeQuietly() {
        scheduleGeneration += 1
        node.stop()
    }

    private func scheduleSegment(fromSeconds seconds: Double) {
        guard let file else { return }
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, min(seconds, duration)) * sampleRate)
        let remaining = AVAudioFrameCount(max(0, file.length - startFrame))
        baseFrame = startFrame
        scheduleGeneration += 1
        let generation = scheduleGeneration

        guard remaining > 0 else {
            DispatchQueue.main.async { [weak self] in self?.onTrackEnd?() }
            return
        }
        node.scheduleSegment(file, startingFrame: startFrame, frameCount: remaining,
                             at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.scheduleGeneration == generation else { return }
                self.isPlaying = false
                self.pausedAtSeconds = self.duration
                self.engine.pause()   // 播完不续曲时（单曲末尾/列表尽头）别让引擎空转
                self.onTrackEnd?()
            }
        }
    }

    /// 输出设备/采样率变化后的自愈：按新 mixer 格式重装 tap、重建检测器，
    /// 并在原位置续播（系统在配置变化时已把引擎停了）。
    private func handleConfigurationChange() {
        engine.mainMixerNode.removeTap(onBus: 0)
        levelLock.lock()
        detector = nil
        levelLock.unlock()
        installMeterTap()

        guard file != nil else { return }
        let wasPlaying = isPlaying
        let position = wasPlaying ? lastKnownSeconds : pausedAtSeconds
        seek(to: position, resume: wasPlaying)
    }

    private func installMeterTap() {
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            self.levelLock.lock()
            if self.detector == nil {
                self.detector = BeatDetector(sampleRate: buffer.format.sampleRate)
            }
            // 单声道分析（取左声道；节拍/响度对声道不敏感）
            self.detector?.process(channelData[0], count: frames)
            self.levelLock.unlock()
        }
    }
}
