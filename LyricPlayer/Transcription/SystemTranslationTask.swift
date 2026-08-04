import SwiftUI
import Translation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct SystemTranslationRequest: Equatable, Sendable {
    enum Strategy: Equatable, Sendable {
        case balanced
        case highFidelity
        case lowLatency
    }

    let id: UUID
    let sourceIdentifier: String
    let targetIdentifier: String
    let items: [TranslationItem]
    let strategy: Strategy
}

enum SystemTranslationOutcome: Sendable {
    case completed([UUID: String])
    case unsupported(String)
    case failed(String)
}

extension View {
    @ViewBuilder
    func systemTranslationTask(
        _ request: SystemTranslationRequest?,
        onTranslation: @escaping @MainActor @Sendable (UUID, UUID, String?) -> Void,
        onFinish: @escaping @MainActor @Sendable (UUID, SystemTranslationOutcome) -> Void
    ) -> some View {
        if #available(macOS 15.0, *) {
            modifier(SystemTranslationTaskModifier(request: request,
                                                   onTranslation: onTranslation,
                                                   onFinish: onFinish))
        } else {
            self
        }
    }
}

@available(macOS 15.0, *)
private struct SystemTranslationTaskModifier: ViewModifier {
    @State private var configuration: TranslationSession.Configuration?
    let request: SystemTranslationRequest?
    let onTranslation: @MainActor @Sendable (UUID, UUID, String?) -> Void
    let onFinish: @MainActor @Sendable (UUID, SystemTranslationOutcome) -> Void

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                guard let request else { return }
                do {
                    let translated = try await BilingualTranslator.translate(
                        request.items,
                        using: session
                    ) { id, text in
                        onTranslation(request.id, id, text)
                    }
                    try Task.checkCancellation()
                    onFinish(request.id, .completed(translated))
                } catch is CancellationError {
                    // 新请求会立即接手
                } catch let error as BilingualTranslationError {
                    onFinish(request.id, .unsupported(error.localizedDescription))
                } catch {
                    onFinish(request.id, .failed(error.localizedDescription))
                }
            }
            .task(id: request?.id) {
                await MainActor.run { updateConfiguration() }
            }
    }

    @MainActor
    private func updateConfiguration() {
        guard let request else {
            configuration = nil
            return
        }

        let source = Locale.Language(identifier: request.sourceIdentifier)
        let target = Locale.Language(identifier: request.targetIdentifier)
        let next: TranslationSession.Configuration
        if #available(macOS 26.4, *) {
            switch request.strategy {
            case .highFidelity:
                #if canImport(FoundationModels)
                if SystemLanguageModel.default.isAvailable {
                    next = TranslationSession.Configuration(source: source, target: target,
                                                            preferredStrategy: .highFidelity)
                } else {
                    next = TranslationSession.Configuration(source: source, target: target)
                }
                #else
                next = TranslationSession.Configuration(source: source, target: target)
                #endif
            case .lowLatency:
                next = TranslationSession.Configuration(source: source, target: target,
                                                        preferredStrategy: .lowLatency)
            case .balanced:
                next = TranslationSession.Configuration(source: source, target: target)
            }
        } else {
            next = TranslationSession.Configuration(source: source, target: target)
        }

        if configuration?.source != source || configuration?.target != target {
            configuration = next
        } else {
            configuration?.invalidate()
        }
    }
}
