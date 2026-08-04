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

    func testUpdaterRejectsBundlesThatRequireANewerSystem() {
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 0)

        XCTAssertTrue(UpdateInstaller.isCompatibleMinimumSystemVersion("14.1", current: sonoma))
        XCTAssertTrue(UpdateInstaller.isCompatibleMinimumSystemVersion("14.0.9", current: sonoma))
        XCTAssertFalse(UpdateInstaller.isCompatibleMinimumSystemVersion("14.1.1", current: sonoma))
        XCTAssertFalse(UpdateInstaller.isCompatibleMinimumSystemVersion("15.0", current: sonoma))
        XCTAssertFalse(UpdateInstaller.isCompatibleMinimumSystemVersion(nil, current: sonoma))
        XCTAssertFalse(UpdateInstaller.isCompatibleMinimumSystemVersion("14.1 beta", current: sonoma))
        XCTAssertFalse(UpdateInstaller.isCompatibleMinimumSystemVersion("14..1", current: sonoma))
    }

    func testUpdaterReadsMinimumSystemVersionFromEveryUniversalSlice() throws {
        let intel = thinMachO(minimumSystemVersion: 0x000E_0100)
        let appleSilicon = thinMachO(minimumSystemVersion: 0x000F_0000)
        let binary = fatMachO(intel: intel, appleSilicon: appleSilicon)

        let versions = try XCTUnwrap(UpdateInstaller.minimumSystemVersions(inMachO: binary))
        XCTAssertEqual(versions.map {
            "\($0.majorVersion).\($0.minorVersion).\($0.patchVersion)"
        }, ["14.1.0", "15.0.0"])
    }

    func testUpdaterReadsMinimumSystemVersionFromUniversalStaticArchive() throws {
        let intel = archive(member: thinMachO(minimumSystemVersion: 0x000A_0F00))
        let appleSilicon = archive(member: thinMachO(minimumSystemVersion: 0x000B_0000))
        let binary = fatMachO(intel: intel, appleSilicon: appleSilicon)

        let versions = try XCTUnwrap(UpdateInstaller.minimumSystemVersions(inMachO: binary))
        XCTAssertEqual(Set(versions.map {
            "\($0.majorVersion).\($0.minorVersion).\($0.patchVersion)"
        }), ["10.15.0", "11.0.0"])
    }

    func testUpdaterRejectsArchitectureSpecificMinimumSystemVersion() {
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 0)

        XCTAssertTrue(UpdateInstaller.areCompatibleArchitectureMinimumSystemVersions(nil,
                                                                                      current: sonoma))
        XCTAssertTrue(UpdateInstaller.areCompatibleArchitectureMinimumSystemVersions(
            ["arm64": "14.1", "x86_64": "14.0"], current: sonoma
        ))
        XCTAssertFalse(UpdateInstaller.areCompatibleArchitectureMinimumSystemVersions(
            ["arm64": "15.0", "x86_64": "14.1"], current: sonoma
        ))
        XCTAssertFalse(UpdateInstaller.areCompatibleArchitectureMinimumSystemVersions(
            ["arm64": 15], current: sonoma
        ))
    }

    func testUpdaterRejectsMalformedUniversalMachO() throws {
        var binary = Data()
        appendBigEndian(0xCAFE_BABE, to: &binary)
        appendBigEndian(1, to: &binary)

        XCTAssertEqual(UpdateInstaller.minimumSystemVersions(inMachO: binary)?.count, 0)
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

    private func thinMachO(minimumSystemVersion: UInt32) -> Data {
        var data = Data()
        appendLittleEndian(0xFEED_FACF, to: &data)
        appendLittleEndian(0x0100_000C, to: &data)
        appendLittleEndian(0, to: &data)
        appendLittleEndian(2, to: &data)
        appendLittleEndian(1, to: &data)
        appendLittleEndian(24, to: &data)
        appendLittleEndian(0, to: &data)
        appendLittleEndian(0, to: &data)
        appendLittleEndian(0x32, to: &data)
        appendLittleEndian(24, to: &data)
        appendLittleEndian(1, to: &data)
        appendLittleEndian(minimumSystemVersion, to: &data)
        appendLittleEndian(minimumSystemVersion, to: &data)
        appendLittleEndian(0, to: &data)
        return data
    }

    private func fatMachO(intel: Data, appleSilicon: Data) -> Data {
        let headerSize: UInt32 = 48
        var data = Data()
        appendBigEndian(0xCAFE_BABE, to: &data)
        appendBigEndian(2, to: &data)
        appendBigEndian(0x0100_0007, to: &data)
        appendBigEndian(3, to: &data)
        appendBigEndian(headerSize, to: &data)
        appendBigEndian(UInt32(intel.count), to: &data)
        appendBigEndian(0, to: &data)
        appendBigEndian(0x0100_000C, to: &data)
        appendBigEndian(0, to: &data)
        appendBigEndian(headerSize + UInt32(intel.count), to: &data)
        appendBigEndian(UInt32(appleSilicon.count), to: &data)
        appendBigEndian(0, to: &data)
        data.append(intel)
        data.append(appleSilicon)
        return data
    }

    private func archive(member: Data) -> Data {
        var data = Data("!<arch>\n".utf8)
        let header = "fixture.o/      0           0     0     100644  \(member.count)"
            .padding(toLength: 58, withPad: " ", startingAt: 0)
        data.append(Data(header.utf8))
        data.append(Data("`\n".utf8))
        data.append(member)
        if member.count % 2 != 0 { data.append(0x0A) }
        return data
    }

    private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func appendBigEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }
}
