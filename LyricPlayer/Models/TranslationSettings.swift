import Foundation
import Observation
import Translation

/// 系统翻译支持的目标语言。列表由 Translation 框架动态提供，随系统更新自动扩展。
struct TranslationLanguageOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

enum BilingualTranslationState: Equatable {
    case idle
    case translating
    case done
    case failed(String)
}

/// 歌词与实时字幕共用一套目标语言，两个显示开关彼此独立。
@MainActor
@Observable
final class TranslationSettings {
    static let shared = TranslationSettings()

    var lyricsEnabled: Bool {
        didSet { UserDefaults.standard.set(lyricsEnabled, forKey: "lyricsTranslationEnabled") }
    }
    var captionsEnabled: Bool {
        didSet { UserDefaults.standard.set(captionsEnabled, forKey: "captionsTranslationEnabled") }
    }
    var targetIdentifier: String {
        didSet { UserDefaults.standard.set(targetIdentifier, forKey: "translationTargetLanguage") }
    }
    private(set) var supportedLanguages: [TranslationLanguageOption]

    @ObservationIgnored private var didLoadLanguages = false

    private init() {
        let systemLanguage = Locale.Language.systemLanguages.first?.minimalIdentifier ?? "zh-Hans"
        let saved = UserDefaults.standard.string(forKey: "translationTargetLanguage")
        targetIdentifier = saved ?? systemLanguage
        lyricsEnabled = UserDefaults.standard.bool(forKey: "lyricsTranslationEnabled")
        captionsEnabled = UserDefaults.standard.bool(forKey: "captionsTranslationEnabled")
        supportedLanguages = [Self.option(for: Locale.Language(identifier: saved ?? systemLanguage))]
    }

    var targetLanguage: Locale.Language {
        Locale.Language(identifier: targetIdentifier)
    }

    var targetName: String {
        supportedLanguages.first(where: { $0.id == targetIdentifier })?.name
            ?? Self.option(for: targetLanguage).name
    }

    func loadSupportedLanguages() async {
        guard !didLoadLanguages else { return }
        didLoadLanguages = true

        let languages = await LanguageAvailability().supportedLanguages
        guard !languages.isEmpty else { return }

        supportedLanguages = languages
            .map(Self.option)
            .reduce(into: [String: TranslationLanguageOption]()) { result, option in
                result[option.id] = option
            }
            .values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let selected = Locale.Language(identifier: targetIdentifier)
        if let equivalent = languages.first(where: { $0.isEquivalent(to: selected) }) {
            targetIdentifier = equivalent.minimalIdentifier
        } else if let system = Locale.Language.systemLanguages.first,
                  let equivalent = languages.first(where: { $0.isEquivalent(to: system) }) {
            targetIdentifier = equivalent.minimalIdentifier
        } else if let first = supportedLanguages.first {
            targetIdentifier = first.id
        }
    }

    private static func option(for language: Locale.Language) -> TranslationLanguageOption {
        let id = language.minimalIdentifier
        let name = Locale.current.localizedString(forIdentifier: id) ?? id
        return TranslationLanguageOption(id: id, name: name)
    }
}
