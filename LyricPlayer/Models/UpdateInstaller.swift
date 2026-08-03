import Foundation
import AppKit
import CryptoKit
import Darwin

/// 应用内自动更新安装器：下载 → 校验 → 替换 → 重启。
///
/// 专为无 Apple Developer 证书的分发设计：
/// - **应用内下载不带 quarantine 标记**——只有首次手动安装需要过 Gatekeeper，
///   之后的每次更新都是无感的；
/// - **SHA-256 指纹校验**：与发布说明中公布的指纹比对（CI 发版时自动写入），
///   下载被篡改、CDN 传错、断点损坏都会被拒绝；
/// - **包身份校验**：解压出来的 .app 必须与当前应用同 bundle identifier，
///   杜绝"下载到别的东西还给装上了"；
/// - **来源钉死**：只接受 github.com / *.githubusercontent.com 的 HTTPS 直链；
/// - 任何一步失败都退回"打开发布页手动下载"，绝不半途而废留下坏状态。
@MainActor
final class UpdateInstaller: NSObject {
    static let shared = UpdateInstaller()
    nonisolated private static let downloadPrefix = "EchoPlayerDownload-"
    nonisolated private static let workDirectoryPrefix = "EchoPlayerUpdate-"
    nonisolated private static let stagingPrefix = ".EchoPlayerSwap-"
    nonisolated private static let pendingMarkerSuffix = ".pending-update.json"
    nonisolated static let maximumDownloadBytes: Int64 = 1_536 * 1_024 * 1_024
    nonisolated static let maximumExpandedBytes: Int64 = 3 * 1_024 * 1_024 * 1_024
    nonisolated static let maximumArchiveEntries = 50_000
    nonisolated private static let minimumFreeSpaceReserve: Int64 = 512 * 1_024 * 1_024
    nonisolated private static let maximumCompressionRatio = 20.0

    private var progressPanel: NSPanel?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var activeSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var processingTask: Task<PreparedUpdate, Error>?
    private var processingGeneration: UInt64 = 0
    private var releasePageURL: URL?
    private var expectedSHA256 = ""
    private var expectedDownloadSize: Int64?
    private var versionLabel = ""
    private var pendingLaunchState: (state: PendingUpdateState, markerURL: URL)?

    // MARK: - 入口

