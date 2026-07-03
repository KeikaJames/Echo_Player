import SwiftUI
import AppKit

/// 实时会议转写窗口：深色玻璃浮窗（系统"实时字幕"的质感）。
/// 说话人头像 + 分组气泡（连续同人发言合并）、呼吸录音点 + 时长计时、
/// Liquid Glass 控制按钮；文本与说话人分离全部本地完成。
struct LiveCaptionsView: View {
    /// 共享会话：关窗只停止聆听，记录保留，重开窗口可继续查看/导出。
    private var session = LiveCaptionSession.shared

    /// 说话人配色（按出现顺序循环使用）。
    static let speakerColors: [Color] = [
        Color(red: 0.40, green: 0.66, blue: 1.00),   // 蓝
        Color(red: 1.00, green: 0.64, blue: 0.38),   // 橙
        Color(red: 0.56, green: 0.86, blue: 0.52),   // 绿
        Color(red: 0.88, green: 0.55, blue: 0.95),   // 紫
        Color(red: 1.00, green: 0.48, blue: 0.52),   // 红
        Color(red: 0.48, green: 0.86, blue: 0.90),   // 青
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            transcript
            controlBar
        }
        .frame(minWidth: 540, minHeight: 300)
        .background(.ultraThinMaterial)            // 整窗玻璃
        .background(CaptionsWindowStyler())        // 透明标题栏，玻璃直通到顶
        .environment(\.colorScheme, .dark)
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    // MARK: - 顶部：状态与计时

    private var header: some View {
        HStack(spacing: 10) {
            statusBadge
            Spacer()
            if session.speakerCount > 1 {
                Label("\(session.speakerCount) 人对话", systemImage: "person.2.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)      // 让出透明标题栏（红绿灯）区域
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch session.state {
        case .idle:
            Label("已停止", systemImage: "mic.slash")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在启动…").font(.callout).foregroundStyle(.secondary)
            }

        case .listening:
            HStack(spacing: 8) {
                PulsingRecordDot()
                Text("正在聆听")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                if let start = session.startedAt {
                    ElapsedTimeText(since: start)
                }
            }

        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("重试") { session.start() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - 转写区：说话人分组气泡

    /// 连续同一说话人的句子合并为一组（会议纪要的自然形态）。
    private var groupedEntries: [(id: UUID, speaker: Int?, date: Date, texts: [CaptionEntry])] {
        var groups: [(id: UUID, speaker: Int?, date: Date, texts: [CaptionEntry])] = []
        for entry in session.entries {
            if var last = groups.last, last.speaker == entry.speaker, entry.speaker != nil {
                last.texts.append(entry)
                groups[groups.count - 1] = last
            } else {
                groups.append((id: entry.id, speaker: entry.speaker, date: entry.date, texts: [entry]))
            }
        }
        return groups
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groupedEntries, id: \.id) { group in
                        speakerGroup(group)
                            .id(group.id)
                    }

                    if !session.statusText.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(session.statusText)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.top, 2)
                    }

                    if !session.volatileText.isEmpty {
                        volatileRow
                    } else if session.state == .listening && session.entries.isEmpty && session.statusText.isEmpty {
                        emptyHint
                    }

                    Color.clear.frame(height: 6).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.entries.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.volatileText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func speakerGroup(_ group: (id: UUID, speaker: Int?, date: Date, texts: [CaptionEntry])) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SpeakerAvatar(speaker: group.speaker)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(group.speaker.map { "说话人 \($0)" } ?? "语音")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(group.speaker.map {
                            Self.speakerColors[($0 - 1) % Self.speakerColors.count]
                        } ?? Color.secondary)
                    Text(group.date, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.quaternary)
                }
                ForEach(group.texts) { entry in
                    Text(entry.text)
                        .font(.system(size: 16))
                        .foregroundStyle(.primary.opacity(0.92))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var volatileRow: some View {
        HStack(alignment: .top, spacing: 10) {
            SpeakerAvatar(speaker: nil, live: true)
            Text(session.volatileText)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .padding(.top, 4)
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("正在聆听，开始说话即可转写")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - 底部：Liquid Glass 控制

    private var controlBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    session.isListening ? session.stop() : session.start()
                } label: {
                    Label(session.isListening ? "停止" : "继续",
                          systemImage: session.isListening ? "stop.fill" : "mic.fill")
                        .frame(minWidth: 56)
                }
                .buttonStyle(.glassProminent)
                .tint(session.isListening ? .red : .accentColor)
                .help(session.isListening ? "停止聆听" : "继续聆听")

                Spacer()

                Button { session.copyAll() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.glass)
                .help("拷贝全部（含说话人）")
                .disabled(session.entries.isEmpty)

                Button { session.saveToFile() } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.glass)
                .help("保存会议记录（.txt）…")
                .disabled(session.entries.isEmpty)

                Button { session.saveRecording() } label: {
                    Image(systemName: "waveform.circle")
                }
                .buttonStyle(.glass)
                .help("导出录音（.wav）…")
                .disabled(session.entries.isEmpty && !session.isListening)

                Button { session.clear() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.glass)
                .help("清空记录")
                .disabled(session.entries.isEmpty && session.volatileText.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - 组件

/// 说话人头像：配色圆 + 编号；未标注/实时中为灰底波形。
private struct SpeakerAvatar: View {
    let speaker: Int?
    var live = false

    var body: some View {
        ZStack {
            Circle()
                .fill(background)
                .frame(width: 28, height: 28)
            if let speaker {
                Text("\(speaker)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: live ? "waveform" : "person.wave.2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: live)
            }
        }
    }

    private var background: AnyShapeStyle {
        if let speaker {
            let color = LiveCaptionsView.speakerColors[(speaker - 1) % LiveCaptionsView.speakerColors.count]
            return AnyShapeStyle(LinearGradient(colors: [color, color.opacity(0.65)],
                                                startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(Color.white.opacity(0.16))
    }
}

/// 呼吸的红色录音点。
private struct PulsingRecordDot: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * 2.4)
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .shadow(color: .red.opacity(0.5 * pulse), radius: 4 + 3 * pulse)
                .opacity(0.7 + 0.3 * pulse)
        }
    }
}

/// mm:ss 计时。
private struct ElapsedTimeText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// 把宿主窗口调成"深色玻璃浮窗"：非不透明 + 深色外观 + 透明标题栏。
/// 用 viewDidMoveToWindow 钩子保证时机（异步抓 window 不可靠）。
private struct CaptionsWindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowTunerView { WindowTunerView() }
    func updateNSView(_ nsView: WindowTunerView, context: Context) {}

    final class WindowTunerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // SwiftUI 在场景配置阶段会覆盖部分窗口属性，延迟两拍重放确保生效
            DispatchQueue.main.async { [weak self] in self?.apply() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let window else { return }
            // 应用级外观被强制为浅色（多窗口 bug 的修复），转写窗口单独上深色
            window.appearance = NSAppearance(named: .darkAqua)
            // 窗口透明化：材质才能透出桌面，呈现玻璃浮窗质感
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        }
    }
}
