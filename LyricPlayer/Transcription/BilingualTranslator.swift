import Foundation
import NaturalLanguage
import Translation

struct TranslationItem: Equatable, Sendable {
    let id: UUID
    let text: String
}

struct TranslationGroup: Identifiable, Sendable {
    let id = UUID()
    let sourceIdentifier: String
    let items: [TranslationItem]

    var sourceLanguage: Locale.Language {
        Locale.Language(identifier: sourceIdentifier)
    }
}

struct TranslationPlan: Sendable {
    let groups: [TranslationGroup]
    let skippedIDs: Set<UUID>
}

enum BilingualTranslationError: LocalizedError {
    case unsupportedPair(Locale.Language, Locale.Language)

    var errorDescription: String? {
        switch self {
        case .unsupportedPair(let source, let target):
            let sourceName = Locale.current.localizedString(forIdentifier: source.minimalIdentifier)
                ?? source.minimalIdentifier
            let targetName = Locale.current.localizedString(forIdentifier: target.minimalIdentifier)
                ?? target.minimalIdentifier
            return "系统翻译暂不支持从\(sourceName)到\(targetName)。"
        }
    }
}

/// 先按源语言分组，再保留调用方 ID 逐句翻译，结果始终能映射回原时间轴。
enum BilingualTranslator {
    private static let minimumDetectionCharacters = 20
    private static let minimumDetectionConfidence = 0.65

    static func plan(for items: [TranslationItem],
                     target: Locale.Language,
                     knownSource: Locale.Language? = nil) -> TranslationPlan {
        let valid = items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let fallback = knownSource?.minimalIdentifier
            ?? languageIdentifier(for: valid.map(\.text).joined(separator: "\n"))
        var grouped: [String: [TranslationItem]] = [:]
        var order: [String] = []
        var skipped: Set<UUID> = Set(items.map(\.id)).subtracting(valid.map(\.id))

        for item in valid {
            let detected = languageIdentifier(for: item.text)
            guard let sourceIdentifier = detected ?? fallback else {
                skipped.insert(item.id)
                continue
            }
            let source = Locale.Language(identifier: sourceIdentifier)
            guard !source.isEquivalent(to: target) else {
                skipped.insert(item.id)
                continue
            }
            if grouped[sourceIdentifier] == nil { order.append(sourceIdentifier) }
            grouped[sourceIdentifier, default: []].append(item)
        }

        let groups = order.compactMap { identifier in
            grouped[identifier].map { TranslationGroup(sourceIdentifier: identifier, items: $0) }
        }
        return TranslationPlan(groups: groups, skippedIDs: skipped)
    }

    @available(macOS 15.0, *)
    static func translate(_ items: [TranslationItem],
                          using session: TranslationSession,
                          onTranslation: (@MainActor @Sendable (UUID, String?) -> Void)? = nil) async throws -> [UUID: String] {
        let valid = items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !valid.isEmpty else { return [:] }

        if let source = session.sourceLanguage, let target = session.targetLanguage,
           try await shouldTranslate(from: source, to: target) == false {
            for item in valid { await onTranslation?(item.id, nil) }
            return [:]
        }

        var translated: [UUID: String] = [:]
        for item in valid {
            try Task.checkCancellation()
            do {
                let response = try await session.translate(item.text)
                let target = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                let source = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let result = !target.isEmpty && target.compare(source,
                                                               options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
                    ? target : nil
                if let result { translated[item.id] = result }
                await onTranslation?(item.id, result)
            } catch {
                if isIgnorableLineError(error) {
                    await onTranslation?(item.id, nil)
                    continue
                }
                if Task.isCancelled { throw CancellationError() }
                if #available(macOS 26.0, *), TranslationError.alreadyCancelled ~= error {
                    throw CancellationError()
                }
                throw error
            }
        }
        return translated
    }

    private static func languageIdentifier(for text: String) -> String? {
        let sample = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowsShortSample = usesDistinctiveScript(sample)
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }
        guard let best = hypotheses.first, best.key != .undetermined else { return nil }
        let threshold = sample.count >= minimumDetectionCharacters
            ? minimumDetectionConfidence : (allowsShortSample ? 0.8 : 0.9)
        let runnerUp = hypotheses.dropFirst().first?.value ?? 0
        guard best.value >= threshold, best.value - runnerUp >= 0.2 else { return nil }
        let language = best.key
        return Locale.Language(identifier: language.rawValue).minimalIdentifier
    }

    private static func usesDistinctiveScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0370...0x052F,   // 希腊字母、西里尔字母
                 0x0590...0x06FF,   // 希伯来文、阿拉伯文
                 0x0900...0x097F,   // 天城文
                 0x0E00...0x0E7F,   // 泰文
                 0x3040...0x30FF,   // 日文假名
                 0x3400...0x9FFF,   // 汉字
                 0xAC00...0xD7AF:   // 韩文
                return true
            default:
                return false
            }
        }
    }

    @available(macOS 15.0, *)
    private static func shouldTranslate(from source: Locale.Language,
                                        to target: Locale.Language) async throws -> Bool {
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed, .supported:
            return true
        case .unsupported:
            if baseIdentifier(source) == baseIdentifier(target) { return false }
            throw BilingualTranslationError.unsupportedPair(source, target)
        @unknown default:
            throw BilingualTranslationError.unsupportedPair(source, target)
        }
    }

    private static func baseIdentifier(_ language: Locale.Language) -> Substring {
        language.minimalIdentifier.split(separator: "-").first ?? ""
    }

    @available(macOS 15.0, *)
    private static func isIgnorableLineError(_ error: Error) -> Bool {
        TranslationError.nothingToTranslate ~= error
            || TranslationError.unableToIdentifyLanguage ~= error
            || TranslationError.unsupportedSourceLanguage ~= error
    }
}
