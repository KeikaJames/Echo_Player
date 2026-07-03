import Foundation
import AppKit
import CryptoKit

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

    private var progressPanel: NSPanel?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var downloadTask: URLSessionDownloadTask?
    private var releasePageURL: URL?
    private var expectedSHA256: String?
    private var versionLabel = ""

    // MARK: - 入口

    func install(from assetURL: URL, expectedSHA256: String?, version: String, releasePageURL: URL?) {
        guard Self.isTrustedSource(assetURL) else {
            fail("更新包地址不在可信来源（GitHub）上，已停止。")
            return
        }
        guard downloadTask == nil else { return }   // 已在更新中
        self.releasePageURL = releasePageURL
        self.expectedSHA256 = expectedSHA256?.lowercased()
        self.versionLabel = version

        showProgress(text: "正在下载 Echo Player \(version)…")
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: assetURL)
        downloadTask = task
        task.resume()
    }

    /// 只信 GitHub 的 HTTPS 直链（release 资产会 302 到 objects.githubusercontent.com）。
    nonisolated static func isTrustedSource(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    // MARK: - 校验 + 替换 + 重启

    private func finishDownload(at fileURL: URL) {
        defer { downloadTask = nil }

        // 1) SHA-256 指纹比对（发布说明未公布指纹时跳过，但记录日志）
        if let expected = expectedSHA256 {
            guard let actual = Self.sha256(of: fileURL) else {
                failWithPage("无法读取下载文件。")
                return
            }
            guard actual == expected else {
                NSLog("更新校验失败：期望 %@ 实际 %@", expected, actual)
                failWithPage("下载内容与发布指纹不符（可能被篡改或传输损坏），已放弃安装。")
                return
            }
        } else {
            NSLog("本次发布未公布 SHA-256 指纹，跳过校验")
        }

        setProgress(text: "正在校验并解压…", indeterminate: true)

        // 2) ditto 解压（保留符号链接与签名结构）
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoPlayerUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", fileURL.path, workDir.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            failWithPage("更新包解压失败：\(error.localizedDescription)")
            return
        }

        // 3) 找出 .app 并核验身份（bundle id 必须与当前应用一致）
        guard let newApp = Self.findApp(in: workDir) else {
            failWithPage("更新包里没有找到应用，可能下载了错误的文件。")
            return
        }
        let newInfo = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
        let newBundleID = newInfo?["CFBundleIdentifier"] as? String
        guard let newBundleID, newBundleID == Bundle.main.bundleIdentifier else {
            failWithPage("更新包身份不符（\(newBundleID ?? "未知")），已拒绝安装。")
            return
        }

        // 4) 替换自身：旧版进废纸篓，新版归位；失败则把旧版救回来
        let currentURL = Bundle.main.bundleURL
        let container = currentURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: container.path) else {
            revealFallback(fileURL: fileURL, reason: "应用所在目录不可写。")
            return
        }
        var trashedURL: NSURL?
        do {
            try FileManager.default.trashItem(at: currentURL, resultingItemURL: &trashedURL)
            try FileManager.default.moveItem(at: newApp, to: currentURL)
        } catch {
            // 尽力恢复旧版，避免"应用消失"
            if let trashed = trashedURL as URL?,
               !FileManager.default.fileExists(atPath: currentURL.path) {
                try? FileManager.default.moveItem(at: trashed, to: currentURL)
            }
            revealFallback(fileURL: fileURL, reason: "替换应用失败：\(error.localizedDescription)")
            return
        }

        // 5) 重启到新版本
        closeProgress()
        let alert = NSAlert()
        alert.messageText = "更新完成"
        alert.informativeText = "Echo Player \(versionLabel) 已安装，重新打开即可使用新版本。"
        alert.addButton(withTitle: "立即重新打开")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: currentURL, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    private static func findApp(in dir: URL) -> URL? {
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

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 失败兜底

    private func fail(_ message: String) {
        closeProgress()
        downloadTask = nil
        let alert = NSAlert()
        alert.messageText = "自动更新未完成"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 失败 + 提供"前往发布页"手动下载的出路。
    private func failWithPage(_ message: String) {
        closeProgress()
        downloadTask = nil
        let alert = NSAlert()
        alert.messageText = "自动更新未完成"
        alert.informativeText = message + "\n你可以前往发布页手动下载。"
        alert.addButton(withTitle: "前往发布页")
        alert.addButton(withTitle: "以后再说")
        if alert.runModal() == .alertFirstButtonReturn, let page = releasePageURL {
            NSWorkspace.shared.open(page)
        }
    }

    /// 已下载成功但无法自动替换：把 zip 拷到"下载"并在访达里展示。
    private func revealFallback(fileURL: URL, reason: String) {
        closeProgress()
        downloadTask = nil
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        var shown = fileURL
        if let downloads {
            let dest = downloads.appendingPathComponent("EchoPlayer-\(versionLabel).zip")
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: fileURL, to: dest)) != nil { shown = dest }
        }
        let alert = NSAlert()
        alert.messageText = "已下载，但无法自动安装"
        alert.informativeText = reason + "\n更新包已放到「下载」文件夹，解压后拖到「应用程序」替换即可。"
        alert.addButton(withTitle: "在访达中显示")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([shown])
        }
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
        downloadTask?.cancel()
        downloadTask = nil
        closeProgress()
    }
}

// MARK: - 下载进度回调

extension UpdateInstaller: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let mb = Double(totalBytesWritten) / 1_048_576
        let totalMB = Double(totalBytesExpectedToWrite) / 1_048_576
        Task { @MainActor in
            self.setProgress(text: String(format: "正在下载 Echo Player %@…（%.0f / %.0f MB）",
                                          self.versionLabel, mb, totalMB),
                             fraction: fraction)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // 回调返回后系统会删临时文件：先挪到自己的临时目录
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoPlayerDownload-\(UUID().uuidString).zip")
        try? FileManager.default.moveItem(at: location, to: kept)
        Task { @MainActor in
            self.finishDownload(at: kept)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor in
            self.downloadTask = nil
            self.failWithPage("下载失败：\(error.localizedDescription)")
        }
    }
}
