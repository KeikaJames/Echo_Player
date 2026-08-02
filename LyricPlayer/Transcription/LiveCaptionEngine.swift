import Foundation
import Observation
import AVFoundation
import Speech
import AppKit
#if canImport(FluidAudio)
import FluidAudio
#endif

/// 一条已定稿的实时字幕。
struct CaptionEntry: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    var text: String
    /// 说话人编号（1 起）；说话人分离未就绪时为 nil。
    var speaker: Int?
    /// 该句在麦克风音频流中的时间范围（秒），用于与说话人分段对齐。
    var timeRange: ClosedRange<Double>?
    /// 所属聆听会话代：停止→继续后，旧会话条目不再被新会话的说话人分段改写
    /// （两轮会话的时间轴都从 0 起算，不隔离必然错标）。
    var session: Int = 0
}

enum LiveCaptionState: Equatable {
    case idle
    case starting
    case listening
    case error(String)
}

/// 麦克风实时会议转写：流式识别文本 + 说话人分离（谁在说话）。
/// - 文本：macOS 26 SpeechAnalyzer 流式模块（volatile 实时上屏、final 定稿），旧系统回退 SFSpeech；
/// - 说话人：FluidAudio（pyannote 分割 + WeSpeaker 声纹，CoreML 全本地），
///   每 5 秒对整段会话音频重新聚类，识别在场人数并把每句话标到对应说话人。
@Observable
final class LiveCaptionSession {
    /// 全应用共享一个会话：关窗只停止聆听，不销毁记录——
    /// 重开窗口记录还在（误关一次窗不再等于整场会议蒸发）。
    static let shared = LiveCaptionSession()

    var entries: [CaptionEntry] = []
    var volatileText: String = ""
    /// 引擎状态提示（如"正在下载语言模型…"）：独立于 volatileText，
    /// 永远不会被定稿成字幕条目。
    var statusText: String = ""
    var state: LiveCaptionState = .idle
    /// 说话人分离识别到的在场人数（0 = 分离未就绪）。
    var speakerCount: Int = 0
    /// 本次聆听开始时刻（时长计时用）。
    var startedAt: Date?

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    // 会话代号：主线程写、音频 tap 线程与后台任务读，所有访问一律过 genLock
    //（直接读写裸 Int 是 data race，TSan 会报；对照 EnginePlayer 的主线程封闭方案，
    // 这里因为 tap 线程要参与判代，只能用锁）。legacyRequest 同锁保护。
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let genLock = NSLock()
    // start() 的启动流程句柄：stop() 时取消，配合提交段检查，
    // 杜绝"启动中被停止后引擎照样把麦克风打开"的隐私泄漏
    @ObservationIgnored private var startTask: Task<Void, Never>?

    // macOS 26 路径持有的对象（用 AnyObject 存以避免可用性标注扩散）
    @ObservationIgnored private var modernBackend: AnyObject?

    // 旧路径
    @ObservationIgnored private var legacyRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var legacyTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var legacyRetryStreak = 0   // 连续快败计数（防无限重试）

    // 说话人分离：16kHz 单声道会话音频缓冲（也用于导出录音）
    @ObservationIgnored private let diarLock = NSLock()
    @ObservationIgnored private var diarAudio: [Float] = []
    @ObservationIgnored private var diarTrimmedSeconds: Double = 0   // 缓冲裁剪掉的头部时长
    @ObservationIgnored private var diarTask: Task<Void, Never>?
    @ObservationIgnored private var speakerOrder: [String] = []      // speakerId → 编号（出现顺序）
    private static let diarSampleRate = 16000.0
    private static let diarMaxSeconds = 15.0 * 60                    // 缓冲上限 15 分钟

    var isListening: Bool { state == .listening || state == .starting }

    // MARK: - 开始 / 停止