    func install(from assetURL: URL, expectedSHA256: String?, expectedDownloadSize: Int64?,
                 version: String, releasePageURL: URL?) {
        guard Self.isTrustedSource(assetURL) else {
            fail("更新包地址不在可信来源（GitHub）上，已停止。")
            return
        }
        guard let expectedSHA256, Self.isValidSHA256(expectedSHA256) else {
            self.releasePageURL = releasePageURL
            failWithPage("该发布没有有效的 SHA-256 指纹，不能自动安装。")
            return
        }
        guard expectedDownloadSize.map({ $0 <= Self.maximumDownloadBytes }) ?? true else {
            self.releasePageURL = releasePageURL
            failWithPage("更新包超过自动更新的安全体积上限。")
            return
        }
        guard downloadTask == nil, processingTask == nil else { return }   // 已在更新中
        self.releasePageURL = releasePageURL
        self.expectedSHA256 = expectedSHA256.lowercased()
        self.expectedDownloadSize = expectedDownloadSize
        self.versionLabel = version

        showProgress(text: "正在下载 Echo Player \(version)…")
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: assetURL)
        activeSession = session
        downloadTask = task
        task.resume()
    }

    /// 只信 GitHub 的 HTTPS 直链（release 资产会 302 到 objects.githubusercontent.com）。
    nonisolated static func isTrustedSource(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    nonisolated static func isExpectedVersion(_ candidate: String?, release: String) -> Bool {
        guard let candidate, !candidate.isEmpty else { return false }
        let expected = release.hasPrefix("v") || release.hasPrefix("V")
            ? String(release.dropFirst())
            : release
        return candidate == expected
    }

    nonisolated static func isValidSHA256(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == 64 else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    nonisolated static func removeAbandonedTemporaryFiles() {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let legacyDeadline = Date().addingTimeInterval(-24 * 60 * 60)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey,
                                        .isSymbolicLinkKey, .contentModificationDateKey]
        if let items = try? manager.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: Array(keys)) {
            for item in items {
                let name = item.lastPathComponent
                let prefix: String
                let suffix: String
                if name.hasPrefix(downloadPrefix), name.hasSuffix(".zip") {
                    prefix = downloadPrefix
                    suffix = ".zip"
                } else if name.hasPrefix(workDirectoryPrefix) {
                    prefix = workDirectoryPrefix
                    suffix = ""
                } else {
                    continue
                }
                let values = try? item.resourceValues(forKeys: keys)
                guard values?.isDirectory == true || values?.isRegularFile == true
                        || values?.isSymbolicLink == true else { continue }

                let stem = name.dropFirst(prefix.count).dropLast(suffix.count)
                if let pid = processID(in: stem) {
                    guard pid != currentPID else { continue }
                    if !isProcessRunning(pid) { try? manager.removeItem(at: item) }
                } else if let date = values?.contentModificationDate, date < legacyDeadline {
                    try? manager.removeItem(at: item)
                }
            }
        }
        removeAbandonedStagedItems(in: Bundle.main.bundleURL.deletingLastPathComponent(),
                                   currentBundleURL: Bundle.main.bundleURL,
                                   currentPID: currentPID,
                                   legacyDeadline: legacyDeadline,
                                   keys: keys)
    }

    nonisolated private static func removeAbandonedStagedItems(in directory: URL,
                                                                currentBundleURL: URL,
                                                                currentPID: Int32,
                                                                legacyDeadline: Date,
                                                                keys: Set<URLResourceKey>) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: Array(keys)) else { return }
        for item in items where shouldDiscardStagedItem(
            item, currentBundleURL: currentBundleURL, currentPID: currentPID,
            legacyDeadline: legacyDeadline, keys: keys
        ) {
            discardStagedItem(item)
        }
    }

    nonisolated static func shouldDiscardStagedItem(_ item: URL,
                                                    currentBundleURL: URL,
                                                    currentPID: Int32,
                                                    legacyDeadline: Date,
                                                    keys: Set<URLResourceKey>) -> Bool {
        let name = item.lastPathComponent
        guard name.hasPrefix(stagingPrefix), name.hasSuffix(".app") else { return false }
        guard item.standardizedFileURL.resolvingSymlinksInPath()
                != currentBundleURL.standardizedFileURL.resolvingSymlinksInPath() else { return false }
        guard !FileManager.default.fileExists(atPath: pendingMarkerURL(for: item).path) else { return false }
        let values = try? item.resourceValues(forKeys: keys)
        guard values?.isDirectory == true || values?.isSymbolicLink == true else { return false }
        let stem = name.dropFirst(stagingPrefix.count).dropLast(4)
        if let pid = processID(in: stem) {
            return pid != currentPID && !isProcessRunning(pid)
        }
        return values?.contentModificationDate.map { $0 < legacyDeadline } ?? false
    }

    nonisolated private static func processID<S: StringProtocol>(in stem: S) -> Int32? {
        guard let separator = stem.firstIndex(of: "-") else { return nil }
        return Int32(stem[..<separator]).flatMap { $0 > 0 ? $0 : nil }
    }

    nonisolated private static func isProcessRunning(_ pid: Int32) -> Bool {
        errno = 0
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    nonisolated private static func pendingMarkerURL(for previousURL: URL) -> URL {
        URL(fileURLWithPath: previousURL.path + pendingMarkerSuffix)
    }

    // MARK: - 校验 + 替换 + 重启

    private func finishDownload(at fileURL: URL, task: URLSessionDownloadTask) {
        guard downloadTask === task, processingTask == nil else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            failWithPage("当前应用缺少 bundle identifier，无法核验更新包。")
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        setProgress(text: "正在校验并解压…", indeterminate: true)
        processingGeneration &+= 1
        let generation = processingGeneration
        let currentURL = Bundle.main.bundleURL
        let expectedSHA256 = expectedSHA256
        let expectedDownloadSize = expectedDownloadSize
        let version = versionLabel
        let worker = Task.detached(priority: .userInitiated) {
            try await Self.prepareUpdate(fileURL: fileURL,
                                         expectedSHA256: expectedSHA256,
                                         expectedDownloadSize: expectedDownloadSize,
                                         version: version,
                                         bundleIdentifier: bundleIdentifier,
                                         currentURL: currentURL)
        }
        processingTask = worker

        Task { @MainActor [weak self] in
            let result: Result<PreparedUpdate, Error>
            do {
                result = .success(try await worker.value)
            } catch {
                result = .failure(error)
            }
            guard let self,
                  self.processingGeneration == generation,
                  self.downloadTask === task else {
                if case .success(let prepared) = result {
                    Task.detached { Self.discardStagedItem(prepared.stagedURL) }
                }
                Task.detached { try? FileManager.default.removeItem(at: fileURL) }
                return
            }

            self.processingTask = nil
            self.downloadTask = nil
            switch result {
            case .success(let prepared):
                self.installPreparedUpdate(prepared, currentURL: currentURL, fileURL: fileURL)
            case .failure(let error):
                var canRemoveTemporaryFile = true
                if error is CancellationError {
                    self.closeProgress()
                } else if let preparationError = error as? UpdatePreparationError,
                          case .containerNotWritable = preparationError {
                    canRemoveTemporaryFile = self.revealFallback(
                        fileURL: fileURL, reason: error.localizedDescription
                    )
                } else {
                    self.failWithPage(error.localizedDescription)
                }
                if canRemoveTemporaryFile {
                    Task.detached { try? FileManager.default.removeItem(at: fileURL) }
                }
            }
        }
    }

    nonisolated private static func prepareUpdate(fileURL: URL,
                                                   expectedSHA256: String,
                                                   expectedDownloadSize: Int64?,
                                                   version: String,
                                                   bundleIdentifier: String,
                                                   currentURL: URL) async throws -> PreparedUpdate {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize.map(Int64.init),
              fileSize > 0, fileSize <= maximumDownloadBytes,
              expectedDownloadSize.map({ $0 == fileSize }) ?? true else {
            throw UpdatePreparationError.archiveLimitExceeded
        }
        let actualSHA256 = try sha256(of: fileURL)
        guard actualSHA256 == expectedSHA256 else {
            NSLog("更新校验失败：期望 %@ 实际 %@", expectedSHA256, actualSHA256)
            throw UpdatePreparationError.hashMismatch
        }
        try Task.checkCancellation()

        let manager = FileManager.default
        let workDir = manager.temporaryDirectory
            .appendingPathComponent("\(workDirectoryPrefix)\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? manager.removeItem(at: workDir) }
        try manager.createDirectory(at: workDir, withIntermediateDirectories: true)
        let archive = try await archiveSummary(for: fileURL)
        guard archive.entries > 0, archive.entries <= maximumArchiveEntries,
              archive.compressedBytes > 0, archive.compressedBytes <= maximumDownloadBytes,
              archive.expandedBytes > 0, archive.expandedBytes <= maximumExpandedBytes,
              Double(archive.expandedBytes) / Double(archive.compressedBytes)
                <= maximumCompressionRatio else {
            throw UpdatePreparationError.archiveLimitExceeded
        }
        let capacity = try workDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard capacity >= archive.expandedBytes + minimumFreeSpaceReserve else {
            throw UpdatePreparationError.insufficientDiskSpace
        }
        guard try await runTool("/usr/bin/ditto", ["-x", "-k", fileURL.path, workDir.path]) else {
            throw UpdatePreparationError.cannotExtract
        }
        try Task.checkCancellation()

        guard let newApp = findApp(in: workDir) else {
            throw UpdatePreparationError.missingApplication
        }
        let resolvedWorkDir = workDir.resolvingSymlinksInPath().path + "/"
        guard newApp.resolvingSymlinksInPath().path.hasPrefix(resolvedWorkDir) else {
            throw UpdatePreparationError.invalidApplicationPath
        }

        let container = currentURL.deletingLastPathComponent()
        guard manager.fileExists(atPath: currentURL.path),
              manager.isWritableFile(atPath: container.path) else {
            throw UpdatePreparationError.containerNotWritable
        }
        let stagedURL = container.appendingPathComponent(
            "\(stagingPrefix)\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).app",
            isDirectory: true
        )
        var completed = false
        defer {
            if !completed { try? manager.removeItem(at: stagedURL) }
        }

        // 跨卷复制先落到同目录的隐藏 staging；正式切换只剩一次同卷原子交换。
        guard try await runTool("/usr/bin/ditto", [newApp.path, stagedURL.path]) else {
            throw UpdatePreparationError.cannotStage
        }
        try await validateCandidate(stagedURL,
                                    expectedBundleIdentifier: bundleIdentifier,
                                    version: version)
        try Task.checkCancellation()
        completed = true
        return PreparedUpdate(stagedURL: stagedURL)
    }

    nonisolated private static func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        // zip 里套了一层文件夹的情况
        for item in items {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
               let nested = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil),
               let app = nested.first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }
        return nil
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func archiveSummary(from output: String) -> UpdateArchiveSummary? {
        let pattern = #"(?m)^([0-9]+) files?, ([0-9]+) bytes uncompressed, ([0-9]+) bytes compressed:"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: output,
                                                range: NSRange(output.startIndex..., in: output)),
              match.numberOfRanges == 4 else { return nil }
        func integer(at index: Int) -> Int64? {
            guard let range = Range(match.range(at: index), in: output) else { return nil }
            return Int64(output[range])
        }
        guard let entries = integer(at: 1), let expanded = integer(at: 2),
              let compressed = integer(at: 3), entries <= Int64(Int.max) else { return nil }
        return UpdateArchiveSummary(entries: Int(entries),
                                    expandedBytes: expanded,
                                    compressedBytes: compressed)
    }

    nonisolated private static func archiveSummary(for url: URL) async throws -> UpdateArchiveSummary {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-t", url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let box = UpdateProcessBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            if box.install(process) { process.terminate() }
            process.waitUntilExit()
            box.clear(process)
            try Task.checkCancellation()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8),
                  let summary = archiveSummary(from: text) else {
                throw UpdatePreparationError.cannotInspectArchive
            }
            return summary
        } onCancel: {
            box.cancel()
        }
    }

    nonisolated private static func validateCandidate(_ appURL: URL,
                                                       expectedBundleIdentifier: String,
                                                       version: String) async throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: infoData,
                                                                    options: [],
                                                                    format: nil) as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              bundleIdentifier == expectedBundleIdentifier else {
            throw UpdatePreparationError.identityMismatch
        }
        guard isExpectedVersion(info["CFBundleShortVersionString"] as? String, release: version) else {
            throw UpdatePreparationError.versionMismatch
        }
        guard let executableName = info["CFBundleExecutable"] as? String,
              executableName == (executableName as NSString).lastPathComponent,
              !executableName.isEmpty else {
            throw UpdatePreparationError.missingExecutable
        }
        let executable = appURL.appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executableName)
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              try await executableSupportsCurrentArchitecture(executable),
              try await runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path]) else {
            throw UpdatePreparationError.invalidApplication
        }
    }

    nonisolated private static func executableSupportsCurrentArchitecture(_ executable: URL) async throws -> Bool {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        return false
        #endif
        return try await runTool("/usr/bin/lipo", ["-verify_arch", architecture, executable.path])
    }

    nonisolated private static func runTool(_ path: String, _ arguments: [String]) async throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let box = UpdateProcessBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            if box.install(process) { process.terminate() }
            process.waitUntilExit()
            box.clear(process)
            try Task.checkCancellation()
            return process.terminationStatus == 0
        } onCancel: {
            box.cancel()
        }
    }

    nonisolated static func exchangeItems(_ first: URL, _ second: URL) throws {
        guard first.deletingLastPathComponent().standardizedFileURL
                == second.deletingLastPathComponent().standardizedFileURL else {
            throw UpdatePreparationError.exchangeRequiresSiblings
        }
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                Darwin.renameatx_np(AT_FDCWD, firstPath,
                                    AT_FDCWD, secondPath,
                                    UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    nonisolated private static func discardStagedItem(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var resultingURL: NSURL?
        try? FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    private func installPreparedUpdate(_ prepared: PreparedUpdate,
                                       currentURL: URL,
                                       fileURL: URL) {
        setProgress(text: "正在安装…", indeterminate: true)
        let markerURL = Self.pendingMarkerURL(for: prepared.stagedURL)
        let pendingState = PendingUpdateState(currentPath: currentURL.path,
                                              previousPath: prepared.stagedURL.path,
                                              version: versionLabel,
                                              launchAttempted: false)
        do {
            try Self.writePendingState(pendingState, to: markerURL)
            // staging 与当前 App 是同目录兄弟项；RENAME_SWAP 要么完整交换，要么完全不动。
            try Self.exchangeItems(currentURL, prepared.stagedURL)
        } catch {
            try? FileManager.default.removeItem(at: markerURL)
            Task.detached { Self.discardStagedItem(prepared.stagedURL) }
            let copied = revealFallback(fileURL: fileURL,
                                        reason: "替换应用失败：\(error.localizedDescription)")
            if copied {
                Task.detached { try? FileManager.default.removeItem(at: fileURL) }
            }
            return
        }
        try? FileManager.default.removeItem(at: fileURL)

        // 交换后 currentURL 是新版，stagedURL 是仍可原子换回的旧版。
        closeProgress()
        let alert = NSAlert()
        alert.messageText = "更新已准备"
        alert.informativeText = "立即重新打开以完成 Echo Player \(versionLabel) 安装；暂不安装将继续使用当前版本。"
        alert.addButton(withTitle: "立即重新打开")
        alert.addButton(withTitle: "暂不安装")
        if alert.runModal() == .alertFirstButtonReturn {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: currentURL, configuration: config) { application, error in
                DispatchQueue.main.async {
                    guard let application, error == nil else {
                        try? FileManager.default.removeItem(at: markerURL)
                        self.restorePreviousVersion(from: prepared.stagedURL,
                                                    currentURL: currentURL,
                                                    error: error)
                        return
                    }
                    self.monitorLaunchedUpdate(application, previousURL: prepared.stagedURL,
                                               currentURL: currentURL, markerURL: markerURL)
                }
            }
        } else {
            do {
                try Self.exchangeItems(currentURL, prepared.stagedURL)
                try? FileManager.default.removeItem(at: markerURL)
                Task.detached { Self.discardStagedItem(prepared.stagedURL) }
            } catch {
                NSWorkspace.shared.activateFileViewerSelecting([prepared.stagedURL])
            }
        }
    }

    /// 新版首次启动时留下“已尝试”状态；如果下次启动仍未收到健康确认，
    /// 说明上次在初始化阶段退出，直接原子换回旧版。
    func beginPendingUpdateLaunch() -> Bool {
        guard var pending = Self.pendingState(for: Bundle.main.bundleURL) else { return false }
        if pending.state.launchAttempted {
            do {
                try Self.exchangeItems(pending.currentURL, pending.previousURL)
                try? FileManager.default.removeItem(at: pending.markerURL)
                Task.detached { Self.discardStagedItem(pending.previousURL) }
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: pending.currentURL, configuration: config) { _, _ in
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            } catch {
                NSWorkspace.shared.activateFileViewerSelecting([pending.previousURL])
            }
            return true
        }

        pending.state.launchAttempted = true
        do {
            try Self.writePendingState(pending.state, to: pending.markerURL)
            pendingLaunchState = (pending.state, pending.markerURL)
        } catch {
            return false
        }
        return false
    }

    /// 主事件循环和窗口都存活一段时间后才删除旧版。
    func confirmPendingUpdateLaunchAfterHealthCheck() {
        guard let pending = pendingLaunchState else { return }
        pendingLaunchState = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard let current = Self.pendingState(for: Bundle.main.bundleURL),
                  current.markerURL == pending.markerURL,
                  current.state.launchAttempted else { return }
            try? FileManager.default.removeItem(at: current.markerURL)
            Task.detached { Self.discardStagedItem(current.previousURL) }
        }
    }

    private func monitorLaunchedUpdate(_ application: NSRunningApplication,
                                       previousURL: URL, currentURL: URL, markerURL: URL) {
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                if !FileManager.default.fileExists(atPath: markerURL.path) {
                    NSApp.terminate(nil)
                    return
                }
                if application.isTerminated {
                    try? FileManager.default.removeItem(at: markerURL)
                    restorePreviousVersion(from: previousURL, currentURL: currentURL,
                                           error: UpdatePreparationError.healthCheckFailed)
                    return
                }
            }
            _ = application.terminate()
            for _ in 0..<10 where !application.isTerminated {
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? FileManager.default.removeItem(at: markerURL)
            restorePreviousVersion(from: previousURL, currentURL: currentURL,
                                   error: UpdatePreparationError.healthCheckFailed)
        }
    }

    nonisolated private static func writePendingState(_ state: PendingUpdateState,
                                                       to markerURL: URL) throws {
        try JSONEncoder().encode(state).write(to: markerURL, options: .atomic)
    }

    nonisolated private static func pendingState(for currentURL: URL) -> PendingStateLocation? {
        let directory = currentURL.deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }
        for markerURL in items where markerURL.lastPathComponent.hasSuffix(pendingMarkerSuffix) {
            guard let data = try? Data(contentsOf: markerURL),
                  let state = try? JSONDecoder().decode(PendingUpdateState.self, from: data) else { continue }
            let recordedCurrent = URL(fileURLWithPath: state.currentPath)
            let previousURL = URL(fileURLWithPath: state.previousPath)
            guard recordedCurrent.standardizedFileURL == currentURL.standardizedFileURL,
                  previousURL.deletingLastPathComponent().standardizedFileURL
                    == directory.standardizedFileURL,
                  pendingMarkerURL(for: previousURL).standardizedFileURL
                    == markerURL.standardizedFileURL,
                  FileManager.default.fileExists(atPath: previousURL.path),
                  isExpectedVersion(Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                  ) as? String, release: state.version) else { continue }
            return PendingStateLocation(state: state, markerURL: markerURL,
                                        currentURL: currentURL, previousURL: previousURL)
        }
        return nil
    }

    // MARK: - 失败兜底

    private func clearActiveWork() {
        downloadTask?.cancel()
        downloadTask = nil
        activeSession?.invalidateAndCancel()
        activeSession = nil
        processingGeneration &+= 1
        processingTask?.cancel()
        processingTask = nil
    }

    private func fail(_ message: String) {
        clearActiveWork()
        closeProgress()
        let alert = NSAlert()
        alert.messageText = "自动更新未完成"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 失败 + 提供"前往发布页"手动下载的出路。
    private func failWithPage(_ message: String) {
        clearActiveWork()
        closeProgress()
        let alert = NSAlert()
        alert.messageText = "自动更新未完成"
        alert.informativeText = message + "\n你可以前往发布页手动下载。"
        alert.addButton(withTitle: "前往发布页")
        alert.addButton(withTitle: "以后再说")
        if alert.runModal() == .alertFirstButtonReturn, let page = releasePageURL {
            NSWorkspace.shared.open(page)
        }
    }

    /// 已下载成功但无法自动替换：优先把 zip 拷到"下载"并在访达里展示。
    /// 返回 true 表示已有持久副本，调用方可以删除临时下载。
    private func revealFallback(fileURL: URL, reason: String) -> Bool {
        clearActiveWork()
        closeProgress()
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        var shown = fileURL
        var copied = false
        if let downloads {
            var dest = downloads.appendingPathComponent("EchoPlayer-\(versionLabel).zip")
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = downloads.appendingPathComponent("EchoPlayer-\(versionLabel)-\(UUID().uuidString.prefix(8)).zip")
            }
            if (try? FileManager.default.copyItem(at: fileURL, to: dest)) != nil {
                shown = dest
                copied = true
            }
        }
        let alert = NSAlert()
        alert.messageText = "已下载，但无法自动安装"
        alert.informativeText = reason + (copied
            ? "\n更新包已放到「下载」文件夹，解压后拖到「应用程序」替换即可。"
            : "\n无法写入「下载」文件夹。临时更新包仍保留，请在退出前复制到安全位置。")
        alert.addButton(withTitle: "在访达中显示")
        alert.addButton(withTitle: "前往发布页")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([shown])
        } else if let page = releasePageURL {
            NSWorkspace.shared.open(page)
        }
        return copied
    }

    private func restorePreviousVersion(from previousURL: URL, currentURL: URL, error: Error?) {
        var restored = false
        do {
            try Self.exchangeItems(currentURL, previousURL)
            restored = true
            // 换回后 previousURL 装的是启动失败的新版，放进废纸篓。
            Task.detached { Self.discardStagedItem(previousURL) }
        } catch {
            NSWorkspace.shared.activateFileViewerSelecting([previousURL])
        }

        let alert = NSAlert()
        alert.messageText = restored ? "无法重新打开，已恢复旧版" : "无法重新打开更新"
        alert.informativeText = error?.localizedDescription ?? "请手动重新打开 Echo Player。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 进度面板

    private func showProgress(text: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 96),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "软件更新"
        panel.isFloatingPanel = true

        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 20, y: 56, width: 340, height: 20)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 30, width: 280, height: 18))
        bar.minValue = 0; bar.maxValue = 1
        bar.isIndeterminate = false
        bar.startAnimation(nil)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelDownload))
        cancel.frame = NSRect(x: 306, y: 24, width: 60, height: 28)
        cancel.bezelStyle = .rounded

        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(bar)
        panel.contentView?.addSubview(cancel)
        panel.center()
        panel.orderFrontRegardless()

        progressPanel = panel
        progressBar = bar
        statusLabel = label
    }

    private func setProgress(text: String? = nil, fraction: Double? = nil, indeterminate: Bool = false) {
        if let text { statusLabel?.stringValue = text }
        progressBar?.isIndeterminate = indeterminate
        if indeterminate { progressBar?.startAnimation(nil) }
        if let fraction { progressBar?.doubleValue = fraction }
    }

    private func closeProgress() {
        progressPanel?.orderOut(nil)
        progressPanel = nil
        progressBar = nil
        statusLabel = nil
    }

    @objc private func cancelDownload() {
        clearActiveWork()
        closeProgress()
    }
}

