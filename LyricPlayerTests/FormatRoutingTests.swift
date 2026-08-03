import Foundation
import XCTest
@testable import LyricPlayer

final class FormatRoutingTests: XCTestCase {
    func testEveryDeclaredMediaExtensionHasOneStablePlaybackRoute() {
        let nativeAudio = Track.audioExtensions
        let nativeVideo = Track.videoExtensions
        let ffmpeg = Track.ffmpegExtensions

        XCTAssertTrue(nativeAudio.isDisjoint(with: nativeVideo))
        XCTAssertTrue(nativeAudio.isDisjoint(with: ffmpeg))
        XCTAssertTrue(nativeVideo.isDisjoint(with: ffmpeg))
        XCTAssertTrue(Track.ffmpegVideoExtensions.isSubset(of: ffmpeg))

        for pathExtension in nativeAudio {
            let track = Track(url: URL(fileURLWithPath: "/fixture.\(pathExtension)"))
            XCTAssertTrue(Track.isMediaFile(track.url), pathExtension)
            XCTAssertTrue(Track.isAudioFile(track.url), pathExtension)
            XCTAssertFalse(track.isVideo, pathExtension)
            XCTAssertFalse(track.needsFFmpeg, pathExtension)
        }

        for pathExtension in nativeVideo {
            let track = Track(url: URL(fileURLWithPath: "/fixture.\(pathExtension)"))
            XCTAssertTrue(Track.isMediaFile(track.url), pathExtension)
            XCTAssertFalse(Track.isAudioFile(track.url), pathExtension)
            XCTAssertTrue(track.isVideo, pathExtension)
            XCTAssertFalse(track.needsFFmpeg, pathExtension)
        }

        for pathExtension in ffmpeg {
            let track = Track(url: URL(fileURLWithPath: "/fixture.\(pathExtension)"))
            XCTAssertTrue(Track.isMediaFile(track.url), pathExtension)
            XCTAssertEqual(Track.isAudioFile(track.url),
                           !Track.ffmpegVideoExtensions.contains(pathExtension), pathExtension)
            XCTAssertEqual(track.isVideo,
                           Track.ffmpegVideoExtensions.contains(pathExtension), pathExtension)
            XCTAssertTrue(track.needsFFmpeg, pathExtension)
        }
    }

    func testFormatRoutingIsCaseInsensitiveAndRejectsLookalikes() {
        let uppercased = ["MP3", "MOV", "MKV", "OpUs", "Ts"]
        for pathExtension in uppercased {
            XCTAssertTrue(Track.isMediaFile(URL(fileURLWithPath: "/fixture.\(pathExtension)")),
                          pathExtension)
        }

        for pathExtension in ["mkv.tmp", "oggx", "txt", "", "m3u"] {
            XCTAssertFalse(Track.isMediaFile(URL(fileURLWithPath: "/fixture.\(pathExtension)")),
                           pathExtension)
        }
    }

    func testExpectedExtendedFormatsRemainRegistered() {
        XCTAssertEqual(Track.ffmpegExtensions,
                       ["mkv", "webm", "ogg", "oga", "opus", "ape", "wma", "flv", "avi", "ts"])
        XCTAssertEqual(Track.ffmpegVideoExtensions, ["mkv", "webm", "flv", "avi", "ts"])
    }
}
