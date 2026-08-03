import Foundation
import XCTest
@testable import LyricPlayer

final class UpdateContractTests: XCTestCase {
    func testAutomaticUpdateIsDisabledInsideTestHost() {
        XCTAssertEqual(UpdateChecker.repoSlug, "OWNER/EchoPlayer")
        XCTAssertFalse(UpdateChecker.isConfigured)
    }

    func testAutomaticUpdateStillAcceptsOnlyPinnedHTTPSHosts() {
        XCTAssertTrue(UpdateInstaller.isTrustedSource(URL(string: "https://github.com/owner/repo/releases/a.zip")!))
        XCTAssertTrue(UpdateInstaller.isTrustedSource(URL(string: "https://objects.githubusercontent.com/a.zip")!))

        XCTAssertFalse(UpdateInstaller.isTrustedSource(URL(string: "http://github.com/a.zip")!))
        XCTAssertFalse(UpdateInstaller.isTrustedSource(URL(string: "https://github.com.attacker.example/a.zip")!))
        XCTAssertFalse(UpdateInstaller.isTrustedSource(URL(string: "file:///tmp/a.zip")!))
    }

    func testDownloadedBundleVersionMustMatchReleaseTag() {
        XCTAssertTrue(UpdateInstaller.isExpectedVersion("1.2.3", release: "v1.2.3"))
        XCTAssertTrue(UpdateInstaller.isExpectedVersion("1.2.3", release: "V1.2.3"))
        XCTAssertFalse(UpdateInstaller.isExpectedVersion("1.2.2", release: "v1.2.3"))
        XCTAssertFalse(UpdateInstaller.isExpectedVersion(nil, release: "v1.2.3"))
    }

    func testAutomaticInstallRequiresACompleteSHA256() {
        XCTAssertTrue(UpdateInstaller.isValidSHA256(String(repeating: "a", count: 64)))
        XCTAssertTrue(UpdateInstaller.isValidSHA256(String(repeating: "F", count: 64)))
        XCTAssertFalse(UpdateInstaller.isValidSHA256(String(repeating: "a", count: 63)))
        XCTAssertFalse(UpdateInstaller.isValidSHA256(String(repeating: "g", count: 64)))
    }

    func testArchivePreflightParsesOnlyBoundedNumericSummary() throws {
        let summary = try XCTUnwrap(UpdateInstaller.archiveSummary(
            from: "683 files, 615648491 bytes uncompressed, 495425460 bytes compressed: 19.5%\n"
        ))
        XCTAssertEqual(summary.entries, 683)
        XCTAssertEqual(summary.expandedBytes, 615_648_491)
        XCTAssertEqual(summary.compressedBytes, 495_425_460)
        XCTAssertLessThan(summary.expandedBytes, UpdateInstaller.maximumExpandedBytes)
        XCTAssertLessThan(summary.compressedBytes, UpdateInstaller.maximumDownloadBytes)
        XCTAssertNil(UpdateInstaller.archiveSummary(
            from: "files: many, bytes uncompressed: unlimited"
        ))
    }

    func testApplicationSwapKeepsBothPathsAndCanBeReversed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoPlayerSwapRegression-\(UUID().uuidString)", isDirectory: true)
        let current = root.appendingPathComponent("Echo Player.app", isDirectory: true)
        let staged = root.appendingPathComponent(".EchoPlayerSwap-2147483647-fixture.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: current.appendingPathComponent("version"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("version"))

        try UpdateInstaller.exchangeItems(current, staged)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("version"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: staged.appendingPathComponent("version"), encoding: .utf8), "old")

        try UpdateInstaller.exchangeItems(current, staged)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("version"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: staged.appendingPathComponent("version"), encoding: .utf8), "new")
    }

    func testUpdaterRemovesTemporaryFilesLeftByDeadProcess() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoPlayerDownload-2147483647-\(UUID().uuidString).zip")
        try Data("partial update".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        UpdateInstaller.removeAbandonedTemporaryFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUpdaterNeverTreatsRunningStagedBundleAsAbandoned() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoPlayerCurrentStaging-\(UUID().uuidString)", isDirectory: true)
        let staged = root.appendingPathComponent(
            ".EchoPlayerSwap-2147483647-fixture.app", isDirectory: true
        )
        let regular = root.appendingPathComponent("Echo Player.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey,
                                         .contentModificationDateKey]
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let deadline = Date().addingTimeInterval(60)
        XCTAssertFalse(UpdateInstaller.shouldDiscardStagedItem(
            staged, currentBundleURL: staged, currentPID: currentPID,
            legacyDeadline: deadline, keys: keys
        ))
        XCTAssertTrue(UpdateInstaller.shouldDiscardStagedItem(
            staged, currentBundleURL: regular, currentPID: currentPID,
            legacyDeadline: deadline, keys: keys
        ))

        let marker = URL(fileURLWithPath: staged.path + ".pending-update.json")
        try Data("pending".utf8).write(to: marker)
        XCTAssertFalse(UpdateInstaller.shouldDiscardStagedItem(
            staged, currentBundleURL: regular, currentPID: currentPID,
            legacyDeadline: deadline, keys: keys
        ))
    }
}
