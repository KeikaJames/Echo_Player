#if canImport(WhisperKit)  // 只有添加了 WhisperKit 包依赖时才编译

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

    /// 常驻的推理管线：模型加载较慢，跨曲目复用。
    /// - single-flight：并发调用共享同一次加载，快速切歌时不会同时初始化两份 500MB 模型；
    /// - 收到系统内存压力警告时释放（正在使用的转写因 ARC 持有本地引用不受影响）。
    private static let pipelineLock = NSLock()
    private static var cachedPipeline: WhisperKit?
    private static var loadingTask: Task<WhisperKit, Error>?
    private static var pressureSource: DispatchSourceMemoryPressure?

    /// 模型存放目录。也支持手动下载模型放到这里离线使用（见 README）。
    static var modelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyricPlayer/WhisperModels", isDirectory: true)
    }

    static func transcribe(url: URL, duration: Double, onUpdate: @escaping TranscriptionUpdateHandler) async throws -> [LyricLine] {
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

        let progress = whisper.progress
        let gate = ProgressGate()
        let results = try await whisper.transcribe(audioPath: url.path, decodeOptions: options) { _ in
            let fraction = progress.fractionCompleted
            if gate.shouldReport(fraction) {
                onUpdate(TranscriptionSnapshot(lines: [], fraction: min(0.99, fraction),
                                               message: "正在深入识别歌词…"))
            }
            return !Task.isCancelled  // 返回 false 提前终止
        }
        try Task.checkCancellation()

        return compose(results: results)
    }

    // MARK: - 语言探测（切片 + 转写一小段）

    private static func detectLanguage(url: URL, duration: Double, whisper: WhisperKit) async -> String? {
        let start = duration > 90 ? duration * 0.25 : 0
        let length = min(30, duration - start)
        guard length > 8 else { return nil }
        guard let slice = try? AudioSlicer.slice(url: url, startSeconds: start, seconds: length) else { return nil }
        defer { try? FileManager.default.removeItem(at: slice) }

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = nil
        options.detectLanguage = true
        options.wordTimestamps = false

        guard let results = try? await whisper.transcribe(audioPath: slice.path, decodeOptions: options) else {
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

    private static func compose(results: [TranscriptionResult]) -> [LyricLine] {
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
                                             start: Double(w.start),
                                             duration: Double(max(0.01, w.end - w.start)))
                        words.append(contentsOf: subdivideCJK(word))
                    }
                } else {
                    let text = cleanSegmentText(segment.text)
                    guard !text.isEmpty, !isAnnotation(text) else { continue }
                    let word = LyricWord(text: text,
                                         start: Double(segment.start),
                                         duration: Double(max(0.05, segment.end - segment.start)))
                    words.append(contentsOf: subdivideCJK(word))
                }
            }
        }
        words.sort { $0.start < $1.start }
        return LyricComposer.compose(words: words)
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
        if let cached = pipelineLock.withLock({ cachedPipeline }) { return cached }

        // single-flight：已有加载在跑就搭车，否则自己开一趟
        let task: Task<WhisperKit, Error> = pipelineLock.withLock {
            if let running = loadingTask { return running }
            let fresh = Task { try await doLoadPipeline(onUpdate: onUpdate) }
            loadingTask = fresh
            return fresh
        }
        do {
            let pipeline = try await task.value
            pipelineLock.withLock {
                cachedPipeline = pipeline
                loadingTask = nil
            }
            installMemoryPressureHandler()
            return pipeline
        } catch {
            pipelineLock.withLock { loadingTask = nil }
            throw error
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
            do {
                onUpdate(TranscriptionSnapshot(lines: [], fraction: nil, message: "正在准备歌词…"))
                return try await WhisperKit(WhisperKitConfig(modelFolder: candidate.path))
            } catch {
                NSLog("语音模型目录不可用（\(candidate.lastPathComponent)），尝试下一来源：\(error.localizedDescription)")
            }
        }

        // 全部候选失效 → 重新下载（带进度）
        let gate = ProgressGate()
        let downloadMessage = "正在下载语音模型（约 500 MB，仅首次）…"
        onUpdate(TranscriptionSnapshot(lines: [], fraction: 0, message: downloadMessage))
        let folder = try await WhisperKit.download(variant: modelName, downloadBase: modelsRoot) { progress in
            let fraction = progress.fractionCompleted
            if gate.shouldReport(fraction) {
                onUpdate(TranscriptionSnapshot(lines: [], fraction: fraction, message: downloadMessage))
            }
        }
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
