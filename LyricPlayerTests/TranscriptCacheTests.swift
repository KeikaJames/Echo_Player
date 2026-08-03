import Foundation
import XCTest
@testable import LyricPlayer

final class TranscriptCacheTests: XCTestCase {
    private let localeA = "regression|zh-CN"
    private let localeB = "regression|en-US"

    func testCacheRoundTripPreservesLinesAndSourceForOriginalMediaURL() async throws {
        let media = try makeMedia(bytes: [0x01, 0x02, 0x03])
        defer { cleanCacheAndFile(media) }
        let line = LyricLine(text: "cache contract", start: 1.25, end: 2.5)

        await TranscriptCache.save(lines: [line], source: .recognized, for: media, localeID: localeA)
        let cached = await TranscriptCache.load(for: media, localeID: localeA)
        let loaded = try XCTUnwrap(cached)

        XCTAssertEqual(loaded.lines, [line])
        XCTAssertEqual(loaded.source, .recognized)
        let otherLocale = await TranscriptCache.load(for: media, localeID: localeB)
        XCTAssertNil(otherLocale,
                     "Recognition language variants must not contaminate one another")
    }

    func testNegativeCacheRoundTripsInsteadOfRetriggeringRecognition() async throws {
        let media = try makeMedia(bytes: [0x04])
        defer { cleanCacheAndFile(media) }

        await TranscriptCache.save(lines: [], source: .recognized, for: media, localeID: localeA)
        let cached = await TranscriptCache.load(for: media, localeID: localeA)
        let loaded = try XCTUnwrap(cached)

        XCTAssertTrue(loaded.lines.isEmpty)
        XCTAssertEqual(loaded.source, .recognized)
    }

    func testMTimeDoesNotInvalidateCacheButContentSizeDoes() async throws {
        let media = try makeMedia(bytes: [0x05])
        defer { cleanCacheAndFile(media) }
        let line = LyricLine(text: "stable", start: 0, end: 1)
        await TranscriptCache.save(lines: [line], source: .recognized, for: media, localeID: localeA)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: media.path
        )
        let afterMTimeChange = await TranscriptCache.load(for: media, localeID: localeA)
        XCTAssertNotNil(afterMTimeChange,
                        "iCloud-style mtime changes must not invalidate transcripts")