private struct PreparedUpdate: Sendable {
    let stagedURL: URL
}

struct UpdateArchiveSummary: Equatable {
    let entries: Int
    let expandedBytes: Int64
    let compressedBytes: Int64
}

private struct PendingUpdateState: Codable {
    let currentPath: String
    let previousPath: String
    let version: String
    var launchAttempted: Bool
}

private struct PendingStateLocation {
    var state: PendingUpdateState
    let markerURL: URL
    let currentURL: URL
    let previousURL: URL
}

private enum UpdatePreparationError: LocalizedError {
    case hashMismatch
    case cannotInspectArchive
    case archiveLimitExceeded
    case insufficientDiskSpace
    case healthCheckFailed
    case cannotExtract
    case missingApplication
    case invalidApplicationPath
    case containerNotWritable
    case cannotStage
    case identityMismatch
    case versionMismatch
    case missingExecutable
    case invalidApplication
    case exchangeRequiresSiblings

    var errorDescription: String? {
        switch self {
        case .hashMismatch:
            return "下载内容与发布指纹不符（可能被篡改或传输损坏），已放弃安装。"
        case .cannotInspectArchive:
            return "无法检查更新包结构，已拒绝解压。"
        case .archiveLimitExceeded:
            return "更新包的体积、文件数或压缩比异常，已拒绝解压。"
        case .insufficientDiskSpace:
            return "磁盘剩余空间不足，无法安全解压更新包。"
        case .healthCheckFailed:
            return "新版未能通过启动健康检查。"
        case .cannotExtract:
            return "更新包解压失败。"
        case .missingApplication:
            return "更新包里没有找到应用，可能下载了错误的文件。"
        case .invalidApplicationPath:
            return "更新包的应用路径异常，已拒绝安装。"
        case .containerNotWritable:
            return "应用所在目录不可写。"
        case .cannotStage:
            return "无法把更新暂存到应用所在目录。"
        case .identityMismatch:
            return "更新包身份不符，已拒绝安装。"
        case .versionMismatch:
            return "更新包版本与发布版本不符，已拒绝安装。"
        case .missingExecutable:
            return "更新包缺少可执行文件，已拒绝安装。"
        case .invalidApplication:
            return "更新包不完整或不支持当前 Mac，已拒绝安装。"
        case .exchangeRequiresSiblings:
            return "更新暂存位置不在应用目录中。"
        }
    }
}

