import AVFoundation
import XCTest
@testable import LyricPlayer

final class AnalysisAudioSourceTests: XCTestCase {
    func testTimelineFrameRejectsValuesOutsideTheDecodeBudgetBeforeNarrowing() {
        XCTAssertEqual(AnalysisAudioSource.boundedTimelineFrame(-1, maximum: 1_000), 0)
        XCTAssertEqual(AnalysisAudioSource.boundedTimelineFrame(999.6, maximum: 1_000), 1_000)
        XCTAssertNil(AnalysisAudioSource.boundedTimelineFrame(1_001, maximum: 1_000))
        XCTAssertNil(AnalysisAudioSource.boundedTimelineFrame(Double(Int64.max),
                                                              maximum: Int64.max))
    }

    func testTemporaryPCMCapacityKeepsReserveAndHasHardLimit() throws {
        let mib: Int64 = 1024 * 1024

        XCTAssertThrowsError(try AnalysisAudioSource.temporaryPCMByteLimit(
            availableCapacity: 512 * mib
        )) { error in
            guard case AnalysisAudioSource.PreparationError.notEnoughTemporarySpace = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try AnalysisAudioSource.temporaryPCMByteLimit(availableCapacity: 1_024 * mib),
            512 * mib
        )
        XCTAssertEqual(
            try AnalysisAudioSource.temporaryPCMByteLimit(availableCapacity: 10_000 * mib),
            2_048 * mib
        )
    }

