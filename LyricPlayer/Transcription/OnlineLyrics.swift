import Foundation

/// 在线歌词源：LRCLIB（lrclib.net，免费、无需 key、社区维护的同步歌词库）。
/// 用户允许在线查询后，优先使用曲库中的同步歌词，查不到再继续本地识别。
enum OnlineLyrics {
    private static let maxResponseBytes = 2 * 1024 * 1024
    private static let maxRecords = 500

    private struct LRCLIBRecord: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let syncedLyrics: String?
    }

    enum FetchResult {
        case synced([LyricLine])   // 命中同步歌词
        case instrumental          // 曲库标记为纯音乐
    }

    /// 按元数据查询同步歌词；查不到返回 nil（不抛错，管线继续走识别）。
    static func fetch(title: String, artist: String, duration: Double) async -> FetchResult? {
        let cleanTitle = String(cleanup(title).prefix(200))
        let cleanArtist = String(primaryArtist(artist).prefix(200))
        let duration = validDuration(duration) ?? 0
        guard !cleanTitle.isEmpty else { return nil }

        // 1) 精确匹配（LRCLIB 按 ±2 秒时长匹配）
        if duration > 0, !cleanArtist.isEmpty {
            var comps = URLComponents(string: "https://lrclib.net/api/get")!
            comps.queryItems = [
                .init(name: "track_name", value: cleanTitle),
                .init(name: "artist_name", value: cleanArtist),
                .init(name: "duration", value: String(Int(duration.rounded()))),
            ]
            if let record: LRCLIBRecord = await request(comps.url) {
                if record.instrumental == true { return .instrumental }
                if let lines = syncedLines(from: record) { return .synced(lines) }
            }
        }

        // 2) 搜索并挑时长最接近的同步歌词
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        var items = [URLQueryItem(name: "track_name", value: cleanTitle)]
        if !cleanArtist.isEmpty { items.append(.init(name: "artist_name", value: cleanArtist)) }
        comps.queryItems = items

        guard let decoded: [LRCLIBRecord] = await request(comps.url) else { return nil }
        let records = Array(decoded.prefix(maxRecords))
        let candidates = records
            .compactMap { record -> (record: LRCLIBRecord, bucket: Double, length: Int)? in
                guard let lyrics = record.syncedLyrics, !lyrics.isEmpty,
                      record.instrumental != true else { return nil }
                let recordDuration = validDuration(record.duration)
                let distance: Double
                if duration > 0 {
                    guard let recordDuration else { return nil }
                    distance = abs(recordDuration - duration)
                } else {
                    distance = 0
                }
                return (record, floor(distance / 3), lyrics.count)
            }
            .sorted { a, b in
                // 时长差按 3 秒分桶：同桶视为同版本，选歌词更完整的那份。
                // 用分桶而非"差值容差"是为了保证严格弱序（容差比较不可传递，
                // sorted 对其结果未定义）；曲目无时长信息时退化为只比完整度。
                if a.bucket != b.bucket { return a.bucket < b.bucket }
                return a.length > b.length
            }
        guard let best = candidates.first?.record else {
            // 没有任何带歌词的版本，但时长吻合的条目标记为纯音乐 → 采信
            if let inst = records.first(where: { $0.instrumental == true }),
               duration > 0, let d = validDuration(inst.duration), abs(d - duration) <= 5 {
                return .instrumental
            }
            return nil
        }
        // 时长差太多说明是不同版本（现场版/加长版），对不上时间轴，放弃
        if duration > 0, let d = validDuration(best.duration), abs(d - duration) > 10 { return nil }
        return syncedLines(from: best).map { .synced($0) }
    }

    private static func syncedLines(from record: LRCLIBRecord) -> [LyricLine]? {
        guard let synced = record.syncedLyrics, !synced.isEmpty else { return nil }
        let lines = LRCFile.parse(text: synced)
        return lines.count >= 4 ? lines : nil
    }

    private static func request<T: Decodable>(_ url: URL?) async -> T? {
        guard let url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("EchoPlayer/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        for attempt in 0..<2 {   // 网络瞬断时重试一次
            do {
                let (data, response) = try await BoundedHTTPClient.data(for: req, maxBytes: maxResponseBytes)
                if response.statusCode == 404 { return nil }   // 未收录，不必重试
                if response.statusCode == 200 {
                    return try? JSONDecoder().decode(T.self, from: data)
                }
            } catch is CancellationError {
                return nil   // 切歌取消：立即退出，别把取消伪装成"未收录"再重试一轮
            } catch BoundedHTTPClient.RequestError.responseTooLarge {
                return nil
            } catch {
                if attempt == 1 { NSLog("在线歌词查询失败：\(error.localizedDescription)") }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        return nil
    }

    private static func validDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 7 * 24 * 3600 else { return nil }
        return value
    }

    /// 标题清洗：去掉 (Live)、[Remastered 2019] 之类的括注。
    private static func cleanup(_ title: String) -> String {
        var out = title
        out = out.replacingOccurrences(of: #"\s*[\(\[（【][^\)\]）】]*[\)\]）】]"#,
                                       with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// 多艺人字段取第一个（"Dr. Dre/Snoop Dogg" → "Dr. Dre"）。
    private static func primaryArtist(_ artist: String) -> String {
        let separators = CharacterSet(charactersIn: "/,;&、")
        let first = artist.components(separatedBy: separators).first ?? artist
        return first
            .replacingOccurrences(of: #"(?i)\s*(feat\.?|ft\.?)\s.*$"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
