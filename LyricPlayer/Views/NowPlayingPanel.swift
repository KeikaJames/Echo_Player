import SwiftUI

/// 左侧（或隐藏歌词时居中）的封面与曲目信息面板。
struct NowPlayingPanel: View {
    @Environment(PlayerModel.self) private var model
    var large = false

    var body: some View {
        VStack(spacing: large ? 28 : 18) {
            Spacer(minLength: 0)

            artworkView
                .frame(width: side, height: side)

            VStack(spacing: 6) {
                Text(model.currentTrack?.title ?? "")
                    .font(large ? .title2.bold() : .headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let artist = model.currentTrack?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(large ? .title3 : .subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, large ? 40 : 24)
        .padding(.vertical, 20)
    }

    private var side: CGFloat { large ? 320 : 240 }

    @ViewBuilder
    private var artworkView: some View {
        if let artwork = model.currentTrack?.artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.primary.opacity(0.05))
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.3, weight: .light))
                        .foregroundStyle(.primary.opacity(0.25))
                }
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        }
    }
}
