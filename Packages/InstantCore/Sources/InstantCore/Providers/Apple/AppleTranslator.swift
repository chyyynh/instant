import Foundation
@preconcurrency import Translation

/// Apple's on-device Translation framework. Fast and offline; translates each line in isolation.
@MainActor
public final class AppleTranslator: Translator {
    private let session: TranslationSession

    /// Requires the language pair to be installed; see `AppleTranslator.status(from:to:)`.
    /// Live captions ask for `.lowLatency` (macOS/iOS 26.4+); the default may favor quality.
    public init(source: Locale.Language, target: Locale.Language) {
        if #available(macOS 26.4, iOS 26.4, *) {
            let defaultStrategy = TranslationSession(installedSource: source, target: target).preferredStrategy
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
            Trace.shared.event("mt.start", [
                "engine": "apple",
                "default_strategy": Self.name(defaultStrategy),
                "strategy": Self.name(session.preferredStrategy),
            ])
        } else {
            session = TranslationSession(installedSource: source, target: target)
            Trace.shared.event("mt.start", ["engine": "apple", "strategy": "unavailable"])
        }
    }

    @available(macOS 26.4, iOS 26.4, *)
    private static func name(_ strategy: TranslationSession.Strategy) -> String {
        strategy == .lowLatency ? "lowLatency" : strategy == .highFidelity ? "highFidelity" : "other"
    }

    nonisolated public static func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    nonisolated public static func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    public func translate(_ text: String, context: [TranslatedLine]) async throws -> String {
        try await session.translate(text).targetText
    }
}
