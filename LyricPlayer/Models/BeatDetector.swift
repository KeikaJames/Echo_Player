import Foundation
import Accelerate
import AVFoundation

/// 实时鼓点检测：谱通量（Spectral Flux）+ 自适应阈值。
/// 这是 aubio / librosa 等专业库的标准做法：
/// - 1024 点帧、512 点跳步、Hann 窗、实数 FFT 取幅度谱；
/// - 通量 = Σ max(0, |X_n[k]| − |X_{n−1}[k]|)，低频段（底鼓）加权；
/// - 阈值 = 中值(7帧) + 1.0×均值(7帧)，0.25s 不应期。
///
/// 性能（Apple Silicon）：分析热路径零堆分配——所有工作缓冲在 init 一次性分配，
/// 幅度谱用指针交换代替拷贝，输入队列用游标消费代替 removeFirst 的逐 hop 搬移。
/// 该路径同时服务实时 tap（86 帧/秒）与整曲离线预分析（一首 4 分钟歌约 2 万帧）。
final class BeatDetector {
    private let frameSize = 1024
    private let hopSize = 512
    private let log2n: vDSP_Length = 10
    private let sampleRate: Double

    private let fftSetup: FFTSetup

    // 一次性分配的工作缓冲（deinit 统一释放）
    private let window: UnsafeMutablePointer<Float>          // Hann 窗
    private let windowed: UnsafeMutablePointer<Float>        // 加窗后的帧
    private var magnitudes: UnsafeMutablePointer<Float>      // 本帧幅度谱（与 prev 指针互换）
    private var prevMagnitudes: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let medianScratch: UnsafeMutablePointer<Float>   // 阈值窗口的排序草稿（7 元素）

    // 输入队列：追加 + 游标前移，游标积累到阈值才做一次紧凑（摊还 O(1)）
    private var pending: [Float] = []
    private var pendingStart = 0

    // 通量历史：定长环形缓冲（原实现的 removeFirst 会逐帧搬移）
    private let historySize = 43            // ≈1 秒（44.1kHz / 512 hop）
    private var fluxRing: [Float]
    private var fluxWritten = 0             // 累计写入帧数

    private var samplesProcessed = 0
    private var lastOnsetAt = -1.0
    private var prevFlux: Float = 0
    private var prevFlux2: Float = 0

    private let bassBins: Int               // 低频加权的频段上界（≈200Hz）
    private let maxBin: Int                 // 通量统计上界（≈5kHz，人声/军鼓以下）

    /// 平滑响度（0...1），快攻慢放。
    private(set) var level: Float = 0
    /// 鼓点包络：onset 瞬间跳到 1，按 ~6/s 指数衰减。
    private(set) var pulse: Float = 0
    /// 每次检出 onset 的回调（参数为已处理音频的时间点，秒）。
    var onOnset: ((Double) -> Void)?

