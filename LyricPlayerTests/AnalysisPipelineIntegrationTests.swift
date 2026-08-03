import Foundation
import XCTest
@testable import LyricPlayer

final class AnalysisPipelineIntegrationTests: XCTestCase {
    func testPreparedFFmpegAudioFeedsTheSameBeatAnalyzerAsNativeAudio() async throws {
        let native = try RegressionFixture.makeNativeAudio()
        let ffmpegOnly = try RegressionFixture.makeFFmpegOnlyAudio()
        defer {
            RegressionFixture.remove(native)
            RegressionFixture.remove(ffmpegOnly)
        }

        let nativeGrid = await BeatGrid.analyze(url: native)
        var prepared: AnalysisAudioSource.Prepared? = try await AnalysisAudioSource.prepare(url: ffmpegOnly)
        let preparedURL = try XCTUnwrap(prepared?.url)
        let fallbackGrid = await BeatGrid.analyze(url: preparedURL)

        XCTAssertFalse(nativeGrid.isEmpty, "原生通路的拍点基线失效")
        XCTAssertFalse(fallbackGrid.isEmpty, "FFmpeg 通路应复用同一拍点分析器")
        XCTAssertEqual(nativeGrid, nativeGrid.sorted())
        XCTAssertEqual(fallbackGrid, fallbackGrid.sorted())

        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedURL.path),
                      "分析任务持有 Prepared 时临时文件必须存活")
        prepared = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedURL.path),
                       "共享分析任务结束后应释放临时文件")
    }

    func testRecognizedLineIDsRemainUsableByBilingualPipeline() {
        let first = LyricLine(text: "This is a sufficiently clear English sentence.", start: 0, end: 2)
        let second = LyricLine(text: "Another stable sentence for language detection.", start: 2, end: 4)
        let items = [first, second].map { TranslationItem(id: $0.id, text: $0.text) }

        let plan = BilingualTranslator.plan(
            for: items,
            target: Locale.Language(identifier: "zh-Hans"),
            knownSource: Locale.Language(identifier: "en")
        )
        let plannedIDs = Set(plan.groups.flatMap(\.items).map(\.id))

        XCTAssertEqual(plannedIDs, Set([first.id, second.id]))
        XCTAssertTrue(plan.skippedIDs.isEmpty)
    }

    func testWhisperInputIsNormalizedAndBoundedBeforeDeepRecognition() async throws {
        let input = try RegressionFixture.makeNativeAudio()
        defer { RegressionFixture.remove(input) }

        let samples = try WhisperTranscriber.loadAudioChunk(url: input, start: 0, end: 2)
        XCTAssertGreaterThan(samples.count, 31_000)
        XCTAssertLessThan(samples.count, 33_000)

        let maximumRawBytes = Int64((WhisperTranscriber.deepChunkSeconds
            + WhisperTranscriber.deepChunkOverlapSeconds * 2) * 16_000)
            * Int64(MemoryLayout<Float>.size)
        XCTAssertLessThanOrEqual(maximumRawBytes, 40 * 1024 * 1024,
                                 "Deep recognition must never materialize a whole giant source")

        let longDuration = WhisperTranscriber.deepChunkSeconds * 3 + 17
        var position = 0.0
        var ranges: [Range<Double>] = []
        while let range = WhisperTranscriber.deepChunkRange(start: position,
                                                            duration: longDuration) {
            XCTAssertEqual(range.lowerBound, position)
            XCTAssertLessThanOrEqual(range.upperBound - range.lowerBound,
                                     WhisperTranscriber.deepChunkSeconds)
            let window = try XCTUnwrap(WhisperTranscriber.deepChunkWindow(for: range,
                                                                          duration: longDuration))
            XCTAssertLessThanOrEqual(window.upperBound - window.lowerBound,
                                     WhisperTranscriber.deepChunkSeconds
                                         + WhisperTranscriber.deepChunkOverlapSeconds * 2)
            ranges.append(range)
            position = range.upperBound
        }
        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual(position, longDuration)

        let beforeBoundary = LyricWord(text: "before", start: 598, duration: 3)
        let afterBoundary = LyricWord(text: "after", start: 599, duration: 3)
        XCTAssertTrue(WhisperTranscriber.owns(beforeBoundary, in: ranges[0],
                                              includesUpperBound: false))
        XCTAssertFalse(WhisperTranscriber.owns(afterBoundary, in: ranges[0],
                                               includesUpperBound: false))
        XCTAssertFalse(WhisperTranscriber.owns(beforeBoundary, in: ranges[1],
                                               includesUpperBound: false))
        XCTAssertTrue(WhisperTranscriber.owns(afterBoundary, in: ranges[1],
                                              includesUpperBound: false))

        let cancelled = Task { () throws -> [Float] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try WhisperTranscriber.loadAudioChunk(url: input, start: 0, end: 2)
        }
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled deep-audio read must stop before allocating the chunk")
        } catch is CancellationError {
            // Expected.
        }
    }
}
