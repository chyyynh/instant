import Foundation

/// A previously translated line, available as context for the next one.
public struct TranslatedLine: Sendable, Equatable {
    public let source: String
    public let translation: String

    public init(source: String, translation: String) {
        self.source = source
        self.translation = translation
    }
}

@MainActor
public protocol Translator: AnyObject {
    /// Translates `text`. Backends that understand context (LLMs) use `context` to resolve
    /// omitted subjects and references; sentence-level engines ignore it.
    func translate(_ text: String, context: [TranslatedLine]) async throws -> String
}
