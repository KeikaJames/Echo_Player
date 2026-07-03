import SwiftUI

struct ContentView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

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
        }
        .dropDestination(for: URL.self) { urls, _ in
            let audio = urls.filter { url in
                Track.isMediaFile(url) || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            guard !audio.isEmpty else { return false }
            model.open(urls: audio)
            return true
        } isTargeted: { isDropTargeted = $0 }
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
            if model.currentTrack?.isVideo != true {
                TransportBar()   // 音频用自绘玻璃控制条；视频用系统原生悬浮 HUD
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
}

