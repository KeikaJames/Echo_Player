import SwiftUI

/// Foundation Models 在本机生成的会议摘要。原始转写始终是唯一事实来源。
struct MeetingSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let session: LiveCaptionSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            content
            Divider().opacity(0.25)
            footer
        }
        .frame(width: 640, height: 560)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.yellow)
            Text("会议摘要")
                .font(.title2.bold())
            Spacer()
            if session.isMeetingSummaryStale {
                Label("记录已更新", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        if let summary = session.meetingSummary {
            summaryContent(summary)
        } else {
            switch session.meetingSummaryState {
            case .idle:
                summaryUnavailable("尚未生成摘要")

            case .generating(let message):
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(message)
                        .font(.headline)
                    Text("会议内容只在这台 Mac 上处理")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message):
                ContentUnavailableView {
                    Label("无法生成摘要", systemImage: "sparkles.rectangle.stack")
                } description: {
                    Text(message)
                }

            case .ready:
                summaryUnavailable("摘要结果为空")
            }
        }
    }

    private func summaryContent(_ summary: MeetingSummary) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                summaryStatus

                Text(summary.overview)
                    .font(.system(size: 17, weight: .medium))
                    .lineSpacing(5)
                    .textSelection(.enabled)

                summaryList("要点", systemImage: "list.bullet", items: summary.keyPoints)
                summaryList("决定", systemImage: "checkmark.seal", items: summary.decisions)
                summaryList("待办", systemImage: "checklist", items: summary.actionItems)

                if !summary.chapters.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("章节", systemImage: "text.line.first.and.arrowtriangle.forward")
                        ForEach(Array(summary.chapters.enumerated()), id: \.offset) { _, chapter in
                            HStack(alignment: .top, spacing: 12) {
                                Text(chapter.startTime)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 54, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chapter.title).font(.headline)
                                    Text(chapter.detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineSpacing(3)
                                }
                            }
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var summaryStatus: some View {
        switch session.meetingSummaryState {
        case .generating(let message):
            Label {
                Text(message)
            } icon: {
                ProgressView().controlSize(.small)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)

        case .ready where session.isMeetingSummaryStale:
            Label("会议记录已变化，当前显示的是上一份摘要。", systemImage: "arrow.clockwise")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .idle, .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private func summaryList(_ title: String, systemImage: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle(title, systemImage: systemImage)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 4, height: 4)
                        Text(item)
                            .font(.callout)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.primary.opacity(0.88))
    }

    private func summaryUnavailable(_ message: String) -> some View {
        ContentUnavailableView("会议摘要", systemImage: "sparkles", description: Text(message))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("重新生成") { session.generateSummary() }
                .buttonStyle(.glass)
                .disabled(session.entries.isEmpty || isGenerating)
            Button("拷贝摘要") { session.copySummary() }
                .buttonStyle(.glass)
                .disabled(session.meetingSummary == nil)
            Spacer()
            Button("完成") { dismiss() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var isGenerating: Bool {
        if case .generating = session.meetingSummaryState { return true }
        return false
    }
}
