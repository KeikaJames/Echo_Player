import Foundation

private final class LRCFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let primaryPresentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(primaryURL: URL, sidecarURL: URL) {
        primaryPresentedItemURL = primaryURL
        presentedItemURL = sidecarURL
    }
}

/// LRC 歌词文件的读取与导出。
enum LRCFile {
    private static let maxFileBytes = 4 * 1024 * 1024
    private static let maxLineBytes = 8 * 1024
    private static let maxRawLines = 20_000
    private static let maxTagsPerLine = 8
    private static let maxEntries = 20_000

    /// 查找与音频同名的 .lrc 文件并解析。
    static func sidecarLines(for audioURL: URL) -> [LyricLine]? {
        let base = audioURL.deletingPathExtension()
        for ext in ["lrc", "LRC", "Lrc"] {
            let candidate = base.appendingPathExtension(ext)
            let presenter = LRCFilePresenter(primaryURL: audioURL, sidecarURL: candidate)
            NSFileCoordinator.addFilePresenter(presenter)

            let coordinator = NSFileCoordinator(filePresenter: presenter)
            var error: NSError?
            var parsed: [LyricLine]?
            coordinator.coordinate(readingItemAt: candidate, options: .withoutChanges,
                                   error: &error) { url in
                parsed = parse(fileURL: url)
            }
            NSFileCoordinator.removeFilePresenter(presenter)
            if let parsed, !parsed.isEmpty { return parsed }
        }
        return nil
    }

    static func parse(fileURL: URL) -> [LyricLine]? {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize, fileSize <= maxFileBytes,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count <= maxFileBytes else { return nil }
        let text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            // Windows 记事本"Unicode"（UTF-16 带 BOM），按 BOM 自动辨字节序
            guard let utf16 = String(data: data, encoding: .utf16) else { return nil }
            text = utf16
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8.replacingOccurrences(of: "\u{FEFF}", with: "")   // 去掉 UTF-8 BOM
        } else {
            // 大量中文 LRC 是 GBK/GB18030 编码
            let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            guard let gbText = String(data: data, encoding: String.Encoding(rawValue: gb)) else { return nil }
            text = gbText
        }
        return parse(text: text)
    }

    static func parse(text: String) -> [LyricLine] {
        guard text.utf8.count <= maxFileBytes else { return [] }
        let tagPattern = #/\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]/#
        var entries: [(start: Double, text: String)] = []
        let rawLines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard rawLines.count <= maxRawLines else { return [] }

        for rawLine in rawLines {
            guard rawLine.utf8.count <= maxLineBytes else { return [] }
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let matches = line.matches(of: tagPattern)
            guard !matches.isEmpty else { continue }
            guard matches.count <= maxTagsPerLine else { return [] }

            // 歌词正文 = 去掉所有时间标签之后的部分
            guard let lastMatch = matches.last else { continue }
            let content = String(line[lastMatch.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }

            for m in matches {
                guard entries.count < maxEntries else { return [] }
                let minutes = Double(m.output.1) ?? 0
                let seconds = Double(m.output.2) ?? 0
                var fraction = 0.0
                if let fracStr = m.output.3, let raw = Double(fracStr) {
                    fraction = raw / pow(10, Double(fracStr.count))
                }
                entries.append((minutes * 60 + seconds + fraction, content))
            }
        }

        entries.sort { $0.start < $1.start }
        var lines: [LyricLine] = []
        for (i, entry) in entries.enumerated() {
            let end = i + 1 < entries.count ? entries[i + 1].start : entry.start + 5
            lines.append(LyricLine(text: entry.text, start: entry.start, end: end))
        }
        return lines
    }

    static func export(lines: [LyricLine], title: String, artist: String?) -> String {
        var out = "[ti:\(title)]\n"
        if let artist, !artist.isEmpty { out += "[ar:\(artist)]\n" }
        out += "[re:Echo Player]\n\n"
        for line in lines {
            let total = max(0, line.start)
            let m = Int(total) / 60
            let s = Int(total) % 60
            let cs = Int((total - floor(total)) * 100)
            out += String(format: "[%02d:%02d.%02d]%@\n", m, s, cs, line.text)
        }
        return out
    }
}
