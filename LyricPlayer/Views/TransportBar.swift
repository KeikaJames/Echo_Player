import SwiftUI

/// 悬浮式播放控制条：macOS 26 Liquid Glass 材质。
/// 走带控制、进度、音量/倍速/歌词开关分组悬浮在内容之上。
struct TransportBar: View {
    @Environment(PlayerModel.self) private var model
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                transportCluster
                progressCluster
                utilityCluster
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    // MARK: - 走带控制（玻璃胶囊）

    private var transportCluster: some View {
        HStack(spacing: 16) {
            Button {
                model.shuffleEnabled.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.shuffleEnabled ? Color.accentColor : Color.primary.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help(model.shuffleEnabled ? "关闭随机播放" : "随机播放")

            Button {
                model.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(model.playlist.isEmpty)
            .help("上一首 (⌘←)")

            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.playlist.isEmpty)
            .help(model.isPlaying ? "暂停 (空格)" : "播放 (空格)")

            Button {
                model.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(model.playlist.isEmpty)
            .help("下一首 (⌘→)")

            Button {
                model.cycleRepeatMode()
            } label: {
                Image(systemName: model.repeatMode.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.repeatMode == .off ? Color.primary.opacity(0.85) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("循环模式：\(model.repeatMode.displayName)")
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    // MARK: - 进度（玻璃胶囊，弹性占宽）

    private var progressCluster: some View {
        HStack(spacing: 10) {
            Text(TimeFormatter.string(from: isScrubbing ? scrubValue : model.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : min(model.currentTime, sliderMax) },
                    set: { scrubValue = $0 }
                ),
                in: 0...sliderMax
            ) { editing in
                if editing {
                    scrubValue = model.currentTime
                    isScrubbing = true
                } else {
                    model.seek(to: scrubValue)
                    isScrubbing = false
                }
            }
            .controlSize(.small)
            .disabled(model.currentTrack == nil)

            Text("-" + TimeFormatter.string(from: max(0, model.duration - (isScrubbing ? scrubValue : model.currentTime))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .glassEffect(.regular, in: Capsule())
    }

    private var sliderMax: Double { max(model.duration, 0.01) }

    // MARK: - 音量 / 倍速 / 歌词（玻璃胶囊）

    private var utilityCluster: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: volumeBinding, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 80)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .help("音量 (⌘↑ / ⌘↓)")

            Menu {
                Picker("播放速度", selection: rateBinding) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Text(rateLabel(rate)).tag(Float(rate))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(rateLabel(Double(model.playbackRate)))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(width: 40)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("播放速度")

            Button {
                model.showLyrics.toggle()
            } label: {
                Image(systemName: model.showLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 14))
                    .foregroundStyle(model.showLyrics ? Color.accentColor : Color.primary.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help(model.showLyrics ? "隐藏歌词 (⌘L)" : "显示歌词 (⌘L)")
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { Double(model.volume) }, set: { model.volume = Float($0) })
    }

    private var rateBinding: Binding<Float> {
        Binding(get: { model.playbackRate }, set: { model.playbackRate = $0 })
    }

    private func rateLabel(_ rate: Double) -> String {
        String(format: "%g×", rate)
    }
}
