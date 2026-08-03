import AVFoundation
import XCTest
@testable import LyricPlayer

final class VideoBackendTests: XCTestCase {
    func testOnlyExplicitRateCallsChangePlaybackIntent() {
        XCTAssertEqual(VideoBackend.playbackIntent(rate: 0, reason: .setRateCalled), false)
        XCTAssertEqual(VideoBackend.playbackIntent(rate: 1, reason: .setRateCalled), true)
        XCTAssertNil(VideoBackend.playbackIntent(rate: 0, reason: .setRateFailed))
        XCTAssertNil(VideoBackend.playbackIntent(rate: 0, reason: .audioSessionInterrupted))
        XCTAssertNil(VideoBackend.playbackIntent(rate: 0, reason: .appBackgrounded))
        XCTAssertNil(VideoBackend.playbackIntent(rate: 0, reason: nil))
    }
}
