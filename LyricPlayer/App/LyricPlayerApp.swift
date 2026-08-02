import SwiftUI
import AppKit

@main
struct LyricPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = PlayerModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 780)
        .restorationBehavior(.disabled)   // 不恢复历史窗口，避免堆叠
        .commands {
            PlayerCommands()
        }

        // 麦克风实时字幕：独立浮动小窗
        Window("实时字幕", id: "live-captions") {
            LiveCaptionsView()
                .environment(model)
        }
        .defaultSize(width: 760, height: 380)
        .windowStyle(.hiddenTitleBar)   // 玻璃直通到顶（比手动改 styleMask 可靠，SwiftUI 不会回改）
        .windowLevel(.floating)
        .restorationBehavior(.disabled)       // 上次开着实时字幕退出，也不在下次启动时自动恢复
        .defaultLaunchBehavior(.suppressed)   // 启动时绝不自动呈现
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - 启动

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 全应用统一浅色外观。
        // 注意：不要用 SwiftUI 的 .preferredColorScheme —— 在 macOS 26 上它会让
        // WindowGroup 启动时重复创建窗口（实测每次启动固定多开 3 个）。
        NSApp.appearance = NSAppearance(named: .aqua)
        // 窗口恢复的最后一道保险：本应用永不保存/恢复窗口状态（杜绝多窗口堆叠）
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PlayerModel.shared.restoreState()
        UpdateChecker.autoCheck()
        GlowHaloController.shared.enabled = PlayerModel.shared.glowEnabled

        // 主窗口就绪后：挂接窗外光晕、chrome 自动隐藏，并补挂待处理的视频宽高比
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow,
                  window.styleMask.contains(.titled),
                  !(window is NSPanel),          // 打开/保存面板、NSAlert 都是 NSPanel——
                                                 // 挂上光晕/透明标题栏会把对话框弄乱
                  window.title != "实时字幕" else { return }
            GlowHaloController.shared.attach(to: window)
            WindowChromeController.shared.attach(to: window)
            PlayerModel.shared.flushPendingAspectIfNeeded()
        }

        // 延迟 2 秒后在 Apple 事件层接管"打开文档"（odoc）：
        // - 启动时携带的文件走系统原有通路（否则 AppKit 视作"文档启动"而跳过初始窗口创建）；
        // - 运行期间的打开事件由我们拦截并喂给播放列表，杜绝 SwiftUI 为其新开窗口
        //   （多窗口 bug 的第二条产生路径；handlesExternalEvents 系列对 macOS
        //   文件打开事件拦截不可靠，勿走回头路）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            NSAppleEventManager.shared().setEventHandler(
                self,
                andSelector: #selector(self.handleOpenDocuments(_:replyEvent:)),
                forEventClass: AEEventClass(kCoreEventClass),
                andEventID: AEEventID(kAEOpenDocuments)
            )
        }
    }

    // MARK: - 打开文件

    /// 运行期的 odoc Apple 事件（延迟接管后走这里）。
    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        var urls: [URL] = []
        if let list = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) {
            if list.numberOfItems > 0 {
                for index in 1...list.numberOfItems {
                    if let item = list.atIndex(index),
                       let data = item.coerce(toDescriptorType: typeFileURL)?.data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
            } else if let data = list.coerce(toDescriptorType: typeFileURL)?.data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        PlayerModel.shared.open(urls: urls)
        NSApp.activate()
    }

    /// 启动时携带文件的系统通路（接管前的头 2 秒也走这里）。
    func application(_ application: NSApplication, open urls: [URL]) {
        PlayerModel.shared.open(urls: urls)
    }

    // MARK: - 退出与关窗

    func applicationWillTerminate(_ notification: Notification) {
        PlayerModel.shared.saveState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 正在播放时关窗不退出（与音乐类 App 惯例一致），点 Dock 图标可重新打开窗口
        !PlayerModel.shared.isPlaying
    }
}

/// 菜单栏命令与全局快捷键。
struct PlayerCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    private var model: PlayerModel { PlayerModel.shared }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { UpdateChecker.checkInteractively() }
        }

        CommandGroup(replacing: .newItem) {
            Button("打开…") { model.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("播放") {
            Button(model.isPlaying ? "暂停" : "播放") { model.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])

            Divider()

            Button("上一首") { model.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("下一首") { model.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)

            Divider()

            Button("后退 10 秒") { model.skip(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            Button("前进 10 秒") { model.skip(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])

            Divider()

            Button("调高音量") { model.adjustVolume(by: 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("调低音量") { model.adjustVolume(by: -0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }

        CommandMenu("歌词") {
            Button(model.showLyrics ? "隐藏歌词" : "显示歌词") { model.showLyrics.toggle() }
                .keyboardShortcut("l", modifiers: .command)

            Button("实时字幕（麦克风）…") { openWindow(id: "live-captions") }
                .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            Button("重新识别当前曲目") { model.startLyricsPipeline(forceRecognize: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.currentTrack == nil)

            Button("导出歌词为 LRC…") { model.exportLRC() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.lyricLines.isEmpty)
        }
    }
}
