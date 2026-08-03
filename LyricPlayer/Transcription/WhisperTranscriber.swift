#if canImport(WhisperKit)  // 只有添加了 WhisperKit 包依赖时才编译

import AVFoundation
import ArgmaxCore
import Foundation
import WhisperKit

/// 深度识别引擎：WhisperKit（OpenAI Whisper 的 CoreML 移植）。
/// 对带伴奏的歌曲、噪声鲁棒。由 AutoTranscriber 在快速识别不可靠时自动调用。
///
/// 关键策略：
/// - 先切一段人声概率高的音频（歌曲 1/4 处）探测语言，再用固定语言整曲识别，
///   避免在纯伴奏前奏上做语言检测导致整曲被判为"音乐"；
/// - 过滤 [Music]、(music)、♪ 等非语音标注；
/// - 中文等 CJK 词按字细分时间戳，供逐字流动歌词使用。
enum WhisperTranscriber {
    /// 固定使用 small 模型：中文及多语种质量/速度的平衡点。
    private static let modelName = "small"
    private static let modelRepository = "argmaxinc/whisperkit-coreml"
    private static let modelRevision = "97a5bf9bbc74c7d9c12c755d04dea59e672e3808"
    /// 深度识别按十分钟分段读取，避免超长音轨一次展开成数 GB 浮点样本。
    static let deepChunkSeconds = 10 * 60.0
    /// 分段两侧多读三秒，跨切点的句子由单词中点归属到唯一主分段。
    static let deepChunkOverlapSeconds = 3.0
    private static let inputReadSeconds = 15.0
    private static let maximumInputReadFrames: AVAudioFrameCount = 131_072
    private static let maximumExactFramePosition: Double = 9_007_199_254_740_991

    /// 常驻的推理管线：模型加载较慢，跨曲目复用。
    /// - single-flight：并发调用共享同一次加载，快速切歌时不会同时初始化两份 500MB 模型；
    /// - 收到系统内存压力警告时释放（正在使用的转写因 ARC 持有本地引用不受影响）。
    private static let pipelineLock = NSLock()
    private static var cachedPipeline: WhisperKit?
    private static var loadingTask: Task<WhisperKit, Error>?
    private static var loadingGeneration: UInt64 = 0
    private static var pressureSource: DispatchSourceMemoryPressure?

