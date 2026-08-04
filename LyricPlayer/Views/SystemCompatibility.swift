import SwiftUI
import AppKit

struct AdaptiveGlassContainer<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func adaptiveGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func adaptiveGlassCapsule(interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                glassEffect(.regular.interactive(), in: Capsule())
            } else {
                glassEffect(.regular, in: Capsule())
            }
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
        }
    }

    @ViewBuilder
    func hidingWindowToolbarBackground() -> some View {
        if #available(macOS 15.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }

    @ViewBuilder
    func trackingScrollPhase(onInteracting: @escaping () -> Void,
                             onIdle: @escaping () -> Void) -> some View {
        if #available(macOS 15.0, *) {
            onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting, .tracking, .decelerating:
                    onInteracting()
                case .idle:
                    onIdle()
                default:
                    break
                }
            }
        } else {
            background {
                LegacyScrollPhaseObserver(onInteracting: onInteracting, onIdle: onIdle)
            }
        }
    }
}

private struct LegacyScrollPhaseObserver: NSViewRepresentable {
    let onInteracting: () -> Void
    let onIdle: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInteracting: onInteracting, onIdle: onIdle)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        attach(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onInteracting = onInteracting
        context.coordinator.onIdle = onIdle
        attach(view, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func attach(_ view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.attach(to: Self.findScrollView(from: view))
        }
    }

    private static func findScrollView(from view: NSView) -> NSScrollView? {
        if let scrollView = view.enclosingScrollView { return scrollView }
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = firstScrollView(in: current) { return scrollView }
            ancestor = current.superview
        }
        return nil
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) { return scrollView }
        }
        return nil
    }

    final class Coordinator {
        var onInteracting: () -> Void
        var onIdle: () -> Void
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []

        init(onInteracting: @escaping () -> Void, onIdle: @escaping () -> Void) {
            self.onInteracting = onInteracting
            self.onIdle = onIdle
        }

        func attach(to scrollView: NSScrollView?) {
            guard self.scrollView !== scrollView else { return }
            detach()
            guard let scrollView else { return }
            self.scrollView = scrollView
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                                   object: scrollView, queue: .main) { [weak self] _ in
                    self?.onInteracting()
                },
                center.addObserver(forName: NSScrollView.didLiveScrollNotification,
                                   object: scrollView, queue: .main) { [weak self] _ in
                    self?.onInteracting()
                },
                center.addObserver(forName: NSScrollView.didEndLiveScrollNotification,
                                   object: scrollView, queue: .main) { [weak self] _ in
                    self?.onIdle()
                },
            ]
        }

        func detach() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            scrollView = nil
        }

        deinit {
            detach()
        }
    }
}
