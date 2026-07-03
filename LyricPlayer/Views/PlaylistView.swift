import SwiftUI

/// 侧边栏播放列表：单击选中、双击播放、拖拽排序、右键菜单、⌫ 删除。
struct PlaylistView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.playlist.isEmpty {
                ContentUnavailableView {
                    Label("播放列表为空", systemImage: "music.note.list")
                } description: {
                    Text("将音频文件拖入窗口，\n或按 ⌘O 打开。")
                }
            } else {
                List(selection: $model.sidebarSelection) {
                    ForEach(model.playlist) { track in
                        PlaylistRow(track: track)
                            .tag(track.id)
                    }
                    .onMove { source, destination in
                        model.move(from: source, to: destination)
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand {
                    if let selection = model.sidebarSelection {
                        model.remove(trackIDs: [selection])
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
        .navigationTitle("播放列表")
    }

    private var footer: some View {
        HStack {
            Button {
                model.presentOpenPanel()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("添加音频 (⌘O)")

            Spacer()

            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var summaryText: String {
        let count = model.playlist.count
        guard count > 0 else { return "" }
        let total = model.playlist.reduce(0) { $0 + $1.duration }
        return "\(count) 首 · \(TimeFormatter.string(from: total))"
    }
}

private struct PlaylistRow: View {
    @Environment(PlayerModel.self) private var model
    let track: Track

    private var isCurrent: Bool { model.currentTrackID == track.id }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if isCurrent {
                    Image(systemName: model.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .fontWeight(isCurrent ? .semibold : .regular)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if track.isVideo {
                Image(systemName: "film")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(track.duration > 0 ? TimeFormatter.string(from: track.duration) : "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.play(trackID: track.id)
        }
        .contextMenu {
            Button("播放") { model.play(trackID: track.id) }
            Button("在访达中显示") { model.revealInFinder(trackID: track.id) }
            Divider()
            Button("从列表中移除", role: .destructive) { model.remove(trackIDs: [track.id]) }
        }
        .help(track.url.path)
    }
}
