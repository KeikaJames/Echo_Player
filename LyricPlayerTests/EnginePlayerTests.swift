import AVFoundation
import XCTest
@testable import LyricPlayer

final class EnginePlayerTests: XCTestCase {
    func testLongAudioIsScheduledWithoutNarrowingFrameCount() throws {
        let maximum = AVAudioFramePosition(AVAudioFrameCount.max)
        let segments = EnginePlayer.frameSegments(fileLength: maximum + 42, startFrame: 0)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].startFrame, 0)
        XCTAssertEqual(segments[0].frameCount, AVAudioFrameCount.max)
        XCTAssertEqual(segments[1].startFrame, maximum)
        XCTAssertEqual(segments[1].frameCount, 42)
    }

    func testForgedAudioLengthCannotCreateAnUnboundedScheduleQueue() {
        let maximum = AVAudioFramePosition(AVAudioFrameCount.max)
        let oversized = maximum * AVAudioFramePosition(EnginePlayer.maximumFrameSegments + 1)

        XCTAssertFalse(EnginePlayer.canSchedule(fileLength: oversized, startFrame: 0))
        XCTAssertTrue(EnginePlayer.frameSegments(fileLength: oversized, startFrame: 0).isEmpty)
    }
}