    func start() {
        guard !isListening else { return }
        state = .starting
        startedAt = Date()
        let gen = bumpGeneration()

        startTask = Task { [weak self] in
            guard let self else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard !Task.isCancelled, self.currentGeneration() == gen else { return }
            guard granted else {
                await MainActor.run {
                    guard self.currentGeneration() == gen else { return }
                    self.state = .error("未获得麦克风权限。请在「系统设置 › 隐私与安全性 › 麦克风」中允许本 App。")
                }
                return
            }
            let locale = AutoTranscriber.systemLocale()

            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                do {
                    try await self.startModern(locale: locale, gen: gen)
                    await MainActor.run {
                        if self.currentGeneration() == gen { self.state = .listening }
                    }
                    self.startDiarizationLoop(gen: gen)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    NSLog("实时字幕 SpeechAnalyzer 启动失败，回退旧引擎：\(error.localizedDescription)")
                    self.teardownAudio()
                }
            }
            #endif

            do {
                try await self.startLegacy(locale: locale, gen: gen)
                await MainActor.run {
                    if self.currentGeneration() == gen { self.state = .listening }
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard self.currentGeneration() == gen else { return }
                    self.teardownAudio()
                    self.state = .error(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        // 先取消启动流程：正处于"启动中"（权限弹窗/模型下载）时停止，
        // 提交段（见 startModern/startLegacy）会因取消或判代失败而放弃开麦
        startTask?.cancel()
        startTask = nil

        // 把尚未定稿的内容落为一条字幕（归属当前会话代，bump 之前）
        let pending = volatileText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty {
            entries.append(CaptionEntry(date: Date(), text: pending,
                                        speaker: nil, timeRange: nil, session: currentGeneration()))
        }
        volatileText = ""
        statusText = ""
        _ = bumpGeneration()

        diarTask?.cancel()
        diarTask = nil
        teardownAudio()

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let backend = modernBackend as? ModernLiveBackend {
            backend.shutdown()
        }
        #endif
        modernBackend = nil

        legacyTask?.cancel()
        legacyTask = nil
        let request: SFSpeechAudioBufferRecognitionRequest? = genLock.withLock {
            let r = legacyRequest
            legacyRequest = nil
            return r
        }
        request?.endAudio()
        legacyRecognizer = nil

        state = .idle
    }

    func restart() {
        stop()
        start()
    }

    private func teardownAudio() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    // MARK: - 会话代号（跨线程访问一律走这两个方法）

    private func bumpGeneration() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        generation += 1
        return generation
    }

    private func currentGeneration() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        return generation
    }

    // MARK: - 说话人分离

    /// 音频线程调用：累积 16kHz 单声道样本。
    private func appendDiarizationAudio(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        diarLock.lock()
        diarAudio.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
        // 超限后按分钟级大块裁剪：若逐回调裁剪，达到上限后每次 tap 都要整段
        // memmove ~14M 个样本（~670MB/s 的无效搬移，还都发生在锁内）
        let maxSamples = Int(Self.diarMaxSeconds * Self.diarSampleRate)
        let slack = Int(60 * Self.diarSampleRate)
        if diarAudio.count > maxSamples + slack {
            let drop = diarAudio.count - maxSamples
            diarAudio.removeFirst(drop)
            diarTrimmedSeconds += Double(drop) / Self.diarSampleRate
        }
        diarLock.unlock()
    }

    /// 每 5 秒对整段会话音频跑一次说话人聚类，回填每句字幕的说话人编号。
    private func startDiarizationLoop(gen: Int) {
        #if canImport(FluidAudio)
        diarTask = Task { [weak self] in
            await DiarizationWorker.shared.resetFailureLatch()   // 新会话重新给模型加载一次机会
            var interval = 3.0   // 首轮 3 秒，尽快出现说话人标注
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, self.currentGeneration() == gen else { return }

                self.diarLock.lock()
                // 显式深拷贝：直接赋值是 COW 共享，下一次 tap 追加时会在音频回调里
                // 触发整缓冲（最大 57MB）的隐式拷贝；在这里拷则 tap 最多短暂等锁
                let samples = self.diarAudio.withUnsafeBufferPointer { Array($0) }
                let offset = self.diarTrimmedSeconds
                self.diarLock.unlock()

                let bufferSeconds = Double(samples.count) / Self.diarSampleRate
                // 全量重聚类的代价随缓冲线性涨：间隔随之拉大（15 分钟缓冲 ≈ 45s 一轮），
                // 否则长会话时上一轮还没算完下一轮又排上，ANE 被钉死
                interval = max(5.0, bufferSeconds * 0.05)
                guard bufferSeconds >= 4 else { continue }

                guard let segments = await DiarizationWorker.shared.diarize(samples, offset: offset) else { continue }
                await MainActor.run {
                    guard self.currentGeneration() == gen else { return }
                    self.applyDiarization(segments, gen: gen)
                }
            }
        }
        #endif
    }

