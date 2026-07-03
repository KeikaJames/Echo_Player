import SwiftUI

/// Apple Music 风格的流动歌词：当前行高亮放大、逐词点亮、
/// 自动居中滚动；用户手动滚动时暂停跟随，稍后自动恢复。
struct LyricsView: View {
    @Environment(PlayerModel.self) private var model
    @State private var autoScroll = true
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        Group {
            if model.lyricLines.isEmpty {
                placeholder
            } else {
                lyricsScroll
            }
        }
        .padding(.trailing, 8)
    }

    // MARK: - 歌词滚动区

    private var lyricsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    // 顶部留白，让第一行也能滚到视线高度
                    Color.clear.frame(height: 180)

                    ForEach(Array(model.lyricLines.enumerated()), id: \.element.id) { index, line in
                        LyricLineRow(line: line, index: index)
                            .id(line.id)
                    }

                    Color.clear.frame(height: 260)
                }
                .padding(.horizontal, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollPhaseChange { _, newPhase in
                switch newPhase {
                case .interacting, .tracking, .decelerating:
                    suspendAutoScroll()
                case .idle:
                    scheduleAutoScrollResume()
                default:
                    break
                }
            }
            .onChange(of: model.currentLineIndex) { _, newIndex in
                scrollToCurrent(newIndex, proxy: proxy, animated: true)
            }
            .onChange(of: model.currentTrackID) { _, _ in
                autoScroll = true
                scrollToCurrent(model.currentLineIndex, proxy: proxy, animated: false)
            }
            .onAppear {
                scrollToCurrent(model.currentLineIndex, proxy: proxy, animated: false)
            }
            .overlay(alignment: .bottomTrailing) {
                if !autoScroll {
                    resumePill {
                        autoScroll = true
                        scrollToCurrent(model.currentLineIndex, proxy: proxy, animated: true)
                    }
                }
            }
        }
    }

    private func scrollToCurrent(_ index: Int?, proxy: ScrollViewProxy, animated: Bool) {
        guard autoScroll, let index, model.lyricLines.indices.contains(index) else { return }
        let id = model.lyricLines[index].id
        let anchor = UnitPoint(x: 0, y: 0.33)
        if animated {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    private func suspendAutoScroll() {
        resumeTask?.cancel()
        if autoScroll { autoScroll = false }
    }

    private func scheduleAutoScrollResume() {
        guard !autoScroll else { return }
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            autoScroll = true
        }
    }

    private func resumePill(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("回到当前歌词", systemImage: "arrow.down.to.line")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(20)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - 占位状态

    @ViewBuilder
    private var placeholder: some View {
        switch model.lyricsStatus {
        case .recognizing(let fraction, let message):
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(message ?? "正在识别歌词…")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                if let fraction, fraction > 0 {
                    Text("\(Int(fraction * 100))%")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.primary.opacity(0.55))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView {
                Label("无法识别歌词", systemImage: "waveform.slash")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { model.startLyricsPipeline(forceRecognize: true) }
            }

        default:
            VStack(spacing: 10) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.primary.opacity(0.3))
                Text("此曲目暂无歌词")
                    .foregroundStyle(.primary.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 单行歌词

private struct LyricLineRow: View {
    @Environment(PlayerModel.self) private var model
    let line: LyricLine
    let index: Int
    @State private var isHovered = false

    private var isCurrent: Bool { index == model.currentLineIndex }

    var body: some View {
        Button {
            model.seek(to: line.start)
            model.resume()
        } label: {
            Group {
                if isCurrent && line.hasWordTiming {
                    KaraokeLineText(line: line)
                } else {
                    Text(line.text)
                        .foregroundStyle(isCurrent ? Color.primary : Color.primary.opacity(0.35))
                }
            }
            .font(.system(size: isCurrent ? 28 : 24, weight: .bold, design: .rounded))
            .multilineTextAlignment(.leading)
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.primary.opacity(isHovered ? 0.06 : 0))
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .scaleEffect(isCurrent ? 1.0 : 0.94, anchor: .leading)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isCurrent)
        .accessibilityLabel(line.text)
        .help("点按跳转到 \(TimeFormatter.string(from: line.start))")
    }
}

/// 当前行的卡拉 OK 式逐词点亮。
/// 用 TimelineView 独立驱动刷新，避免整个歌词列表跟着播放时间高频重绘。
private struct KaraokeLineText: View {
    @Environment(PlayerModel.self) private var model
    let line: LyricLine

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !model.isPlaying)) { _ in
            Text(attributedText(at: model.livePlaybackTime()))
        }
    }

    private func attributedText(at time: Double) -> AttributedString {
        var result = AttributedString()
        for (i, word) in line.words.enumerated() {
            var piece = AttributedString(word.text)
            // 连续插值：每个字在自己的时间窗内从暗到亮平滑过渡
            let progress = (time + 0.05 - word.start) / max(word.duration, 0.15)
            let fraction = max(0, min(1, progress))
            piece.foregroundColor = .primary.opacity(0.35 + 0.65 * fraction)
            result += piece
            // 与 LyricComposer.join 相同的空格规则
            if i + 1 < line.words.count,
               let a = word.text.last, let b = line.words[i + 1].text.first,
               !(a.isCJK || b.isCJK),
               !",.!?;:)]}%，。！？；：）】".contains(b),
               !"([{（【".contains(a) {
                result += AttributedString(" ")
            }
        }
        return result
    }
}
