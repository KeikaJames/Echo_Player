import Foundation
import Speech
import AVFoundation

/// 系统引擎入口：优先 macOS 26 的 SpeechAnalyzer，失败时回退 SFSpeechRecognizer。
enum SystemTranscriberChain {
    static func transcribe(url: URL, locale: Locale, onUpdate: @escaping TranscriptionUpdateHandler) async throws -> [LyricLine] {
        #if canImport(FoundationModels)  // 仅在 macOS 26 SDK 下编译新引擎
        if #available(macOS 26.0, *) {
            do {
                return try await ModernSystemTranscriber().transcribe(url: url, locale: locale, onUpdate: onUpdate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                NSLog("SpeechAnalyzer 转写失败，回退 SFSpeechRecognizer：\(error.localizedDescription)")
            }
        }
        #endif
        return try await LegacySystemTranscriber().transcribe(url: url, locale: locale, onUpdate: onUpdate)
    }
}

// MARK: - macOS 26：SpeechAnalyzer

#if canImport(FoundationModels)

/// 基于 macOS 26 SpeechAnalyzer / SpeechTranscriber 的文件转写。
/// 全程离线、支持长音频，结果自带逐词时间区间。
@available(macOS 26.0, *)
struct ModernSystemTranscriber {
    func transcribe(url: URL, locale: Locale, onUpdate: @escaping TranscriptionUpdateHandler) async throws -> [LyricLine] {
        let resolvedLocale = try await Self.resolveSupportedLocale(for: locale)

        let transcriber = SpeechTranscriber(locale: resolvedLocale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])

        // 首次使用某语言时需要下载识别模型
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onUpdate(TranscriptionSnapshot(lines: [], fraction: nil, message: "正在准备歌词…"))
            try await request.downloadAndInstall()
        }

        guard let file = try? AVAudioFile(forReading: url) else {
            throw TranscriptionError.cannotReadAudio
        }
        let totalSeconds = Double(file.length) / file.processingFormat.sampleRate

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // 先启动结果收集，再喂音频
        let collector = Task { () -> [LyricWord] in
            var words: [LyricWord] = []
            for try await result in transcriber.results {
                let attributed = result.text
                for run in attributed.runs {
                    let segment = String(attributed[run.range].characters)
                    if let timeRange = run.audioTimeRange {
                        words.append(LyricWord(text: segment,
                                               start: timeRange.start.seconds,
                                               duration: max(0.01, timeRange.duration.seconds)))
                    } else if !words.isEmpty {
                        // 标点、空白等无时间信息的片段并入前一个词
                        words[words.count - 1].text += segment
                    }
                }
                let lines = LyricComposer.compose(words: words)
                let fraction = totalSeconds > 0 ? min(1.0, (words.last?.end ?? 0) / totalSeconds) : nil
                onUpdate(TranscriptionSnapshot(lines: lines, fraction: fraction, message: nil))
            }
            return words
        }

        do {
            try await withTaskCancellationHandler {
                if let lastSampleTime = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: lastSampleTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collector.cancel()
            throw error
        }

        let words = try await collector.value
        try Task.checkCancellation()
        return LyricComposer.compose(words: words)
    }

    /// 精确匹配失败时退到同语言的受支持地区（如 zh-Hans-CN → zh-CN）。
    /// 实时字幕引擎也会复用此方法。
    static func resolveSupportedLocale(for locale: Locale) async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let wanted = locale.identifier(.bcp47).lowercased()
        if let exact = supported.first(where: { $0.identifier(.bcp47).lowercased() == wanted }) {
            return exact
        }
        let wantedLang = locale.language.languageCode?.identifier
        if let sameLanguage = supported.first(where: { $0.language.languageCode?.identifier == wantedLang }) {
            return sameLanguage
        }
        throw TranscriptionError.unsupportedLocale(locale.identifier)
    }
}

#endif

// MARK: - 旧系统回退：SFSpeechRecognizer（macOS 13+）

/// 基于 SFSpeechRecognizer 的文件转写。
/// 服务器识别有约 1 分钟限制，因此把音频切成 55 秒片段逐段识别再拼接时间轴。
struct LegacySystemTranscriber {
    private static let chunkSeconds = 55.0

