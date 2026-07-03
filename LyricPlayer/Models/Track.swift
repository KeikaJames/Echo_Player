import Foundation
import AVFoundation
import AppKit

/// 播放列表中的一首曲目。
struct Track: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var title: String
    var artist: String = ""
    var duration: Double = 0
    var artwork: NSImage?

    init(url: URL) {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.artist == rhs.artist
            && lhs.duration == rhs.duration && (lhs.artwork == nil) == (rhs.artwork == nil)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// 支持的音频扩展名。
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "aifc",
        "caf", "flac", "ac3", "au", "snd", "amr"
    ]

    /// 支持的视频扩展名（AVFoundation 原生解码）。
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// 需 FFmpeg（KSPlayer）软解的扩展名全集——AVFoundation 打不开的容器/编码。
    static let ffmpegExtensions: Set<String> = [
        "mkv", "webm", "ogg", "oga", "opus", "ape", "wma", "flv", "avi", "ts"
    ]

    /// FFmpeg 集合里“带画面”的那部分（决定走视频舞台而非纯音频界面）。
    static let ffmpegVideoExtensions: Set<String> = ["mkv", "webm", "flv", "avi", "ts"]

    /// 该曲目是否需要走 FFmpeg 后端。
    var needsFFmpeg: Bool { Self.ffmpegExtensions.contains(url.pathExtension.lowercased()) }

    var isVideo: Bool {
        let ext = url.pathExtension.lowercased()
        return Self.videoExtensions.contains(ext) || Self.ffmpegVideoExtensions.contains(ext)
    }

    static func isMediaFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return audioExtensions.contains(ext) || videoExtensions.contains(ext)
            || ffmpegExtensions.contains(ext)
    }

    static func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        // FFmpeg 集合里非视频的部分（ogg/oga/opus/ape/wma）算作音频
        return audioExtensions.contains(ext)
            || (ffmpegExtensions.contains(ext) && !ffmpegVideoExtensions.contains(ext))
    }

    /// 异步读取元数据（标题 / 艺人 / 时长 / 封面）。
    struct Metadata: Sendable {
        var title: String?
        var artist: String?
        var duration: Double
        var artworkData: Data?
    }

    static func loadMetadata(from url: URL) async -> Metadata {
        let asset = AVURLAsset(url: url)
        var meta = Metadata(title: nil, artist: nil, duration: 0, artworkData: nil)

        if let duration = try? await asset.load(.duration) {
            meta.duration = duration.seconds.isFinite ? duration.seconds : 0
        }
        guard let items = try? await asset.load(.commonMetadata) else { return meta }

        let titleItems = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierTitle)
        if let item = titleItems.first, let value = try? await item.load(.stringValue) {
            meta.title = value
        }
        let artistItems = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtist)
        if let item = artistItems.first, let value = try? await item.load(.stringValue) {
            meta.artist = value
        }
        let artItems = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork)
        if let item = artItems.first, let data = try? await item.load(.dataValue) {
            meta.artworkData = data
        }

        // 视频没有封面时取 20% 处的画面帧作缩略图
        if meta.artworkData == nil, videoExtensions.contains(url.pathExtension.lowercased()) {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 800)
            let at = CMTime(seconds: max(1, meta.duration * 0.2), preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: at).image {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                meta.artworkData = rep.representation(using: .png, properties: [:])
            }
        }
        return meta
    }
}