    /// 把说话人分段套到已定稿的字幕句子上（按时间区间重叠最大者）。
    /// 只标注当前会话代的条目：旧会话的时间轴同样从 0 起算，不隔离必然错标。
    private func applyDiarization(_ segments: [(speakerId: String, start: Double, end: Double)], gen: Int) {
        for segment in segments where !speakerOrder.contains(segment.speakerId) {
            speakerOrder.append(segment.speakerId)
        }
        speakerCount = speakerOrder.count

        for index in entries.indices where entries[index].session == gen {
            guard let range = entries[index].timeRange else { continue }
            var best: (id: String, overlap: Double)?
            for segment in segments {
                let overlap = min(range.upperBound, segment.end) - max(range.lowerBound, segment.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (segment.speakerId, overlap)
                }
            }
            if let best, let order = speakerOrder.firstIndex(of: best.id) {
                entries[index].speaker = order + 1
            }
        }
    }

    // MARK: - 文本操作

    func clear() {
        entries.removeAll()
        volatileText = ""
        statusText = ""
    }

    var transcriptText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return entries.map { entry in
            let who = entry.speaker.map { "说话人\($0)：" } ?? ""
            return "[\(formatter.string(from: entry.date))] \(who)\(entry.text)"
        }.joined(separator: "\n")
    }

    func copyAll() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcriptText, forType: .string)
    }

    func saveToFile() {
        guard !entries.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        panel.nameFieldStringValue = "会议记录 \(stamp.string(from: Date())).txt"
        panel.prompt = "保存"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcriptText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Self.presentSaveFailure(error)   // 磁盘满/卷只读时必须让用户知道，记录还在窗口里
        }
    }

    /// 导出本次会话的录音（16kHz 单声道 WAV）。
    func saveRecording() {
        diarLock.lock()
        let samples = diarAudio
        diarLock.unlock()
        guard !samples.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        panel.nameFieldStringValue = "录音 \(stamp.string(from: Date())).wav"
        panel.prompt = "保存"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.diarSampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.diarSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        } catch {
            Self.presentSaveFailure(error)
        }
    }

    private static func presentSaveFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "保存失败"
        alert.informativeText = "文件未能写入：\(error.localizedDescription)\n记录仍保留在窗口中，请换个位置重试。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 结果上屏（统一入口）

    private func deliver(text: String, isFinal: Bool, gen: Int, range: ClosedRange<Double>? = nil) {
        Task { @MainActor [weak self] in
            guard let self, self.currentGeneration() == gen else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isFinal {
                if !trimmed.isEmpty {
                    self.entries.append(CaptionEntry(date: Date(), text: trimmed,
                                                     speaker: nil, timeRange: range, session: gen))
                }
                self.volatileText = ""
            } else {
                self.volatileText = trimmed
            }
        }
    }

    // MARK: - macOS 26：SpeechAnalyzer 流式识别

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private final class ModernLiveBackend {
        let analyzer: SpeechAnalyzer
        let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
        var resultsTask: Task<Void, Never>?

        init(analyzer: SpeechAnalyzer, inputBuilder: AsyncStream<AnalyzerInput>.Continuation) {
            self.analyzer = analyzer
            self.inputBuilder = inputBuilder
        }

        func shutdown() {
            inputBuilder.finish()
            let analyzer = self.analyzer
            let task = resultsTask
            Task {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                task?.cancel()
            }
        }
    }

    @available(macOS 26.0, *)
    private func startModern(locale: Locale, gen: Int) async throws {
        let supportedLocale = try await ModernSystemTranscriber.resolveSupportedLocale(for: locale)
        let transcriber = SpeechTranscriber(locale: supportedLocale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await MainActor.run {
                if self.currentGeneration() == gen { self.statusText = "正在下载语言模型…" }
            }
            try await request.downloadAndInstall()
            await MainActor.run {
                if self.currentGeneration() == gen { self.statusText = "" }
            }
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.recognizerUnavailable
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: inputSequence)

        let inputNode = audioEngine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw TranscriptionError.recognizerUnavailable
        }
        guard let converter = AVAudioConverter(from: micFormat, to: analyzerFormat) else {
            throw TranscriptionError.recognizerUnavailable
        }
        // 说话人分离用的 16kHz 单声道转换器
        guard let diarFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Self.diarSampleRate,
                                             channels: 1, interleaved: false),
              let diarConverter = AVAudioConverter(from: micFormat, to: diarFormat) else {
            throw TranscriptionError.recognizerUnavailable
        }

        // 重置会话音频缓冲（说话人状态属 UI，在下面的主线程提交段重置）
        diarLock.lock()
        diarAudio.removeAll()
        diarTrimmedSeconds = 0
        diarLock.unlock()

        let backend = ModernLiveBackend(analyzer: analyzer, inputBuilder: inputBuilder)
        backend.resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    var range: ClosedRange<Double>?
                    if result.isFinal {
                        let cmRange = result.range
                        let start = cmRange.start.seconds
                        let end = cmRange.end.seconds
                        if start.isFinite, end.isFinite, end > start {
                            range = start...end
                        }
                    }
                    self?.deliver(text: text, isFinal: result.isFinal, gen: gen, range: range)
                }
            } catch {
                guard let self else { return }
                await MainActor.run {
                    if self.currentGeneration() == gen, self.state == .listening {
                        self.state = .error("识别中断：\(error.localizedDescription)")
                        self.teardownAudio()
                        // 识别流已死，别让说话人循环继续空烧 CPU
                        self.diarTask?.cancel()
                        self.diarTask = nil
                    }
                }
            }
        }

        // 提交段（主线程，与 stop() 串行）：过了这道闸麦克风才真正开启。
        // 启动期间被停止/取消 → 在此抛出，catch 里收拾 analyzer，绝不留下常亮的麦克风。
        do {
            try await MainActor.run {
                guard !Task.isCancelled, self.currentGeneration() == gen else { throw CancellationError() }
                self.speakerOrder.removeAll()
                self.speakerCount = 0
                inputNode.removeTap(onBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
                    guard let self, self.currentGeneration() == gen else { return }
                    if let converted = Self.convert(buffer, with: converter, to: analyzerFormat) {
                        inputBuilder.yield(AnalyzerInput(buffer: converted))
                    }
                    if let converted16k = Self.convert(buffer, with: diarConverter, to: diarFormat) {
                        self.appendDiarizationAudio(converted16k)
                    }
                }
                self.audioEngine.prepare()
                try self.audioEngine.start()
                self.modernBackend = backend
            }
        } catch {
            backend.shutdown()   // 结束输入流并 finalize analyzer，避免结果任务悬挂
            throw error
        }
    }

    /// 把麦克风缓冲转换成目标采样格式。
    private static func convert(_ buffer: AVAudioPCMBuffer,
                                with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, statusPointer in
            if consumed {
                statusPointer.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPointer.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
    #endif

    // MARK: - 旧系统：SFSpeechRecognizer 流式识别

    private func startLegacy(locale: Locale, gen: Int) async throws {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptionError.notAuthorized }

        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }
        legacyRecognizer = recognizer

        let inputNode = audioEngine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw TranscriptionError.recognizerUnavailable
        }

        // 提交段（主线程，与 stop() 串行）：过了这道闸麦克风才真正开启
        try await MainActor.run {
            guard !Task.isCancelled, self.currentGeneration() == gen else { throw CancellationError() }
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
                guard let self, self.currentGeneration() == gen else { return }
                let request = self.genLock.withLock { self.legacyRequest }
                request?.append(buffer)
            }
            self.audioEngine.prepare()
            try self.audioEngine.start()
            self.legacyRetryStreak = 0
            self.startLegacyRequest(gen: gen)
        }
    }

    /// 一段话结束（isFinal）或出错（约 1 分钟限制）后自动开启新一轮识别。
    private func startLegacyRequest(gen: Int) {
        guard currentGeneration() == gen, let recognizer = legacyRecognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true  // 音频永不出本机
        request.taskHint = .dictation
        if #available(macOS 13.0, *) { request.addsPunctuation = true }
        genLock.withLock { legacyRequest = request }

        legacyTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.currentGeneration() == gen else { return }
                if let result {
                    self.legacyRetryStreak = 0   // 有产出即视为健康
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.deliver(text: text, isFinal: true, gen: gen)
                        self.startLegacyRequest(gen: gen)
                    } else {
                        self.deliver(text: text, isFinal: false, gen: gen)
                    }
                } else if error != nil {
                    // 服务器时长限制 / 静音超时等：静默续接；
                    // 但持久性故障（本地听写模型未装等）会立刻再失败——连续快败
                    // 超过 5 次就停下来报错，不做无限重试的死循环
                    self.legacyRetryStreak += 1
                    guard self.legacyRetryStreak <= 5 else {
                        self.stop()
                        self.state = .error("语音识别不可用。请在「系统设置 › 键盘 › 听写」中启用听写并下载离线语言。")
                        return
                    }
                    self.volatileText = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard self.currentGeneration() == gen, self.state == .listening else { return }
                        self.startLegacyRequest(gen: gen)
                    }
                }
            }
        }
    }
}

