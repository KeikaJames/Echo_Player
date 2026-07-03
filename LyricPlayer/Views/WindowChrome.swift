import AppKit

/// 窗口 chrome（红绿灯、标题、工具栏）管理：
/// - 常驻：透明标题栏 + 全尺寸内容视图（材质背板从根上消灭，拖拽/最小化不再闪色带）；
/// - 视频模式：鼠标静止 2.5 秒后 chrome 整体淡出（与系统播放 HUD 同节奏），动一下鼠标即回。
final class WindowChromeController {
    static let shared = WindowChromeController()

    private weak var window: NSWindow?
    private var mouseMonitor: Any?
    private var hideTimer: Timer?
    private var videoMode = false
    private var chromeHidden = false

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.acceptsMouseMovedEvents = true
        applyMode()
    }

    func setVideoMode(_ on: Bool) {
        guard videoMode != on else { return }
        videoMode = on
        applyMode()
    }

    /// 播放暂停等状态变化时调用：暂停立即找回 chrome。
    func noteActivity() {
        showChrome()
        scheduleHide()
    }

    private func applyMode() {
        guard let window else { return }
        window.titleVisibility = videoMode ? .hidden : .visible
        if videoMode {
            startMouseMonitor()
            scheduleHide()
        } else {
            stopMouseMonitor()
            showChrome()
        }
    }

    // MARK: - 鼠标空闲检测

    private func startMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .scrollWheel, .leftMouseDown]
        ) { [weak self] event in
            if let self, event.window === self.window {
                self.showChrome()
                self.scheduleHide()
            }
            return event
        }
    }

    private func stopMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        guard videoMode else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self, self.videoMode, PlayerModel.shared.isPlaying else { return }
            self.hideChrome()
        }
    }

    // MARK: - 显隐

    private var chromeViews: [NSView] {
        guard let window else { return [] }
        return [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton),
        ].compactMap { $0 }
    }

    private func hideChrome() {
        guard let window, !chromeHidden else { return }
        chromeHidden = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            for view in chromeViews { view.animator().alphaValue = 0 }
        }
        window.toolbar?.isVisible = false
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func showChrome() {
        guard let window, chromeHidden else { return }
        chromeHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            for view in chromeViews { view.animator().alphaValue = 1 }
        }
        window.toolbar?.isVisible = true
    }
}