    func transcribe(url: URL, locale: Locale, onUpdate: @escaping TranscriptionUpdateHandler) async throws -> [LyricLine] {
        try await Self.requestAuthorization()

        guard let recognizer = Self.makeRecognizer(for: locale) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }
        guard recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }
        // 隐私承诺：音频永不出本机，不支持本机识别就直接报不可用
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.recognizerUnavailable
        }
        let onDevice = true

        guard let file = try? AVAudioFile(forReading: url) else {
            throw TranscriptionError.cannotReadAudio
        }
        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let totalSeconds = Double(totalFrames) / sampleRate
        guard totalSeconds > 0.1 else { return [] }

        var allWords: [LyricWord] = []
        let chunkFrames = AVAudioFramePosition(Self.chunkSeconds * sampleRate)
        var position: AVAudioFramePosition = 0

        while position < totalFrames {
            try Task.checkCancellation()
            let framesToRead = AVAudioFrameCount(min(chunkFrames, totalFrames - position))
            let offsetSeconds = Double(position) / sampleRate

            let chunkURL = try Self.writeChunk(from: file, start: position, frames: framesToRead)
            defer { try? FileManager.default.removeItem(at: chunkURL) }

            let segments = try await Self.recognizeFile(chunkURL, recognizer: recognizer, onDevice: onDevice)
            for seg in segments {
                allWords.append(LyricWord(text: seg.substring,
                                          start: seg.timestamp + offsetSeconds,
                                          duration: max(0.01, seg.duration)))
            }
            position += AVAudioFramePosition(framesToRead)

            let lines = LyricComposer.compose(words: allWords)
            let fraction = min(1.0, Double(position) / Double(totalFrames))
            onUpdate(TranscriptionSnapshot(lines: lines, fraction: fraction, message: nil))
        }

        return LyricComposer.compose(words: allWords)
    }

    // 精确匹配失败时，退而找同语言的可用识别器（如 zh-TW → zh-CN）。
    private static func makeRecognizer(for locale: Locale) -> SFSpeechRecognizer? {
        if let exact = SFSpeechRecognizer(locale: locale) { return exact }
        let wantedLang = locale.language.languageCode?.identifier
        let fallback = SFSpeechRecognizer.supportedLocales().first {
            $0.language.languageCode?.identifier == wantedLang
        }
        return fallback.flatMap { SFSpeechRecognizer(locale: $0) }
    }

    private static func requestAuthorization() async throws {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptionError.notAuthorized }
    }

    /// 把源文件的一段导出为临时 CAF 文件。
    private static func writeChunk(from file: AVAudioFile, start: AVAudioFramePosition, frames: AVAudioFrameCount) throws -> URL {
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw TranscriptionError.cannotReadAudio
        }
        file.framePosition = start
        try file.read(into: buffer, frameCount: frames)

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyric-chunk-\(UUID().uuidString).caf")
        let outFile = try AVAudioFile(forWriting: tmpURL, settings: format.settings)
        try outFile.write(from: buffer)
        return tmpURL
    }

    private static func recognizeFile(_ url: URL, recognizer: SFSpeechRecognizer, onDevice: Bool) async throws -> [SFTranscriptionSegment] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation
        if #available(macOS 13.0, *) { request.addsPunctuation = true }

        let box = RecognitionBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[SFTranscriptionSegment], Error>) in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        let nsError = error as NSError
                        // “未检测到语音”不算失败，返回空段落
                        let isNoSpeech = nsError.code == 1110 || nsError.localizedDescription.contains("No speech")
                        box.resumeOnce {
                            if isNoSpeech {
                                cont.resume(returning: [])
                            } else if box.cancelled {
                                cont.resume(throwing: CancellationError())
                            } else {
                                cont.resume(throwing: error)
                            }
                        }
                        return
                    }
                    guard let result, result.isFinal else { return }
                    box.resumeOnce {
                        cont.resume(returning: result.bestTranscription.segments)
                    }
                }
                box.task = task
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// 保护 continuation 只 resume 一次，并桥接取消。
private final class RecognitionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private(set) var cancelled = false
    var task: SFSpeechRecognitionTask?

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

/// 音频切片：把文件的某一段导出为临时 CAF，用于语言探测等。
enum AudioSlicer {
    static func slice(url: URL, startSeconds: Double, seconds: Double) throws -> URL {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { throw TranscriptionError.cannotReadAudio }

        let startFrame = AVAudioFramePosition(max(0, startSeconds) * sampleRate)
        let available = max(0, file.length - startFrame)
        let frames = AVAudioFrameCount(min(seconds * sampleRate, Double(available)))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw TranscriptionError.cannotReadAudio
        }
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frames)

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyric-slice-\(UUID().uuidString).caf")
        let outFile = try AVAudioFile(forWriting: tmpURL, settings: format.settings)
        try outFile.write(from: buffer)
        return tmpURL
    }
}
