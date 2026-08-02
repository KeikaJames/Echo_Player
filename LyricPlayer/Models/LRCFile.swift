import Foundation

/// LRC 歌词文件的读取与导出。
enum LRCFile {
    /// 查找与音频同名的 .lrc 文件并解析。
    static func sidecarLines(for audioURL: URL) -> [LyricLine]? {
        let base = audioURL.deletingPathExtension()
        for ext in ["lrc", "LRC", "Lrc"] {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                if let lines = parse(fileURL: candidate), !lines.isEmpty {
                    return lines
                }
            }
        }
        return nil
    }

    static func parse(fileURL: URL) -> [LyricLine]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
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
        let tagPattern = #/\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]/#
        var entries: [(start: Double, text: String)] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let matches = line.matches(of: tagPattern)
            guard !matches.isEmpty else { continue }

            // 歌词正文 = 去掉所有时间标签之后的部分
            guard let lastMatch = matches.last else { continue }
            let content = String(line[lastMatch.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }

            for m in matches {
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