private final class UpdateProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// 返回 true 表示取消早于 Process 安装，调用方应在 run 后立刻终止。
    func install(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return true }
        self.process = process
        return false
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }
}

// MARK: - 下载进度回调

extension UpdateInstaller: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.isTrustedSource(url) else {
            completionHandler(nil)
            task.cancel()
            Task { @MainActor in
                guard self.downloadTask === task else { return }
                self.failWithPage("更新下载被重定向到不可信地址，已停止。")
            }
            return
        }
        completionHandler(request)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.maximumDownloadBytes
            || totalBytesExpectedToWrite > Self.maximumDownloadBytes {
            downloadTask.cancel()
            Task { @MainActor in
                guard self.downloadTask === downloadTask else { return }
                self.failWithPage("更新包超过自动更新的安全体积上限。")
            }
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let mb = Double(totalBytesWritten) / 1_048_576
        let totalMB = Double(totalBytesExpectedToWrite) / 1_048_576
        Task { @MainActor in
            guard self.downloadTask === downloadTask else { return }
            self.setProgress(text: String(format: "正在下载 Echo Player %@…（%.0f / %.0f MB）",
                                          self.versionLabel, mb, totalMB),
                             fraction: fraction)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // 回调返回后系统会删临时文件：先挪到自己的临时目录
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.downloadPrefix)\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
        } catch {
            Task { @MainActor in
                guard self.downloadTask === downloadTask else { return }
                self.failWithPage("无法保存下载文件：\(error.localizedDescription)")
            }
            return
        }
        Task { @MainActor in
            guard self.downloadTask === downloadTask else {
                try? FileManager.default.removeItem(at: kept)
                return
            }
            self.finishDownload(at: kept, task: downloadTask)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        Task { @MainActor in
            if self.activeSession === session { self.activeSession = nil }
            guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
            guard self.downloadTask === task else { return }
            self.failWithPage("下载失败：\(error.localizedDescription)")
        }
    }
}
