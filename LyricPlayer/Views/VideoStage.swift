import SwiftUI
import AVKit

/// 视频舞台：系统原生悬浮控制条（QuickTime 同款 HUD：音量/走带/画中画/共享/倍速，
/// 自动隐藏、随鼠标浮现）+ 底部自动字幕叠加。
struct VideoStage: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        ZStack {
            if model.currentTrack?.needsFFmpeg == true {
                // FFmpeg（KSPlayer）画面：无模糊垫层，纯黑底 + 铺满的原生渲染视图
                Color.black
                FFmpegVideoView(view: model.ffmpegPlayerView)
            } else {
                // 环境垫层：同源画面放大填满 + 高斯模糊——
                // 窗口/全屏比例和视频对不上时，露出的不是黑边而是画面的模糊延伸
                BlurredVideoBackdrop(player: model.videoPlayer)
                NativeVideoPlayer(player: model.videoPlayer)
            }

            if model.showLyrics {
                subtitleOverlay
            }
        }
        .clipped()
        .ignoresSafeArea()   // 画面直通标题栏之下，全透明沉浸
    }

    // MARK: - 字幕叠加

    @ViewBuilder
    private var subtitleOverlay: some View {
        VStack {
            Spacer()
            Group {
                if let index = model.currentLineIndex, model.lyricLines.indices.contains(index) {
                    Text(model.lyricLines[index].text)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .id(index)
                        .transition(.opacity)
                } else if case .recognizing(let fraction, let message) = model.lyricsStatus,
                          model.lyricLines.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(subtitleStatusText(fraction: fraction, message: message))
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.42), in: Capsule())
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.currentLineIndex)
            .padding(.bottom, 24)   // 字幕贴底；悬浮 HUD 出现时叠于其上方区域
        }
        .allowsHitTesting(false)
    }

    private func subtitleStatusText(fraction: Double?, message: String?) -> String {
        if let message { return message }
        if let fraction, fraction > 0 { return "正在识别字幕… \(Int(fraction * 100))%" }
        return "正在识别字幕…"
    }
}

/// AVKit 原生播放视图：悬浮控制条、画中画、全屏切换全部由系统提供。
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating              // 截图同款的悬浮 HUD
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

/// FFmpeg（KSPlayer）画面容器：把 KSMEPlayer 自带的渲染 NSView 作为子视图铺满。
/// 换曲时底层 view 会变（新的 KSMEPlayer 实例），这里检测到不同就替换子视图；
/// 画面比例由 KSPlayer 的 contentMode(.scaleAspectFit) 负责，容器只管填满。
struct FFmpegVideoView: NSViewRepresentable {
    let view: NSView?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let current = container.subviews.first
        if current === view { return }
        current?.removeFromSuperview()
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// 模糊环境垫层：第二个 AVPlayerLayer 共享同一个 AVPlayer，
/// aspectFill 填满 + 高斯模糊 + 压暗，代替黑边。
struct BlurredVideoBackdrop: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> BackdropLayerView {
        BackdropLayerView()
    }

    func updateNSView(_ view: BackdropLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

final class BackdropLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    private let dimLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(48, forKey: kCIInputRadiusKey)
            playerLayer.filters = [blur]
        }
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.addSublayer(playerLayer)
        layer?.addSublayer(dimLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 出血放大：模糊后的边缘晕影留在可视区之外
        playerLayer.frame = bounds.insetBy(dx: -60, dy: -60)
        dimLayer.frame = bounds
        CATransaction.commit()
    }
}
