import Foundation

/// 一个带时间戳的词（来自语音识别的逐词结果）。
struct LyricWord: Codable, Hashable, Sendable {
    var text: String
    var start: Double
    var duration: Double
    var end: Double { start + duration }
}

/// 一行歌词/台词。
struct LyricLine: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var start: Double
    var end: Double
    var words: [LyricWord] = []

    /// 是否有逐词时间信息（可做卡拉 OK 式逐词点亮）。
    var hasWordTiming: Bool { words.count >= 2 }
}

/// 歌词来源。
enum LyricsSource: String, Codable, Sendable {
    case lrcFile
    case cache
    case online
    case recognized

    var displayName: String {
        switch self {
        case .lrcFile: return "LRC 歌词文件"
        case .cache: return "缓存"
        case .online: return "在线歌词"
        case .recognized: return "自动识别"
        }
    }
}

/// 把逐词识别结果按停顿、句读、长度切分成歌词行。
enum LyricComposer {
    private static let gapThreshold = 0.85      // 词间停顿超过该秒数则换行
    private static let maxUnits = 44.0          // 一行的最大“宽度单位”（中文按 2 计）
    private static let maxLineDuration = 9.0    // 一行最长持续秒数
    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "…", ".", "!", "?", ";", "；"]

    static func compose(words rawWords: [LyricWord]) -> [LyricLine] {
        var lines: [LyricLine] = []
        var current: [LyricWord] = []
        var currentUnits = 0.0

        func flush() {
            guard !current.isEmpty else { return }
            let text = join(current)
            if !text.isEmpty {
                lines.append(LyricLine(text: text,
                                       start: current[0].start,
                                       end: current[current.count - 1].end,
                                       words: current))
            }
            current = []
            currentUnits = 0
        }

        for raw in rawWords {
            let trimmed = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var word = raw
            word.text = trimmed

            if let last = current.last {
                let gap = word.start - last.end
                let endsSentence = last.text.last.map { sentenceEnders.contains($0) } ?? false
                let tooWide = currentUnits >= maxUnits
                let tooLong = (word.end - current[0].start) > maxLineDuration
                if gap >= gapThreshold || tooWide || tooLong || (endsSentence && currentUnits >= 8) {
                    flush()
                }
            }
            current.append(word)
            currentUnits += units(of: trimmed)
        }
        flush()
        return lines
    }

    /// 中日韩字符按 2 个单位计宽，其余按 1。
    private static func units(of s: String) -> Double {
        s.unicodeScalars.reduce(0) { $0 + ($1.isCJK ? 2 : 1) }
    }

    private static func join(_ words: [LyricWord]) -> String {
        var out = ""
        for w in words {
            if out.isEmpty {
                out = w.text
            } else if let a = out.last, let b = w.text.first, needsSpace(between: a, and: b) {
                out += " " + w.text
            } else {
                out += w.text
            }
        }
        return out
    }

    private static func needsSpace(between a: Character, and b: Character) -> Bool {
        if a.isCJK || b.isCJK { return false }
        if ",.!?;:)]}%，。！？；：）】".contains(b) { return false }
        if "([{（【".contains(a) { return false }
        return true
    }
}

extension Character {
    var isCJK: Bool { unicodeScalars.first?.isCJK ?? false }
}

extension Unicode.Scalar {
    var isCJK: Bool {
        switch value {
        case 0x2E80...0x303F,       // 部首、符号
             0x3040...0x30FF,       // 日文假名
             0x3400...0x4DBF,       // 扩展 A
             0x4E00...0x9FFF,       // 基本汉字
             0xAC00...0xD7AF,       // 谚文
             0xF900...0xFAFF,       // 兼容汉字
             0xFF00...0xFF60:       // 全角符号
            return true
        default:
            return false
        }
    }
}
