import SwiftUI
import AppKit

/// 实时会议转写窗口：深色玻璃浮窗（系统"实时字幕"的质感）。
/// 说话人头像 + 分组气泡（连续同人发言合并）、呼吸录音点 + 时长计时、
/// Liquid Glass 控制按钮；文本与说话人分离全部本地完成。
struct LiveCaptionsView: View {
    @Environment(TranslationSettings.self) private var translationSettings
    /// 共享会话：关窗只停止聆听，记录保留，重开窗口可继续查看/导出。
    private var session = LiveCaptionSession.shared
    @State private var translationRequest: SystemTranslationRequest?
    @State private var captionTranslationGroup: TranslationGroup?
    @State private var captionTranslationWarning: String?
    @State private var showsSummary = false

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
        .onAppear {
            requestCaptionTranslation()
        }
        .onDisappear {
            translationRequest = nil
            captionTranslationGroup = nil
            session.suspendCaptionTranslation()
            session.stop()
        }
        .systemTranslationTask(translationRequest,
                               onTranslation: applyCaptionTranslation,
                               onFinish: finishCaptionTranslation)
        .onChange(of: session.entries.count) { _, _ in requestCaptionTranslation() }
        .onChange(of: translationSettings.captionsEnabled) { _, enabled in
            if enabled {
                requestCaptionTranslation()
            } else {
                translationRequest = nil
                captionTranslationGroup = nil
                captionTranslationWarning = nil
                session.clearCaptionTranslations()
            }
        }
        .onChange(of: translationSettings.targetIdentifier) { _, _ in
            translationRequest = nil
            captionTranslationGroup = nil
            captionTranslationWarning = nil
            session.clearCaptionTranslations()
            requestCaptionTranslation()
        }
        .task { await translationSettings.loadSupportedLanguages() }
        .sheet(isPresented: $showsSummary) {
            MeetingSummaryView(session: session)
        }
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
                    .adaptiveGlassButtonStyle()
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text)
                            .font(.system(size: 16))
                            .foregroundStyle(.primary.opacity(0.92))
                            .lineSpacing(3)
                        if translationSettings.captionsEnabled,
                           session.captionTranslationTarget == translationSettings.targetIdentifier,
                           let translated = entry.translatedText {
                            Text(translated)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                        }
                    }
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
        AdaptiveGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    session.isListening ? session.stop() : session.start()
                } label: {
                    Label(session.isListening ? "停止" : "继续",
                          systemImage: session.isListening ? "stop.fill" : "mic.fill")
                        .frame(minWidth: 56)
                }
                .adaptiveGlassButtonStyle(prominent: true)
                .tint(session.isListening ? .red : .accentColor)
                .help(session.isListening ? "停止聆听" : "继续聆听")

                Spacer()

                translationMenu

                Button {
                    showsSummary = true
                    if (session.meetingSummary == nil || session.isMeetingSummaryStale),
                       !isGeneratingSummary {
                        session.generateSummary()
                    }
                } label: {
                    Image(systemName: "sparkles")
                }
                .adaptiveGlassButtonStyle()
                .help(summaryButtonHelp)
                .disabled(session.entries.isEmpty)

                Button { session.copyAll() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .adaptiveGlassButtonStyle()
                .help("拷贝全部（含说话人）")
                .disabled(session.entries.isEmpty)

                Button { session.saveToFile() } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .adaptiveGlassButtonStyle()
                .help("保存会议记录（.txt）…")
                .disabled(session.entries.isEmpty)

                Button { session.saveRecording() } label: {
                    Image(systemName: "waveform.circle")
                }
                .adaptiveGlassButtonStyle()
                .help("导出录音（.wav）…")
                .disabled(session.entries.isEmpty && !session.isListening)

                Button { session.clear() } label: {
                    Image(systemName: "trash")
                }
                .adaptiveGlassButtonStyle()
                .help("清空记录")
                .disabled(session.entries.isEmpty && session.volatileText.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var translationMenu: some View {
        @Bindable var settings = translationSettings
        return Menu {
            Toggle("显示双语字幕", isOn: $settings.captionsEnabled)
                .disabled(!settings.systemTranslationAvailable && !settings.captionsEnabled)
            Picker("译为", selection: $settings.targetIdentifier) {
                ForEach(settings.supportedLanguages) { language in
                    Text(language.name).tag(language.id)
                }
            }
            .disabled(!settings.systemTranslationAvailable)
            if !settings.systemTranslationAvailable {
                Divider()
                Text(TranslationSettings.minimumSystemMessage)
            }
            if case .failed(let message) = session.captionTranslationState {
                Divider()
                Text(message)
            }
        } label: {
            if session.captionTranslationState == .translating {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: settings.captionsEnabled ? "character.bubble.fill" : "character.bubble")
            }
        }
        .adaptiveGlassButtonStyle()
        .help(captionTranslationHelp)
    }

    private var captionTranslationHelp: String {
        guard translationSettings.systemTranslationAvailable else {
            return translationSettings.captionsEnabled
                ? "关闭双语字幕"
                : TranslationSettings.minimumSystemMessage
        }
        if case .failed(let message) = session.captionTranslationState { return message }
        return translationSettings.captionsEnabled
            ? "关闭双语字幕（当前译为\(translationSettings.targetName)）"
            : "使用系统翻译显示双语字幕"
    }

    private var isGeneratingSummary: Bool {
        if case .generating = session.meetingSummaryState { return true }
        return false
    }

    private var summaryButtonHelp: String {
        guard session.meetingSummary != nil else { return "生成会议摘要" }
        return session.isMeetingSummaryStale ? "更新会议摘要" : "查看会议摘要"
    }

    // MARK: - 双语字幕

    private func requestCaptionTranslation() {
        guard translationSettings.captionsEnabled, !session.entries.isEmpty else {
            translationRequest = nil
            captionTranslationGroup = nil
            if session.entries.isEmpty { captionTranslationWarning = nil }
            return
        }

        guard translationSettings.systemTranslationAvailable else {
            translationRequest = nil
            captionTranslationGroup = nil
            captionTranslationWarning = TranslationSettings.minimumSystemMessage
            session.captionTranslationState = .failed(TranslationSettings.minimumSystemMessage)
            return
        }

        let targetID = translationSettings.targetIdentifier
        if session.captionTranslationState == .translating,
           session.captionTranslationTarget == targetID { return }

        let target = translationSettings.targetLanguage
        let items = session.captionEntriesNeedingTranslation(target: targetID)
            .map { TranslationItem(id: $0.id, text: $0.text) }
        let speechSource = Locale.Language(identifier: AutoTranscriber.systemLocale().identifier)
        let plan = BilingualTranslator.plan(for: items, target: target, knownSource: speechSource)
        session.beginCaptionTranslation(target: targetID)
        for id in plan.skippedIDs {
            session.applyCaptionTranslation(nil, to: id, target: targetID)
        }

        guard let group = plan.groups.first else {
            translationRequest = nil
            captionTranslationGroup = nil
            if let warning = captionTranslationWarning {
                session.captionTranslationState = .failed(warning)
            } else {
                session.finishCaptionTranslation(target: targetID)
            }
            return
        }
        captionTranslationGroup = group
        translationRequest = SystemTranslationRequest(
            id: group.id,
            sourceIdentifier: group.sourceIdentifier,
            targetIdentifier: targetID,
            items: group.items,
            strategy: .lowLatency
        )
    }

    private func applyCaptionTranslation(requestID: UUID, entryID: UUID, text: String?) {
        guard let request = translationRequest,
              request.id == requestID,
              captionTranslationGroup?.id == requestID,
              translationSettings.captionsEnabled,
              translationSettings.targetIdentifier == request.targetIdentifier else { return }
        session.applyCaptionTranslation(text, to: entryID, target: request.targetIdentifier)
    }

    private func finishCaptionTranslation(requestID: UUID, outcome: SystemTranslationOutcome) {
        guard let group = captionTranslationGroup,
              group.id == requestID,
              let request = translationRequest,
              request.id == requestID,
              translationSettings.targetIdentifier == request.targetIdentifier else { return }

        switch outcome {
        case .completed:
            session.finishCaptionTranslation(target: request.targetIdentifier)
            translationRequest = nil
            captionTranslationGroup = nil
            requestCaptionTranslation()

        case .unsupported(let message):
            for item in group.items {
                session.applyCaptionTranslation(nil, to: item.id, target: request.targetIdentifier)
            }
            captionTranslationWarning = message
            session.finishCaptionTranslation(target: request.targetIdentifier)
            translationRequest = nil
            captionTranslationGroup = nil
            requestCaptionTranslation()

        case .failed(let message):
            translationRequest = nil
            session.captionTranslationState = .failed(message)
        }
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
        private weak var observedWindow: NSWindow?
        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWindowClose()
            apply()
            // SwiftUI 在场景配置阶段会覆盖部分窗口属性，延迟两拍重放确保生效
            DispatchQueue.main.async { [weak self] in self?.apply() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.apply() }
        }

        private func observeWindowClose() {
            guard observedWindow !== window else { return }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
            observedWindow = window
            guard let window else { return }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                LiveCaptionSession.shared.stop()
            }
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
            window.level = .floating
            window.isRestorable = false
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        }

        deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }
    }
}
