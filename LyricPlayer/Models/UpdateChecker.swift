import Foundation
import AppKit

/// 检查 GitHub Releases 上的新版本。
/// 发布流程：在 GitHub 仓库发一个 tag 形如 v1.2 的 Release 并附上打包好的 .app（zip），
/// 用户端启动时自动检查（每 24 小时至多一次），发现新版弹窗一键跳转下载。
enum UpdateChecker {
    /// 更新源：读 Info.plist 的 UpdateRepository 键（"用户名/仓库名"）。
    /// 发布前只需改 Info.plist 那一处，代码不动。
    /// 调试用覆盖：`defaults write <bundle-id> UpdateRepositoryOverride 某仓库`
    /// 可在不改包的情况下对沙盒仓库做更新链路端到端测试。
    static var repoSlug: String {
        if let override = UserDefaults.standard.string(forKey: "UpdateRepositoryOverride"),
           !override.isEmpty {
            return override
        }
        return (Bundle.main.object(forInfoDictionaryKey: "UpdateRepository") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// 是否已配置真实仓库（占位值 OWNER/… 视为未配置）。
    static var isConfigured: Bool {
        repoSlug.contains("/") && !repoSlug.hasPrefix("OWNER/")
    }

    private static let lastCheckKey = "lastUpdateCheckAt"

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let name: String?
        let body: String?
        let assets: [Asset]?

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int?
        }
    }

    /// 从发布资产中挑更新包：优先带 Echo 字样的 .zip，其次任意 .zip；
    /// 地址必须过可信来源检查（github.com HTTPS）。
    private static func pickUpdateAsset(_ release: Release) -> URL? {
        let zips = (release.assets ?? []).filter { $0.name.lowercased().hasSuffix(".zip") }
        let preferred = zips.first { $0.name.lowercased().contains("echo") } ?? zips.first
        guard let preferred, let url = URL(string: preferred.browser_download_url),
              UpdateInstaller.isTrustedSource(url) else { return nil }
        return url
    }

    /// 从发布说明里提取 SHA-256 指纹（CI 发版时自动写入，形如 `SHA256: ab12…`）。
    private static func sha256FromNotes(_ notes: String?) -> String? {
        guard let notes else { return nil }
        guard let match = notes.range(of: #"(?i)sha-?256[^0-9a-fA-F]{0,20}([0-9a-fA-F]{64})"#,
                                      options: .regularExpression) else { return nil }
        let hex = notes[match].suffix(64)
        return String(hex).lowercased()
    }

    /// 启动时静默检查（未配置仓库或 24 小时内查过则跳过）。
    static func autoCheck() {
        guard isConfigured else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        Task { await check(interactive: false) }
    }

    /// 菜单「检查更新…」入口。
    static func checkInteractively() {
        Task { await check(interactive: true) }
    }

    private static func check(interactive: Bool) async {
        guard isConfigured else {
            if interactive {
                await alert(title: "尚未配置更新源",
                            message: "发布到 GitHub 后，把 Info.plist 里 UpdateRepository 改成你的仓库（如 yourname/EchoPlayer）即可启用检查更新。")
            }
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            if interactive {
                await alert(title: "无法检查更新", message: "网络不可用或仓库暂无发布版本。")
            }
            return
        }

        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name

        if isVersion(latest, newerThan: current) {
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "发现新版本 \(release.tag_name)"
                var informative = "当前版本 \(current)。"
                if let notes = release.body, !notes.isEmpty {
                    informative += "\n\n" + notes.prefix(400)
                }
                alert.informativeText = informative
                let page = URL(string: release.html_url)
                let asset = pickUpdateAsset(release)
                if asset != nil {
                    alert.addButton(withTitle: "自动更新")
                    alert.addButton(withTitle: "前往发布页")
                } else {
                    alert.addButton(withTitle: "前往下载")   // 该发布没有可用 zip 资产
                }
                alert.addButton(withTitle: "以后再说")
                let response = alert.runModal()

                if let asset {
                    switch response {
                    case .alertFirstButtonReturn:
                        UpdateInstaller.shared.install(from: asset,
                                                       expectedSHA256: sha256FromNotes(release.body),
                                                       version: release.tag_name,
                                                       releasePageURL: page)
                    case .alertSecondButtonReturn:
                        if let page { NSWorkspace.shared.open(page) }
                    default: break
                    }
                } else if response == .alertFirstButtonReturn, let page {
                    NSWorkspace.shared.open(page)
                }
            }
        } else if interactive {
            await alert(title: "已是最新版本", message: "当前版本 \(current) 就是最新发布的版本。")
        }
    }

    /// 语义化版本比较（按数字段逐段比）。
    /// 边界：大小写 v 前缀都剥；"1.2-beta" 视为旧于 "1.2"；
    /// 纯文字 tag（latest/stable）无法比较，一律不提示更新。
    private static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parse(_ s: String) -> (nums: [Int], prerelease: Bool, hasDigit: Bool) {
            var core = s
            if core.hasPrefix("v") || core.hasPrefix("V") { core.removeFirst() }
            let parts = core.split(separator: "-", maxSplits: 1)
            let nums = (parts.first ?? "").split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
            return (nums, parts.count > 1, core.contains(where: \.isNumber))
        }
        let pa = parse(a), pb = parse(b)
        guard pa.hasDigit else { return false }
        for i in 0..<max(pa.nums.count, pb.nums.count) {
            let x = i < pa.nums.count ? pa.nums[i] : 0
            let y = i < pb.nums.count ? pb.nums[i] : 0
            if x != y { return x > y }
        }
        return pb.prerelease && !pa.prerelease   // 数字段相等：正式版比预发布新
    }

    @MainActor
    private static func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