    func testNativeReadableAudioPassesThroughWithoutOwningInput() async throws {
        let input = try RegressionFixture.makeNativeAudio()
        defer { RegressionFixture.remove(input) }

        XCTAssertNoThrow(try AVAudioFile(forReading: input))

        var prepared: AnalysisAudioSource.Prepared? = try await AnalysisAudioSource.prepare(url: input)
        XCTAssertEqual(prepared?.url.standardizedFileURL, input.standardizedFileURL)

        prepared = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path),
                      "A pass-through source must never delete the user's input file")
    }

    func testPreparationRejectsFileVersionDifferentFromPlayback() async throws {
        let input = try RegressionFixture.makeNativeAudio()
        let replacement = try RegressionFixture.makeNativeAudio()
        defer {
            RegressionFixture.remove(input)
            RegressionFixture.remove(replacement)
        }
        let playbackIdentity = try XCTUnwrap(MediaFileIdentity(url: input))

        try FileManager.default.removeItem(at: input)
        try FileManager.default.moveItem(at: replacement, to: input)

        do {
            _ = try await AnalysisAudioSource.prepare(
                url: input,
                expectedSourceIdentity: playbackIdentity
            )
            XCTFail("Analysis must not switch to a replacement hidden behind the playback path")
        } catch AnalysisAudioSource.PreparationError.sourceChanged {
            // Expected.
        } catch {
            XCTFail("Expected sourceChanged, got: \(error)")
        }
    }

    func testUnreadableWMAFallsBackToReadableTemporaryAudioAndCleansItUp() async throws {
        let input = try RegressionFixture.makeFFmpegOnlyAudio()
        defer { RegressionFixture.remove(input) }

        XCTAssertThrowsError(try AVAudioFile(forReading: input),
                             "The fixture must exercise the FFmpeg path, not AVFoundation")

        var prepared: AnalysisAudioSource.Prepared? = try await AnalysisAudioSource.prepare(url: input)
        let output = try XCTUnwrap(prepared?.url)

        XCTAssertNotEqual(output.standardizedFileURL, input.standardizedFileURL)
        XCTAssertEqual(output.pathExtension.lowercased(), "wav")
        let decoded = try AVAudioFile(forReading: output)
        XCTAssertGreaterThan(decoded.length, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        prepared = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "The owner must remove fallback audio when its lifetime ends")
    }

    func testFFmpegPreparationKeepsDelayedAudioOnTheContainerTimeline() async throws {
        let input = try RegressionFixture.makeDelayedAudioVideo()
        defer { RegressionFixture.remove(input) }

        var prepared: AnalysisAudioSource.Prepared? = try await AnalysisAudioSource.prepare(url: input)
        let output = try XCTUnwrap(prepared?.url)
        let decoded = try AVAudioFile(forReading: output)
        let seconds = Double(decoded.length) / decoded.processingFormat.sampleRate

        XCTAssertGreaterThan(seconds, 6.9, "The five-second PTS gap must remain before the audio")
        XCTAssertLessThan(seconds, 7.1)

        prepared = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testFFmpegPreparationUsesTheSelectedStreamIndex() async throws {
        let input = try RegressionFixture.makeDelayedAudioVideo()
        defer { RegressionFixture.remove(input) }

        var prepared: AnalysisAudioSource.Prepared? = try await AnalysisAudioSource.prepare(
            url: input,
            preferredAudioStreamIndex: 1
        )
        XCTAssertGreaterThan(try AVAudioFile(forReading: XCTUnwrap(prepared?.url)).length, 0)
        prepared = nil

        do {
            _ = try await AnalysisAudioSource.prepare(url: input, preferredAudioStreamIndex: 0)
            XCTFail("A selected video stream must not silently fall back to another audio track")
        } catch AnalysisAudioSource.PreparationError.noAudioTrack {
            // Expected.
        } catch {
            XCTFail("Expected noAudioTrack, got: \(error)")
        }
    }

    func testConcurrentFallbacksDoNotShareOrDeleteEachOthersTemporaryAudio() async throws {
        let input = try RegressionFixture.makeFFmpegOnlyAudio()
        defer { RegressionFixture.remove(input) }

        var prepared = try await withThrowingTaskGroup(
            of: AnalysisAudioSource.Prepared.self,
            returning: [AnalysisAudioSource.Prepared?].self
        ) { group in
            group.addTask { try await AnalysisAudioSource.prepare(url: input) }
            group.addTask { try await AnalysisAudioSource.prepare(url: input) }

            var results: [AnalysisAudioSource.Prepared?] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(prepared.count, 2)
        let firstURL = try XCTUnwrap(prepared[0]?.url)
        let secondURL = try XCTUnwrap(prepared[1]?.url)
        XCTAssertNotEqual(firstURL, secondURL,
                          "Independent consumers must not race through a shared converted file")

        prepared[0] = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path),
                      "Releasing a stale-track source must not delete the current track's source")

        prepared[1] = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testAlreadyCancelledPreparationThrowsAndDoesNotLeakTemporaryWAV() async throws {
        let input = try RegressionFixture.makeFFmpegOnlyAudio()
        defer { RegressionFixture.remove(input) }
        let before = RegressionFixture.temporaryWAVs()

        let task = Task { () throws -> AnalysisAudioSource.Prepared in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AnalysisAudioSource.prepare(url: input)
        }

        do {
            _ = try await task.value
            XCTFail("A preparation started by an already-cancelled task must not succeed")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Cancellation must remain CancellationError, got: \(error)")
        }

        await Task.yield()
        let leaked = RegressionFixture.temporaryWAVs().subtracting(before)
        XCTAssertTrue(leaked.isEmpty, "Cancelled preparation leaked: \(leaked)")
    }

    func testCorruptFFmpegMediaFailsWithoutLeavingPartialOutput() async throws {
        let input = try RegressionFixture.makeCorruptMedia()
        defer { RegressionFixture.remove(input) }
        let before = RegressionFixture.temporaryWAVs()

        do {
            _ = try await AnalysisAudioSource.prepare(url: input)
            XCTFail("Corrupt media must fail instead of producing a cacheable empty file")
        } catch is CancellationError {
            XCTFail("A decode error must not be reported as cancellation")
        } catch {
            // The exact backend error is deliberately not part of the public contract.
        }

        await Task.yield()
        let leaked = RegressionFixture.temporaryWAVs().subtracting(before)
        XCTAssertTrue(leaked.isEmpty, "Failed preparation leaked: \(leaked)")
    }
}
