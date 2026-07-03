import SwiftUI
import AppKit

/// 窗外光晕：一个无边框、透明、不接受鼠标事件的子窗口贴在主窗口正下方，
/// 尺寸比主窗口四周各大出 margin，光晕沿主窗口轮廓描边后向外洇开——
/// 内半边被不透明的主窗口盖住（内强由窗内 EdgeGlow 负责），外半边洒在桌面上（外弱）。
final class GlowHaloController {
    static let shared = GlowHaloController()
    static let margin: CGFloat = 90

    private var halo: NSWindow?
    private weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var fullScreen = false

    var enabled = true {
        didSet { updateVisibility() }
    }

    /// 找到主窗口后调用（AppDelegate 里挂接）。
    func attach(to window: NSWindow) {
        guard parent !== window else { return }
        detach()
        parent = window

        let halo = NSWindow(contentRect: window.frame.insetBy(dx: -Self.margin, dy: -Self.margin),
                            styleMask: .borderless, backing: .buffered, defer: false)
        halo.isOpaque = false
        halo.backgroundColor = .clear
        halo.ignoresMouseEvents = true
        halo.hasShadow = false
        halo.level = window.level
        halo.collectionBehavior = [.transient, .fullScreenAuxiliary]
        halo.contentView = NSHostingView(rootView: OuterGlowView())
        window.addChildWindow(halo, ordered: .below)
        self.halo = halo
        syncFrame()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            self?.syncFrame()
        })
        observers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
            self?.syncFrame()   // 暴力拖拽后校正一次
        })
        observers.append(nc.addObserver(forName: NSWindow.willMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
            self?.halo?.orderOut(nil)
        })
        observers.append(nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
            self?.syncFrame()
            self?.updateVisibility()
        })
        observers.append(nc.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            self?.fullScreen = true
            self?.updateVisibility()
        })
        observers.append(nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            self?.fullScreen = false
            self?.syncFrame()
            self?.updateVisibility()
        })
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.detach()
        })
        updateVisibility()
    }

    private func syncFrame() {
        guard let parent, let halo else { return }
        // display: false —— live-resize 期间该通知可达 60 次/秒，同步重绘一个
        // 带两层大半径 blur 的超大子窗口会让拖拽发滞；交给下个 CA 事务合并
        halo.setFrame(parent.frame.insetBy(dx: -Self.margin, dy: -Self.margin), display: false)
    }

    private func updateVisibility() {
        guard let halo, let parent else { return }
        if enabled && !fullScreen && parent.isVisible {
            if halo.parent == nil { parent.addChildWindow(halo, ordered: .below) }
            halo.orderFront(nil)
            syncFrame()
        } else {
            halo.parent?.removeChildWindow(halo)
            halo.orderOut(nil)
        }
    }

    private func detach() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let halo {
            halo.parent?.removeChildWindow(halo)
            halo.orderOut(nil)
        }
        halo = nil
        parent = nil
    }
}

/// 子窗口里的向外光晕：沿主窗口轮廓（内缩 margin 的圆角矩形）描边，
/// 大模糊半径让光自然洒出窗口轮廓之外；颜色/节拍与窗内光晕同源。
private struct OuterGlowView: View {
    @State private var dynamics = GlowDynamics()

    var body: some View {
        // 空闲（无曲目/暂停）降帧到 8fps：光晕漂移是低频信号，肉眼无感，
        // 却省下 2/3 的空闲 GPU 合成（这是带两层大 blur 的全窗离屏渲染）
        let playerModel = PlayerModel.shared
        let idle = playerModel.currentTrack == nil || !playerModel.isPlaying
        TimelineView(.animation(minimumInterval: idle ? 1.0 / 8.0 : 1.0 / 24.0)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let model = PlayerModel.shared
            dynamics.advance(to: now,
                             level: CGFloat(model.audioLevel()),
                             pulse: CGFloat(model.audioPulse()),
                             ambient: model.glowAmbientColors())
            let phase = dynamics.gradientPhase
            let pop = dynamics.beatEnvelope
            let lift = Double(max(0, pop))
            let level = Double(dynamics.displayLevel)

            return GeometryReader { geo in
                let margin = GlowHaloController.margin
                let rect = CGRect(origin: .zero, size: geo.size).insetBy(dx: margin, dy: margin)

                let colors: [Color] = dynamics.hasAmbient
                    ? dynamics.ambientColors()
                    : (0..<7).map { i in
                        let base = Double(i) / 6.0
                        let hue = (base + sin(phase * 0.9 + base * .pi * 2) * 0.08 + 1)
                            .truncatingRemainder(dividingBy: 1)
                        let saturation = 0.8 + 0.15 * sin(phase * 0.7 + base * .pi)
                        return Color(hue: hue, saturation: saturation, brightness: 1.0)
                    }
                let gradient = AngularGradient(
                    gradient: Gradient(colors: colors + [colors[0]]),
                    center: .center,
                    angle: dynamics.hasAmbient ? .degrees(-90 + sin(phase * 0.5) * 6) : .degrees(sin(phase * 1.2) * 120 + 180)
                )
                let breathing = 0.5 + 0.5 * sin(phase * 0.9)
                let strength = 0.22 + 0.10 * breathing + lift * 0.45 + level * 0.15

                ZStack {
                    // 中层溢光
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .path(in: rect)
                        .stroke(gradient, lineWidth: 22 + CGFloat(lift) * 26)
                        .blur(radius: 26)
                        .opacity(min(0.85, strength))
                    // 大范围外洒（"外弱"）
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .path(in: rect)
                        .stroke(gradient, lineWidth: 44 + CGFloat(lift) * 40)
                        .blur(radius: 52)
                        .opacity(min(0.6, strength * 0.7))
                }
                .drawingGroup()
            }
        }
        .allowsHitTesting(false)
    }
}