    init(sampleRate: Double) {
        self.sampleRate = max(8000, sampleRate)
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        let half = frameSize / 2
        window = .allocate(capacity: frameSize)
        windowed = .allocate(capacity: frameSize)
        magnitudes = .allocate(capacity: half)
        prevMagnitudes = .allocate(capacity: half)
        realp = .allocate(capacity: half)
        imagp = .allocate(capacity: half)
        medianScratch = .allocate(capacity: 7)
        magnitudes.initialize(repeating: 0, count: half)
        prevMagnitudes.initialize(repeating: 0, count: half)

        vDSP_hann_window(window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))
        let binHz = self.sampleRate / Double(frameSize)
        self.bassBins = max(3, Int(200.0 / binHz))
        self.maxBin = min(half - 1, Int(5000.0 / binHz))
        self.fluxRing = [Float](repeating: 0, count: historySize)
        pending.reserveCapacity(frameSize * 16)   // 大于压缩阈值（8192），稳态才真正零重分配
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        window.deallocate()
        windowed.deallocate()
        magnitudes.deallocate()
        prevMagnitudes.deallocate()
        realp.deallocate()
        imagp.deallocate()
        medianScratch.deallocate()
    }

    /// 喂入单声道样本（音频线程调用）。
    func process(_ samples: UnsafePointer<Float>, count: Int) {
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        while pending.count - pendingStart >= frameSize {
            pending.withUnsafeBufferPointer { buf in
                analyzeFrame(buf.baseAddress! + pendingStart)
            }
            pendingStart += hopSize
            samplesProcessed += hopSize
        }
        // 消费完后残留必然 < frameSize，一次搬移收尾，比逐 hop removeFirst 少两个数量级
        if pendingStart >= 8192 {
            pending.removeFirst(pendingStart)
            pendingStart = 0
        }
    }

    private func analyzeFrame(_ frame: UnsafePointer<Float>) {
        let n = vDSP_Length(frameSize)
        let half = frameSize / 2

        // 响度
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, n)
        let mapped = min(1, rms * 4.5)
        level = mapped > level ? level + (mapped - level) * 0.5
                               : level + (mapped - level) * 0.08

        // 加窗 + 实数 FFT 幅度谱（全部写入预分配缓冲）
        vDSP_vmul(frame, 1, window, 1, windowed, 1, n)
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(half))

        // 对数压缩 log(1 + 10·X)（aubio specflux 默认 λ=10）：拉平动态，跨曲风更稳
        var lambda: Float = 10
        vDSP_vsmul(magnitudes, 1, &lambda, magnitudes, 1, vDSP_Length(half))
        var count32 = Int32(half)
        vvlog1pf(magnitudes, magnitudes, &count32)

        // 谱通量：只取正向增量；低频（底鼓）3× 加权
        var flux: Float = 0
        for k in 1..<maxBin {
            let diff = magnitudes[k] - prevMagnitudes[k]
            if diff > 0 {
                flux += diff * (k <= bassBins ? 3.0 : 1.0)
            }
        }
        swap(&magnitudes, &prevMagnitudes)   // 指针互换代替整谱拷贝

        // aubio 式动态阈值：中值(7帧) + 1.0×均值(7帧)——flux 分布长尾，比均值+kσ 更稳；
        // 峰值判定延迟一帧：上一帧必须是三帧里的局部最大且过线（≈12ms 延迟，视觉无感）
        let now = Double(samplesProcessed) / sampleRate
        if fluxWritten >= 7 {
            var sum: Float = 0
            for i in 0..<7 {
                let v = fluxRing[(fluxWritten - 7 + i) % historySize]
                sum += v
                // 7 元素插入排序（栈上完成，代替 suffix+sorted 的两次分配）
                var j = i
                while j > 0, medianScratch[j - 1] > v {
                    medianScratch[j] = medianScratch[j - 1]
                    j -= 1
                }
                medianScratch[j] = v
            }
            let threshold = medianScratch[3] + 1.0 * (sum / 7) + 1e-4   // k 经真实歌曲参数扫描定标：锁八分音符网格

            let prevTime = now - Double(hopSize) / sampleRate
            if prevFlux > prevFlux2, prevFlux >= flux, prevFlux > threshold,
               prevTime - lastOnsetAt > 0.25 {
                pulse = 1
                lastOnsetAt = prevTime
                onOnset?(prevTime)
            }
        }
        prevFlux2 = prevFlux
        prevFlux = flux
        fluxRing[fluxWritten % historySize] = flux
        fluxWritten += 1

        // 包络衰减
        let dt = Float(hopSize) / Float(sampleRate)
        pulse *= exp(-6 * dt)
    }

    /// 暂停时让包络自然归零（UI 线程读取用）。
    func decayWhilePaused() {
        pulse *= 0.85
        if pulse < 0.005 { pulse = 0 }
        level *= 0.9
        if level < 0.005 { level = 0 }
    }
}

/// 离线拍点网格：加载曲目时后台预分析整首歌的 onset 序列。
/// 播放时按网格查表触发光晕弹跳——零检测延迟、零抖动（Superpowered 的离线分析思路）。
enum BeatGrid {
    static func analyze(url: URL) async -> [Double] {
        await Task.detached(priority: .utility) { () -> [Double] in
            guard let file = try? AVAudioFile(forReading: url),
                  file.processingFormat.sampleRate > 0 else { return [] }
            let detector = BeatDetector(sampleRate: file.processingFormat.sampleRate)
            var onsets: [Double] = []
            detector.onOnset = { onsets.append($0) }

            let chunk = AVAudioFrameCount(65536)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return [] }
            while file.framePosition < file.length {
                if Task.isCancelled { return [] }
                do { try file.read(into: buffer, frameCount: chunk) } catch { break }
                if buffer.frameLength == 0 { break }
                if let data = buffer.floatChannelData {
                    detector.process(data[0], count: Int(buffer.frameLength))
                }
            }
            return onsets
        }.value
    }
}