    /// 模型存放目录。也支持手动下载模型放到这里离线使用（见 README）。
    static var modelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyricPlayer/WhisperModels", isDirectory: true)
    }

    static func transcribe(url: URL, duration: Double, onUpdate: @escaping TranscriptionUpdateHandler) async throws -> [LyricLine] {
        guard duration.isFinite, duration > 0 else { throw TranscriptionError.cannotReadAudio }
        let whisper = try await loadPipeline(onUpdate: onUpdate)
        try Task.checkCancellation()

        // 在人声概率高的位置切片探测语言（避开纯伴奏的前奏）
        let language = await detectLanguage(url: url, duration: duration, whisper: whisper)
        try Task.checkCancellation()

        onUpdate(TranscriptionSnapshot(lines: [], fraction: 0, message: "正在深入识别歌词…"))

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.detectLanguage = (language == nil)
        options.wordTimestamps = true
        options.chunkingStrategy = .vad

        let gate = ProgressGate()
        let cancellation = TranscriptionCancellationState()
        var words: [LyricWord] = []
        var chunkStart = 0.0

        while chunkStart < duration {
            try Task.checkCancellation()
            guard let range = deepChunkRange(start: chunkStart, duration: duration),
                  let window = deepChunkWindow(for: range, duration: duration) else { break }
            let rangeStart = window.lowerBound
            let rangeEnd = window.upperBound
            let audio = try loadAudioChunk(url: url, start: rangeStart, end: rangeEnd)
            try Task.checkCancellation()
            guard !audio.isEmpty else { break }

            let windowCount = max(1, Int(ceil(Double(audio.count) / 480_000.0)))
            let results: [TranscriptionResult] = try await withTaskCancellationHandler {
                try await whisper.transcribe(
                    audioArray: audio,
                    decodeOptions: options,
                    callback: { update in
                        let localFraction = min(1, Double(update.windowId + 1) / Double(windowCount))
                        let fraction = min(0.99,
                                           (range.lowerBound
                                            + (range.upperBound - range.lowerBound) * localFraction) / duration)
                        if gate.shouldReport(fraction) {
                            onUpdate(TranscriptionSnapshot(lines: [], fraction: fraction,
                                                           message: "正在深入识别歌词…"))
                        }
                        return !cancellation.isCancelled
                    }
                )
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()

            let chunkWords = extractWords(results: results, timeOffset: rangeStart)
                .filter { owns($0, in: range, includesUpperBound: range.upperBound == duration) }
            words.append(contentsOf: chunkWords)
            words.sort { $0.start < $1.start }
            chunkStart = range.upperBound
            onUpdate(TranscriptionSnapshot(lines: LyricComposer.compose(words: words),
                                           fraction: min(0.99, chunkStart / duration),
                                           message: "正在深入识别歌词…"))
        }

        return LyricComposer.compose(words: words)
    }

    static func deepChunkRange(start: Double, duration: Double) -> Range<Double>? {
        guard start.isFinite, duration.isFinite,
              start >= 0, start < duration else { return nil }
        return start..<min(duration, start + deepChunkSeconds)
    }

    static func deepChunkWindow(for range: Range<Double>, duration: Double) -> Range<Double>? {
        guard duration.isFinite, duration > 0,
              range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound >= 0, range.lowerBound < range.upperBound,
              range.upperBound <= duration else { return nil }
        let lowerBound = max(0, range.lowerBound - deepChunkOverlapSeconds)
        let upperBound = min(duration, range.upperBound + deepChunkOverlapSeconds)
        return lowerBound..<upperBound
    }

    static func owns(_ word: LyricWord, in range: Range<Double>,
                     includesUpperBound: Bool) -> Bool {
        let midpoint = word.start + word.duration / 2
        guard midpoint >= range.lowerBound else { return false }
        return includesUpperBound ? midpoint <= range.upperBound : midpoint < range.upperBound
    }

    // MARK: - 语言探测（切片 + 转写一小段）

    private static func detectLanguage(url: URL, duration: Double, whisper: WhisperKit) async -> String? {
        let start = duration > 90 ? duration * 0.25 : 0
        let length = min(30, duration - start)
        guard length > 8 else { return nil }
        guard let audio = try? loadAudioChunk(url: url, start: start, end: start + length),
              !audio.isEmpty else { return nil }

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = nil
        options.detectLanguage = true
        options.wordTimestamps = false

        let cancellation = TranscriptionCancellationState()
        let results: [TranscriptionResult]
        do {
            results = try await withTaskCancellationHandler {
                try await whisper.transcribe(
                    audioArray: audio,
                    decodeOptions: options,
                    callback: { _ in !cancellation.isCancelled }
                )
            } onCancel: {
                cancellation.cancel()
            }
        } catch {
            return nil
        }
        // 只有当探测段真的识别出了内容，检测到的语言才可信
        let text = results.flatMap { $0.segments }
            .map { cleanSegmentText($0.text) }
            .joined()
        guard text.count >= 6 else { return nil }
        return results.first?.language
    }

    // MARK: - 结果组装

    private static func extractWords(results: [TranscriptionResult], timeOffset: Double) -> [LyricWord] {
        var words: [LyricWord] = []
        for result in results {
            for segment in result.segments {
                // 整段是 [Music]、(applause) 之类的标注 → 丢弃
                guard !isAnnotation(cleanSegmentText(segment.text)) else { continue }

                if let segmentWords = segment.words, !segmentWords.isEmpty {
                    for w in segmentWords {
                        let text = cleanSegmentText(w.word)
                        guard !text.isEmpty, !isAnnotation(text) else { continue }
                        let word = LyricWord(text: text,
                                             start: Double(w.start) + timeOffset,
                                             duration: Double(max(0.01, w.end - w.start)))
                        words.append(contentsOf: subdivideCJK(word))
                    }
                } else {
                    let text = cleanSegmentText(segment.text)
                    guard !text.isEmpty, !isAnnotation(text) else { continue }
                    let word = LyricWord(text: text,
                                         start: Double(segment.start) + timeOffset,
                                         duration: Double(max(0.05, segment.end - segment.start)))
                    words.append(contentsOf: subdivideCJK(word))
                }
            }
        }
        return words
    }

    static func loadAudioChunk(url: URL, start: Double, end: Double) throws -> [Float] {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw TranscriptionError.cannotReadAudio
        }
        let safeStart = max(0, start)
        let safeEnd = min(end, Double(file.length) / sampleRate)
        guard safeEnd > safeStart else { return [] }
        let chunkDuration = safeEnd - safeStart
        guard chunkDuration <= deepChunkSeconds + deepChunkOverlapSeconds * 2 else {
            throw TranscriptionError.cannotReadAudio
        }
        guard let startFrame = framePosition(seconds: safeStart,
                                             sampleRate: sampleRate,
                                             maximum: file.length,
                                             rounding: .down),
              let endFrame = framePosition(seconds: safeEnd,
                                           sampleRate: sampleRate,
                                           maximum: file.length,
                                           rounding: .up),
              endFrame > startFrame else {
            throw TranscriptionError.cannotReadAudio
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(ceil(chunkDuration * 16_000)))
        let timeBoundedReadFrames = AVAudioFramePosition(max(1,
            min(Double(maximumInputReadFrames), sampleRate * inputReadSeconds).rounded(.down)))
        file.framePosition = startFrame
        while file.framePosition < endFrame {
            try Task.checkCancellation()
            let remaining = endFrame - file.framePosition
            let frameCount = AVAudioFrameCount(min(remaining, timeBoundedReadFrames))
            let chunk = try autoreleasepool { () throws -> [Float] in
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: frameCount) else {
                    throw TranscriptionError.cannotReadAudio
                }
                try file.read(into: input, frameCount: frameCount)
                guard input.frameLength > 0,
                      let mono = AudioProcessor.convertToMono(input, mode: .sumChannels(nil)) else {
                    throw TranscriptionError.cannotReadAudio
                }
                let normalized: AVAudioPCMBuffer
                if mono.format.sampleRate == 16_000, mono.format.channelCount == 1 {
                    normalized = mono
                } else {
                    guard let resampled = AudioProcessor.resampleAudio(fromBuffer: mono,
                                                                       toSampleRate: 16_000,
                                                                       channelCount: 1) else {
                        throw TranscriptionError.cannotReadAudio
                    }
                    normalized = resampled
                }
                return AudioProcessor.convertBufferToArray(buffer: normalized)
            }
            samples.append(contentsOf: chunk)
        }
        try Task.checkCancellation()
        return samples
    }

    private static func framePosition(seconds: Double,
                                      sampleRate: Double,
                                      maximum: AVAudioFramePosition,
                                      rounding: FloatingPointRoundingRule) -> AVAudioFramePosition? {
        let value = seconds * sampleRate
        guard value.isFinite, value >= 0, value <= maximumExactFramePosition,
              maximum >= 0 else { return nil }
        let rounded = value.rounded(rounding)
        let safeMaximum = min(Double(maximum), maximumExactFramePosition)
        guard rounded <= safeMaximum else { return nil }
        return AVAudioFramePosition(rounded)
    }

    /// 把多字的中文词按字均分时间戳，让逐字点亮更平滑。
    private static func subdivideCJK(_ word: LyricWord) -> [LyricWord] {
        let chars = Array(word.text)
        let cjkCount = chars.filter { $0.isCJK }.count
        guard cjkCount >= 2, chars.count >= 2 else { return [word] }
        let per = word.duration / Double(chars.count)
        return chars.enumerated().map { index, char in
            LyricWord(text: String(char),
                      start: word.start + Double(index) * per,
                      duration: per)
        }
    }

    /// 去掉 Whisper 特殊标记（<|zh|> 等）与音符符号，并修剪空白。
    private static func cleanSegmentText(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "♪", with: "")
        out = out.replacingOccurrences(of: "♫", with: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否为非语音标注，如 [Music]、(music)、【音乐】。
    private static func isAnnotation(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        return text.range(of: #"^[\[\(【（].*[\]\)】）]$"#, options: .regularExpression) != nil
    }

    // MARK: - 模型加载 / 下载

    private static func loadPipeline(onUpdate: @escaping TranscriptionUpdateHandler) async throws -> WhisperKit {
        try Task.checkCancellation()

        // single-flight：模型加载并不完整支持取消，底层结束前始终保留同一趟任务，
        // 避免快速切歌叠出多份 Core ML 模型；等待者本身仍可立即退出。
        let state: (cached: WhisperKit?, flight: Task<WhisperKit, Error>?) = pipelineLock.withLock {
            if let cachedPipeline { return (cachedPipeline, nil) }
            if let loadingTask { return (nil, loadingTask) }
            loadingGeneration &+= 1
            let generation = loadingGeneration
            let fresh = Task {
                do {
                    let pipeline = try await doLoadPipeline(onUpdate: onUpdate)
                    let installed = pipelineLock.withLock {
                        guard loadingGeneration == generation else { return false }
                        cachedPipeline = pipeline
                        loadingTask = nil
                        return true
                    }
                    if installed { installMemoryPressureHandler() }
                    return pipeline
                } catch {
                    pipelineLock.withLock {
                        if loadingGeneration == generation { loadingTask = nil }
                    }
                    throw error
                }
            }
            loadingTask = fresh
            return (nil, fresh)
        }
        if let cached = state.cached { return cached }
        guard let flight = state.flight else { throw TranscriptionError.recognizerUnavailable }
        let pipeline = try await cancellableValue(of: flight)
        try Task.checkCancellation()
        return pipeline
    }

    private static func cancellableValue(of task: Task<WhisperKit, Error>) async throws -> WhisperKit {
        let waiter = PipelineWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task.detached(priority: .utility) {
                    waiter.complete(await task.result)
                }
            }
        } onCancel: {
            waiter.cancel()
        }
    }

    private static func doLoadPipeline(onUpdate: @escaping TranscriptionUpdateHandler) async throws -> WhisperKit {
        // 候选目录按优先级：手动放置 > App 内置 > 之前自动下载。
        // 只探测单个文件是否存在不够——目录可能半损坏（下载中断/用户误删），
        // 所以初始化失败就跳到下一个候选，全灭后走下载自愈。
        var candidates: [URL] = []
        let manual = modelsRoot.appendingPathComponent(modelName, isDirectory: true)
        if FileManager.default.fileExists(atPath: manual.appendingPathComponent("MelSpectrogram.mlmodelc").path) {
            candidates.append(manual)
        }
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("WhisperModel/openai_whisper-\(modelName)", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("MelSpectrogram.mlmodelc").path) {
            candidates.append(bundled)
        }
        let auto = modelsRoot.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(modelName)", isDirectory: true)
        if FileManager.default.fileExists(atPath: auto.appendingPathComponent("MelSpectrogram.mlmodelc").path) {
            candidates.append(auto)
        }

        for candidate in candidates {
            try Task.checkCancellation()
            do {
                onUpdate(TranscriptionSnapshot(lines: [], fraction: nil, message: "正在准备歌词…"))
                return try await WhisperKit(WhisperKitConfig(modelFolder: candidate.path))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                NSLog("语音模型目录不可用（\(candidate.lastPathComponent)），尝试下一来源：\(error.localizedDescription)")
            }
        }

        // 全部候选失效 → 重新下载（带进度）
        try Task.checkCancellation()
        let gate = ProgressGate()
        let downloadMessage = "正在下载语音模型（约 500 MB，仅首次）…"
        onUpdate(TranscriptionSnapshot(lines: [], fraction: 0, message: downloadMessage))
        let downloader = ModelDownloader(config: ModelDownloadConfig(
            modelRepo: modelRepository,
            revision: modelRevision
        ))
        let root = try await downloader.resolveRepo(
            patterns: ["openai_whisper-\(modelName)/**"],
            downloadBase: modelsRoot
        ) { progress in
            let fraction = progress.fractionCompleted
            if gate.shouldReport(fraction) {
                onUpdate(TranscriptionSnapshot(lines: [], fraction: fraction, message: downloadMessage))
            }
        }
        let folder = root.appendingPathComponent("openai_whisper-\(modelName)", isDirectory: true)
        try Task.checkCancellation()
        onUpdate(TranscriptionSnapshot(lines: [], fraction: nil, message: "正在准备歌词…"))
        return try await WhisperKit(WhisperKitConfig(modelFolder: folder.path))
    }

    /// 内存吃紧时放掉常驻模型（约 0.6-1GB RSS），下次识别时重新加载。
    private static func installMemoryPressureHandler() {
        pipelineLock.lock(); defer { pipelineLock.unlock() }
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            pipelineLock.withLock {
                guard loadingTask == nil, cachedPipeline != nil else { return }
                cachedPipeline = nil
                NSLog("内存压力：已释放 Whisper 推理管线（下次识别自动重载）")
            }
        }
        source.activate()
        pressureSource = source
    }
}

private final class TranscriptionCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private final class PipelineWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WhisperKit, Error>?
    private var result: Result<WhisperKit, Error>?
    private var cancelled = false

    func install(_ continuation: CheckedContinuation<WhisperKit, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func complete(_ result: Result<WhisperKit, Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        guard let continuation else {
            self.result = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let continuation = continuation
        self.continuation = nil
        result = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

/// 限频器：进度变化不足 1% 时不上报，避免高频刷新 UI 造成卡顿。
private final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0

    func shouldReport(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fraction - last >= 0.01 else { return false }
        last = fraction
        return true
    }
}

#endif
