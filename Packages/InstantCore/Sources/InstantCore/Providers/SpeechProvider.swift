import Foundation

/// Who turns speech into text (and, for some, translates it): Apple's on-device recognizer, or a
/// cloud service the user has a key for. Cloud engines upload the audio.
public enum SpeechEngine: String, CaseIterable, Identifiable, Sendable {
    case apple
    case soniox
    case elevenLabs

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .apple: "Apple"
        case .soniox: "Soniox"
        case .elevenLabs: "ElevenLabs"
        }
    }

    public var isCloud: Bool { self != .apple }

    /// The service translates as it recognizes, so lines aren't translated on device.
    public var translates: Bool { self == .soniox }

    /// A provider for one session. `options.apiKey` must be set for cloud engines.
    @MainActor
    public func makeProvider(_ options: ProviderOptions) -> SpeechProvider {
        switch self {
        case .apple: AppleProvider(locale: options.source)
        case .soniox: CloudProvider(Soniox(options))
        case .elevenLabs: CloudProvider(ElevenLabs(options))
        }
    }
}

/// What a provider is asked to do: recognize `source`, and translate into `target` if it translates.
public struct ProviderOptions: Sendable {
    public var source: Locale
    public var target: Locale.Language
    public var apiKey: String

    public init(source: Locale, target: Locale.Language, apiKey: String = "") {
        self.source = source
        self.target = target
        self.apiKey = apiKey
    }

    /// The source language's code ("ja"), which cloud services take.
    var sourceCode: String { source.language.languageCode?.identifier ?? "ja" }
}

public enum TranscriptEvent: Sendable, Equatable {
    /// In-progress speech since the last final. Each volatile replaces the previous one.
    case volatile([Token])
    /// Speech the provider has committed to. Subsequent volatiles start after it. Providers that
    /// translate send it with its translation, as one line.
    case final([Token], translation: String? = nil)
}

/// One speech service, used the same way whichever it is: `start` it on the audio and read events
/// until the stream ends; `stop` waits for the last words, `cancel` drops them.
@MainActor
public protocol SpeechProvider: AnyObject {
    /// Recent input level, for a UI meter.
    var level: LevelMeter { get }
    /// Final events carry translations. Otherwise the session splits and translates lines itself.
    var translates: Bool { get }
    func start(audio: AsyncStream<AudioChunk>) async throws -> AsyncThrowingStream<TranscriptEvent, Error>
    /// Waits for already-captured audio to be recognized. Call after the audio stream has ended.
    func stop() async
    func cancel() async
}
