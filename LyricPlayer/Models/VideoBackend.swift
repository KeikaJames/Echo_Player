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
    // 画面边缘取色（氛围光）：低频率从视频帧采样
    private var videoOutput: AVPlayerItemVideoOutput?
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    var onTrackEnd: (() -> Void)?
    /// 视频自然尺寸就绪回调（已应用旋转变换，主线程）。
    var onVideoSize: ((CGSize) -> Void)?

    var rate: Float = 1.0 {
        didSet { if isPlaying { player.rate = max(0.25, min(4, rate)) } }
    }

    var volume: Float = 0.8 {
        didSet { player.volume = max(0, min(1, volume)) }
    }

    var currentTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    func load(url: URL) throws {
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain   // 倍速不变调
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        videoOutput = output
        player.replaceCurrentItem(with: item)
        player.volume = volume
        duration = 0

        Task { [weak self] in
            if let d = try? await item.asset.load(.duration).seconds, d.isFinite {
                await MainActor.run {
                    guard let self, self.player.currentItem === item else { return }
                    self.duration = d
                }
            }
            // 自然尺寸（含旋转）→ 窗口宽高比绑定
            if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
               let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: size).applying(transform)
                let display = CGSize(width: abs(r.width), height: abs(r.height))
                await MainActor.run {
                    guard let self, self.player.currentItem === item else { return }
                    self.onVideoSize?(display)
                }
            }
        }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            self?.onTrackEnd?()
        }
    }

    func unload() {
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        duration = 0
    }

    func play() {
        guard player.currentItem != nil else { return }
        player.playImmediately(atRate: max(0.25, min(4, rate)))
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double, resume: Bool) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // 完成回调版本：seek 落定后才决定播/停，强制解码渲染目标帧——
        // 修复"播完回到开头黑屏"（无回调的 seek 在到达文件末尾后不会刷新画面）
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            resume ? self.play() : self.player.pause()
        }
    }

    func audioLevel() -> Float { 0 }
    func audioPulse() -> Float { 0 }

    /// 采样当前视频帧的 8 个边缘区域平均色（氛围光用），顺时针从顶部开始。
    func sampleEdgeColors() -> [NSColor]? {
        guard let output = videoOutput else { return nil }
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let e = image.extent
        guard e.width > 8, e.height > 8 else { return nil }

        // 一次把整帧缩成 8×8 再单次回读（256 字节）：
        // 旧做法是 8 个 CIAreaAverage 各建滤镜、各做一次 1×1 GPU→CPU 同步回读，
        // 每次回读都要等 GPU 排空，实测每帧阻塞 2-8ms；合并后 <1ms
        let grid = 8
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(grid) / e.width,
                                                             y: CGFloat(grid) / e.height))
        var pixels = [UInt8](repeating: 0, count: grid * grid * 4)
        Self.ciContext.render(scaled, toBitmap: &pixels, rowBytes: grid * 4,
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

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}
