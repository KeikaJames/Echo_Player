import Foundation
import XCTest
@testable import LyricPlayer

final class PlayerModelTests: XCTestCase {
    func testPlayRetriesCurrentTrackAfterAPlaybackFailure() throws {
        let model = PlayerModel.shared
        let source = try RegressionFixture.makeNativeAudio()
        let retryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-\(UUID().uuidString).m4a")
        defer {
            model.stop()
            model.playlist = []
            RegressionFixture.remove(source)
            RegressionFixture.remove(retryURL)
        }

        model.stop()
        let track = Track(url: retryURL)
        model.playlist = [track]
        model.play(trackID: track.id)
        XCTAssertFalse(model.isPlaying)

        try FileManager.default.copyItem(at: source, to: retryURL)
        model.resume()

        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.currentTrackID, track.id)
    }
}