        try Data([0x05, 0x06]).write(to: media, options: .atomic)
        let afterSizeChange = await TranscriptCache.load(for: media, localeID: localeA)
        XCTAssertNil(afterSizeChange,
                     "A different file size must not reuse a stale transcript")
    }

    func testSameSizeReplacementDoesNotReuseStaleTranscript() async throws {
        let size = 1024 * 1024
        let media = try makeMedia(bytes: [UInt8](repeating: 0x10, count: size))
        defer { cleanCacheAndFile(media) }
        let line = LyricLine(text: "old file", start: 0, end: 1)
        await TranscriptCache.save(lines: [line], source: .recognized, for: media, localeID: localeA)

        var replacement = Data(repeating: 0x10, count: size)
        replacement[128 * 1024] = 0x20
        try replacement.write(to: media, options: .atomic)

        let loaded = await TranscriptCache.load(for: media, localeID: localeA)
        XCTAssertNil(loaded,
                     "A same-size replacement must not reuse a stale transcript")
    }

    func testLargeFileMTimeChangeKeepsCacheWithoutFullScan() async throws {
        let media = try makeSparseMedia(size: 513 * 1024 * 1024)
        defer { cleanCacheAndFile(media) }
        let line = LyricLine(text: "large stable", start: 0, end: 1)
        await TranscriptCache.save(lines: [line], source: .recognized,
                                   for: media, localeID: localeA)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: media.path
        )

        let loaded = await TranscriptCache.load(for: media, localeID: localeA)
        XCTAssertEqual(loaded?.lines, [line],
                       "Metadata-only changes must not invalidate a large media cache")
    }

    func testLargeFileInPlaceChangeInvalidatesCache() async throws {
        let media = try makeSparseMedia(size: 513 * 1024 * 1024)
        defer { cleanCacheAndFile(media) }
        let line = LyricLine(text: "large old", start: 0, end: 1)
        await TranscriptCache.save(lines: [line], source: .recognized,
                                   for: media, localeID: localeA)

        let file = try FileHandle(forWritingTo: media)
        try file.seek(toOffset: 128 * 1024)
        try file.write(contentsOf: Data([0x20]))
        try file.synchronize()
        try file.close()

        let loaded = await TranscriptCache.load(for: media, localeID: localeA)
        XCTAssertNil(loaded,
                     "A large in-place content change must invalidate the transcript")
    }

    func testSaveRejectsLyricsFromReplacedSourceIdentity() async throws {
        let media = try makeMedia(bytes: [0x31, 0x32, 0x33])
        defer { cleanCacheAndFile(media) }
        let identity = try XCTUnwrap(MediaFileIdentity(url: media))
        let line = LyricLine(text: "source A", start: 0, end: 1)

        try Data([0x41, 0x42, 0x43]).write(to: media, options: .atomic)
        await TranscriptCache.save(lines: [line], source: .recognized,
                                   for: media, localeID: localeA,
                                   sourceIdentity: identity)

        let loaded = await TranscriptCache.load(for: media, localeID: localeA)
        XCTAssertNil(loaded,
                     "Lyrics produced from an old file identity must never be cached for its replacement")
    }

    func testRemovedCacheCannotBeRestoredByInFlightSave() async throws {
        let media = try makeMedia(bytes: [0x51, 0x52, 0x53])
        let reachedWrite = expectation(description: "save reached guarded write")
        let resumeWrite = DispatchSemaphore(value: 0)
        TranscriptCache.setBeforeWriteHookForTesting {
            reachedWrite.fulfill()
            resumeWrite.wait()
        }
        defer {
            resumeWrite.signal()
            TranscriptCache.setBeforeWriteHookForTesting(nil)
            cleanCacheAndFile(media)
        }
        let line = LyricLine(text: "in flight", start: 0, end: 1)

        let save = Task {
            await TranscriptCache.save(lines: [line], source: .recognized,
                                       for: media, localeID: localeA)
        }
        await fulfillment(of: [reachedWrite], timeout: 5)
        TranscriptCache.remove(for: media, localeID: localeA)
        resumeWrite.signal()
        await save.value

        let loaded = await TranscriptCache.load(for: media, localeID: localeA)
        XCTAssertNil(loaded,
                     "An older in-flight save must not restore a cache removed by forced recognition")
    }

    func testCancelledSaveCannotAdoptGenerationCreatedByRemoval() async throws {
        let media = try makeMedia(bytes: [0x61, 0x62, 0x63])
        let reachedGeneration = expectation(description: "save reached generation capture")
        let resumeGeneration = DispatchSemaphore(value: 0)
        TranscriptCache.setBeforeGenerationHookForTesting {
            reachedGeneration.fulfill()
            resumeGeneration.wait()
        }
        defer {
            resumeGeneration.signal()
            TranscriptCache.setBeforeGenerationHookForTesting(nil)
            cleanCacheAndFile(media)
        }
        let line = LyricLine(text: "cancelled save", start: 0, end: 1)

        let save = Task {
            await TranscriptCache.save(lines: [line], source: .recognized,
                                       for: media, localeID: localeA)
        }
        await fulfillment(of: [reachedGeneration], timeout: 5)
        TranscriptCache.remove(for: media, localeID: localeA)
        save.cancel()
        resumeGeneration.signal()
        await save.value

        let loaded = await TranscriptCache.load(for: media, localeID: localeA)
        XCTAssertNil(loaded,
                     "A cancelled old save must not adopt the generation created by cache removal")
    }

    func testTemporaryAnalysisURLDoesNotAliasOriginalMediaCache() async throws {
        let original = try makeMedia(bytes: [0x07, 0x08])
        let converted = try makeMedia(bytes: [0x07, 0x08])
        defer {
            cleanCacheAndFile(original)
            cleanCacheAndFile(converted)
        }
        let line = LyricLine(text: "keyed by original", start: 0, end: 1)

        await TranscriptCache.save(lines: [line], source: .recognized, for: original, localeID: localeA)

        let originalResult = await TranscriptCache.load(for: original, localeID: localeA)
        let convertedResult = await TranscriptCache.load(for: converted, localeID: localeA)
        XCTAssertNotNil(originalResult)
        XCTAssertNil(convertedResult,
                     "A transient decode artifact must never become the durable cache identity")
    }

    private func makeMedia(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoPlayerCacheRegression-\(UUID().uuidString).ogg")
        try Data(bytes).write(to: url, options: .atomic)
        return url
    }

    private func makeSparseMedia(size: UInt64) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoPlayerCacheRegression-\(UUID().uuidString).mkv")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: size)
        try file.close()
        return url
    }

    private func cleanCacheAndFile(_ url: URL) {
        TranscriptCache.remove(for: url, localeID: localeA)
        TranscriptCache.remove(for: url, localeID: localeB)
        try? FileManager.default.removeItem(at: url)
    }
}
