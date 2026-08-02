import Foundation
import AVFoundation
import NaturalLanguage

/// 转写过程中的进度快照。
struct TranscriptionSnapshot: Sendable {
    var lines: [LyricLine]
    var fraction: Double?     // 0...1，nil 表示不确定进度
    var message: String?      // 覆盖默认状态文案
}

typealias TranscriptionUpdateHandler = @Sendable (TranscriptionSnapshot) -> Void

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case unsupportedLocale(String)
    case recognizerUnavailable
    case cannotReadAudio

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "未获得语音识别权限。请在「系统设置 › 隐私与安全性 › 语音识别」中允许本 App。"
        case .unsupportedLocale(let id):
            return "系统语音识别不支持当前语言（\(id)）。"
        case .recognizerUnavailable:
            return "语音识别服务暂时不可用，请稍后重试。"
        case .cannotReadAudio:
            return "无法读取该音频文件。"
        }
    }
}

/// 全自动识别管线（无任何用户配置，像 Apple Music 一样开箱即用）：
///
/// 1. 先用系统引擎按系统语言快速识别——台词、播客、有声书、清唱几秒内出结果；
/// 2. 程序自动评估结果是否可靠（行数、文本密度、语言一致性）；
/// 3. 不可靠（伴奏重的歌曲、外语内容）时自动改用 Whisper 深度识别，
///    语言由模型直接从音频检测，无需任何人工选择。
enum AutoTranscriber {
    static func transcribe(url: URL, onUpdate: @escaping TranscriptionUpdateHandler) async throws -> [LyricLine] {
        // FFmpeg 专属格式（mkv/webm/opus/ape/wma…）AVAudioFile 打不开：识别管线
        // 全程依赖 AVAudioFile/AVAudioEngine，这里直接返回空，避免崩溃或卡死。
        guard (try? AVAudioFile(forReading: url)) != nil else { return [] }

        let locale = systemLocale()
        let duration = audioDuration(url: url)

        // 第 1 步：系统引擎快速识别
        var draft: [LyricLine] = []
        do {
            draft = try await SystemTranscriberChain.transcribe(url: url, locale: locale, onUpdate: onUpdate)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("快速识别失败，将直接深入识别：\(error.localizedDescription)")
        }
        try Task.checkCancellation()

        if isReliable(draft, duration: duration, locale: locale) {
            return draft
        }

        // 第 2 步：Whisper 深度识别（切片探测语言后整曲识别，适合歌曲/外语）。
        // 模型只是"优化器"：草稿有内容时保持展示，识别完成后静默替换。
        #if canImport(WhisperKit)
        let visibleDraft = draft
        onUpdate(TranscriptionSnapshot(lines: visibleDraft, fraction: nil,
                                       message: visibleDraft.isEmpty ? "正在深入识别歌词…" : nil))
        do {
            let deep = try await WhisperTranscriber.transcribe(url: url, duration: duration) { snapshot in
                // 有草稿垫底时不清空屏幕，只透传进度
                let lines = snapshot.lines.isEmpty ? visibleDraft : snapshot.lines
                onUpdate(TranscriptionSnapshot(lines: lines, fraction: snapshot.fraction, message: snapshot.message))
            }
            try Task.checkCancellation()
            if !deep.isEmpty { return deep }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("深入识别失败：\(error.localizedDescription)")
            // 深入识别失败但快速识别有内容时，退回快速结果
            if draft.isEmpty { throw error }
        }
        #endif

        return draft
    }

    /// 系统语言对应的识别 Locale（如 zh-Hans-CN → zh-CN）。
    static func systemLocale() -> Locale {
        let lang = Locale.current.language.languageCode?.identifier ?? "zh"
        let region = Locale.current.region?.identifier ?? "CN"
        return Locale(identifier: "\(lang)-\(region)")
    }

    // MARK: - 结果可靠性评估

    /// 判断快速识别的结果是否可信：
    /// 行数太少、文本密度过低（典型于伴奏盖过人声）、
    /// 或识别出的文本语言与系统语言不符（典型于外语歌）都视为不可靠。
    private static func isReliable(_ lines: [LyricLine], duration: Double, locale: Locale) -> Bool {
        guard lines.count >= 2 else { return false }
        let text = lines.map(\.text).joined()
        guard text.count >= 16 else { return false }

        // 视频容器（mov/部分 mp4）AVAudioFile 打不开，duration 传进来是 0——
        // 用识别结果自身的时间轴兜底；仍取不到就判不可靠（交给 Whisper），
        // 否则密度门槛对"伴奏盖人声的 MV"这种最需要它的场景形同虚设
        var effectiveDuration = duration
        if effectiveDuration <= 0 { effectiveDuration = lines.last?.end ?? 0 }
        guard effectiveDuration > 0 else { return false }

        let density = Double(text.count) / max(effectiveDuration, 1)
        guard density >= 0.6 else { return false }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let dominant = recognizer.dominantLanguage?.rawValue.prefix(2),
           let expected = locale.language.languageCode?.identifier.prefix(2),
           dominant != expected {
            return false
        }
        return true
    }

    private static func audioDuration(url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
