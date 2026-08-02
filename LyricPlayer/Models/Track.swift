import Foundation
import AVFoundation
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// 播放列表中的一首曲目。
struct Track: Identifiable, Hashable {
    let id = UUID()
    var url: URL
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

    static let supportedContentTypes: [UTType] = [
        UTType(importedAs: "app.echoplayer.audio"),
        UTType(importedAs: "app.echoplayer.video"),
    ]

    var isVideo: Bool {
        Self.videoExtensions.contains(url.pathExtension.lowercased())
    }

    static func isMediaFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return audioExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// 异步读取元数据（标题 / 艺人 / 时长 / 封面）。
    struct Metadata: Sendable {
        var title: String?
        var artist: String?
        var duration: Double
        var artworkData: Data?
    }

    static func loadMetadata(from url: URL, includeArtwork: Bool = false) async -> Metadata {
        let asset = AVURLAsset(url: url)
        var meta = Metadata(title: nil, artist: nil, duration: 0, artworkData: nil)

        guard !Task.isCancelled else { return meta }
        if let duration = try? await asset.load(.duration) {
            meta.duration = duration.seconds.isFinite ? duration.seconds : 0
        }
        guard !Task.isCancelled else { return meta }
        if let items = try? await asset.load(.commonMetadata) {
            let titleItems = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierTitle)
            if let item = titleItems.first, let value = try? await item.load(.stringValue) {
                meta.title = String(value.prefix(500))
            }
            let artistItems = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtist)
            if let item = artistItems.first, let value = try? await item.load(.stringValue) {
                meta.artist = String(value.prefix(500))
            }
        }

        if includeArtwork, !Task.isCancelled {
            meta.artworkData = await thumbnailData(for: url)
        }
        return meta
    }

    private static func thumbnailData(for url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: 800, height: 800),
                                                   scale: 1,
                                                   representationTypes: .thumbnail)
        guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = thumbnail.cgImage
        guard image.width <= 800, image.height <= 800 else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