#if canImport(FluidAudio)
/// 说话人分离工作器：串行执行、独占非 Sendable 的 DiarizerManager。
/// 模型（pyannote 分割 + WeSpeaker 声纹）首次使用时自动下载，失败则优雅降级（字幕无说话人标注）。
actor DiarizationWorker {
    static let shared = DiarizationWorker()

    private var diarizer: DiarizerManager?
    private var loadFailed = false

    /// 新聆听会话开始时调用：给模型加载再一次机会
    /// （否则一次瞬时失败会闩死到进程退出，整场会议都没有说话人标注）。
    func resetFailureLatch() {
        loadFailed = false
    }

    /// 内置模型（随安装包分发，约 13MB）：开箱即用，永不下载。
    private static func loadBundledModels() throws -> DiarizerModels? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("DiarizerModels") else { return nil }
        let segmentation = root.appendingPathComponent("pyannote_segmentation.mlmodelc")
        let embedding = root.appendingPathComponent("wespeaker_v2.mlmodelc")
        guard FileManager.default.fileExists(atPath: segmentation.path),
              FileManager.default.fileExists(atPath: embedding.path) else { return nil }
        // 辅助参数文件（PLDA/xvector）同步到库的默认目录，部分工具从那里读取
        let defaultDir = DiarizerModels.defaultModelsDirectory()
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        for aux in ["config.json", "plda-parameters.json", "xvector-transform.json"] {
            let src = root.appendingPathComponent(aux)
            let dst = defaultDir.appendingPathComponent(aux)
            if FileManager.default.fileExists(atPath: src.path),
               !FileManager.default.fileExists(atPath: dst.path) {
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }
        return try DiarizerModels.load(localSegmentationModel: segmentation, localEmbeddingModel: embedding)
    }

    func diarize(_ samples: [Float], offset: Double) async -> [(speakerId: String, start: Double, end: Double)]? {
        if diarizer == nil {
            guard !loadFailed else { return nil }
            do {
                let models: DiarizerModels
                if let bundled = (try? Self.loadBundledModels()) ?? nil {
                    models = bundled
                } else {
                    models = try await DiarizerModels.downloadIfNeeded()
                }
                let manager = DiarizerManager()
                manager.initialize(models: models)
                diarizer = manager
            } catch {
                loadFailed = true
                NSLog("说话人分离模型不可用（将退回无标注字幕）：\(error.localizedDescription)")
                return nil
            }
        }
        guard let diarizer else { return nil }
        do {
            // 聚类可长达数秒-数十秒：放 detached 避免钉死协作线程池的线程；
            // actor 的 await 串行化保证 diarizer 仍是独占访问
            let result = try await Task.detached(priority: .utility) {
                try diarizer.performCompleteDiarization(samples)
            }.value
            return result.segments.map {
                (speakerId: $0.speakerId,
                 start: Double($0.startTimeSeconds) + offset,
                 end: Double($0.endTimeSeconds) + offset)
            }
        } catch {
            NSLog("说话人分离失败：\(error.localizedDescription)")
            return nil
        }
    }
}
#endif
