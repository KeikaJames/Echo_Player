import Foundation
import AppKit

/// 检查 GitHub Releases 上的新版本。
/// 应用只提示并打开官方发布页，不在进程内下载或替换自身。
enum UpdateChecker {
    static var repoSlug: String {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "UpdateRepositoryOverride"),
           isValidRepoSlug(override) {
            return override
        }
        #endif
        let configured = (Bundle.main.object(forInfoDictionaryKey: "UpdateRepository") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return isValidRepoSlug(configured) ? configured : ""
    }

    static var isConfigured: Bool { !repoSlug.isEmpty && !repoSlug.hasPrefix("OWNER/") }

    private static let lastCheckKey = "lastUpdateCheckAt"

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let body: String?
    }

    static func autoCheck() {
        guard isConfigured else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        Task { await check(interactive: false) }
    }

    static func checkInteractively() {
        Task { await check(interactive: true) }
    }

    private static func check(interactive: Bool) async {
        guard isConfigured else {
            if interactive {
                await alert(title: "尚未配置更新源",
                            message: "请在 Info.plist 的 UpdateRepository 中填写 GitHub 仓库，例如 yourname/EchoPlayer。")
            }
            return
        }
        guard let endpoint = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest") else { return }
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8

        guard let (data, response) = try? await BoundedHTTPClient.data(for: request, maxBytes: 1024 * 1024),
              response.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let page = trustedReleasePage(release.html_url) else {
            if interactive {
                await alert(title: "无法检查更新", message: "网络不可用或仓库暂无发布版本。")
              }
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

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
                alert.addButton(withTitle: "前往下载")
                alert.addButton(withTitle: "以后再说")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(page)
                }
            }
        } else if interactive {
            await alert(title: "已是最新版本", message: "当前版本 \(current) 就是最新发布的版本。")
        }
    }

    private static func isValidRepoSlug(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts.contains("."), !parts.contains("..") else { return false }
        return value.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#,
                           options: .regularExpression) != nil
    }

    private static func trustedReleasePage(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https",
              url.host?.lowercased() == "github.com" else { return nil }
        let prefix = "/\(repoSlug.lowercased())/releases/"
        return url.path.lowercased().hasPrefix(prefix) ? url : nil
    }

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
        return pb.prerelease && !pa.prerelease
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
