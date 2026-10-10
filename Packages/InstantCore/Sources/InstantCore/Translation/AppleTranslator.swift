import Foundation
@preconcurrency import Translation

/// Apple's on-device Translation framework. Fast and offline; translates each line in isolation.
@MainActor
public final class AppleTranslator: Translator {
    private let session: TranslationSession

    /// Requires the language pair to be installed; see `AppleTranslator.status(from:to:)`.
    public init(source: Locale.Language, target: Locale.Language) {
        session = TranslationSession(installedSource: source, target: target)
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
