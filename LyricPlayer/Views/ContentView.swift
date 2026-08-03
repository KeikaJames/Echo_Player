import SwiftUI
import Translation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ContentView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(TranslationSettings.self) private var translationSettings
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var lyricsTranslationGroups: [TranslationGroup] = []
    @State private var lyricsTranslationWarning: String?

    var body: some View {
        let isVideoMode = model.currentTrack?.isVideo == true
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            PlaylistView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detailPane
        }
        .toolbar { toolbarContent }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .environment(\.colorScheme, isVideoMode ? .dark : .light)   // 视频=沉浸深色，音频=浅色
        .onChange(of: isVideoMode) { _, video in
            withAnimation { columnVisibility = video ? .detailOnly : .automatic }   // 视频自动收起侧栏
            WindowChromeController.shared.setVideoMode(video)
        }
        .onAppear {
            WindowChromeController.shared.setVideoMode(isVideoMode)
            requestTranslation()
        }
        .dropDestination(for: URL.self) { urls, _ in
            let audio = urls.filter { url in
                Track.isMediaFile(url) || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            guard !audio.isEmpty else { return false }
            model.open(urls: audio)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .translationTask(translationConfiguration) { session in
            await translateLyrics(using: session)
        }
        .onChange(of: model.lyricsRevision) { _, _ in requestTranslation() }
        .onChange(of: translationSettings.lyricsEnabled) { _, enabled in
            if enabled {
                requestTranslation()
            } else {
                translationConfiguration = nil
                lyricsTranslationGroups = []
                lyricsTranslationWarning = nil
                model.lyricsTranslationState = .idle
            }
        }
        .onChange(of: translationSettings.targetIdentifier) { _, _ in
            model.clearLyricsTranslation()
            requestTranslation()
        }
        .task { await translationSettings.loadSupportedLanguages() }
    }

    // MARK: - 主区域

    private var detailPane: some View {
        ZStack {
            AuroraBackground()

            if model.currentTrack == nil {
                emptyState
            } else if model.currentTrack?.isVideo == true {
                VideoStage()   // 视频画面 + 底部自动字幕
            } else if model.showLyrics {
                HStack(spacing: 0) {
                    NowPlayingPanel()
                        .frame(width: 312)
                        .frame(maxHeight: .infinity)
                    LyricsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                NowPlayingPanel(large: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 边缘光晕：音乐=彩虹随鼓点，视频=画面边缘氛围色实时渲染
            if model.glowEnabled {
                EdgeGlow(levelProvider: { model.audioLevel() },
                         pulseProvider: { model.audioPulse() },
                         ambientProvider: { model.glowAmbientColors() })
            }

            if isDropTargeted {
                dropOverlay
            }
        }
        .overlay(alignment: .bottom) {
            if model.currentTrack?.isVideo != true || model.usesFFmpegPlayback {
                // 原生视频用 AVKit HUD；KSPlayer 只提供画面，仍需完整走带控制。
                TransportBar()
            }
        }

    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text("拖拽以播放")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.88))
            Text("音频自动识别歌词，视频自动匹配字幕")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("打开文件…") { model.presentOpenPanel() }
                .buttonStyle(.glass)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                Label("松开以添加到播放列表", systemImage: "plus.circle.fill")
                    .font(.title2.bold())
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(14)
            .allowsHitTesting(false)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.presentOpenPanel()
            } label: {
                Label("添加", systemImage: "plus")
            }
            .help("添加音频文件或文件夹 (⌘O)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                openWindow(id: "live-captions")
            } label: {
                Label("实时字幕", systemImage: "waveform.badge.mic")
            }
            .help("打开麦克风实时字幕 (⇧⌘K)")
        }

        ToolbarItem(placement: .primaryAction) {
            moreMenu
        }
    }

    private var moreMenu: some View {
        @Bindable var model = model
        return Menu {
            Toggle("边缘光晕", isOn: $model.glowEnabled)
            Divider()
            Button("重新识别歌词") { model.startLyricsPipeline(forceRecognize: true) }
                .disabled(model.currentTrack == nil)
            Button("导出歌词为 LRC…") { model.exportLRC() }
                .disabled(model.lyricLines.isEmpty)
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
        .help("歌词操作")
    }

    // MARK: - 双语歌词 / 字幕

    private func requestTranslation() {
        guard translationSettings.lyricsEnabled,
              !model.lyricLines.isEmpty,
              case .done = model.lyricsStatus else {
            translationConfiguration = nil
            lyricsTranslationGroups = []
            lyricsTranslationWarning = nil
            return
        }

        let target = translationSettings.targetLanguage
        let items = model.lyricLines.map { TranslationItem(id: $0.id, text: $0.text) }
        let plan = BilingualTranslator.plan(for: items, target: target)
        for id in plan.skippedIDs { model.translatedLyrics[id] = nil }
        lyricsTranslationGroups = plan.groups
        lyricsTranslationWarning = nil
        model.lyricsTranslationTarget = translationSettings.targetIdentifier

        guard let first = lyricsTranslationGroups.first else {
            translationConfiguration = nil
            model.lyricsTranslationState = .done
            return
        }
        model.lyricsTranslationState = .translating
        configureLyricsTranslation(for: first)
    }

    private func translateLyrics(using session: TranslationSession) async {
        guard let group = lyricsTranslationGroups.first else { return }
        let target = translationSettings.targetIdentifier
        let trackID = model.currentTrackID
        let revision = model.lyricsRevision
        let groupID = group.id

        model.lyricsTranslationState = .translating
        do {
            let translated = try await BilingualTranslator.translate(group.items, using: session) { id, text in
                guard model.currentTrackID == trackID,
                      model.lyricsRevision == revision,
                      lyricsTranslationGroups.first?.id == groupID,
                      translationSettings.lyricsEnabled,
                      translationSettings.targetIdentifier == target else { return }
                model.translatedLyrics[id] = text
            }
            try Task.checkCancellation()
            guard model.currentTrackID == trackID,
                  model.lyricsRevision == revision,
                  lyricsTranslationGroups.first?.id == groupID,
                  translationSettings.lyricsEnabled,
                  translationSettings.targetIdentifier == target else { return }
            model.translatedLyrics.merge(translated) { _, new in new }
            model.lyricsTranslationTarget = target
            lyricsTranslationGroups.removeFirst()
            if let next = lyricsTranslationGroups.first {
                configureLyricsTranslation(for: next)
            } else {
                translationConfiguration = nil
                model.lyricsTranslationState = lyricsTranslationWarning.map(BilingualTranslationState.failed) ?? .done
            }
        } catch is CancellationError {
            // 配置变化会取消旧任务，新任务会立即接手
        } catch let error as BilingualTranslationError {
            guard model.currentTrackID == trackID,
                  model.lyricsRevision == revision,
                  lyricsTranslationGroups.first?.id == groupID,
                  translationSettings.targetIdentifier == target else { return }
            for item in group.items { model.translatedLyrics[item.id] = nil }
            lyricsTranslationWarning = error.localizedDescription
            lyricsTranslationGroups.removeFirst()
            if let next = lyricsTranslationGroups.first {
                configureLyricsTranslation(for: next)
            } else {
                translationConfiguration = nil
                model.lyricsTranslationState = .failed(error.localizedDescription)
            }
        } catch {
            guard model.currentTrackID == trackID,
                  model.lyricsRevision == revision,
                  lyricsTranslationGroups.first?.id == groupID,
                  translationSettings.targetIdentifier == target else { return }
            model.lyricsTranslationState = .failed(error.localizedDescription)
        }
    }

    private func configureLyricsTranslation(for group: TranslationGroup) {
        let source = group.sourceLanguage
        let target = translationSettings.targetLanguage
        let configuration: TranslationSession.Configuration
        #if canImport(FoundationModels)
        if #available(macOS 26.4, *), SystemLanguageModel.default.isAvailable {
            configuration = TranslationSession.Configuration(source: source, target: target,
                                                               preferredStrategy: .highFidelity)
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
        #else
        configuration = TranslationSession.Configuration(source: source, target: target)
        #endif

        if translationConfiguration?.source != source || translationConfiguration?.target != target {
            translationConfiguration = configuration
        } else {
            translationConfiguration?.invalidate()
        }
    }
}
