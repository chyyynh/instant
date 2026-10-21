import Foundation

/// Who turns speech into text: Apple's on-device recognizer, or a cloud service the user has a
/// key for. Cloud engines upload the audio.
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

    /// The engine labels speakers itself, so the on-device speaker model isn't needed.
    public var diarizes: Bool { self == .soniox }
}

/// Streams recognition of live audio as volatile / final events.
@MainActor
public protocol SpeechRecognizer: AnyObject {
    /// Recent input level, for a UI meter.
    var level: LevelMeter { get }
    func start(audio: AsyncStream<AudioChunk>) async throws -> AsyncThrowingStream<TranscriptEvent, Error>
    /// Waits for already-captured audio to be recognized. Call after the audio stream has ended.
    func stop() async
    func cancel() async
}

extension LiveTranscriber: SpeechRecognizer {}

/// Who spoke when, on the session's time base (seconds of audio since it began).
public protocol SpeakerSource: AnyObject, Sendable {
    /// Audio up to here has been attributed; lines ending later may still get a speaker.
    var coveredUntil: Double { get }
    func attribute(start: Double, end: Double) -> SpeakerDiarizer.Attribution
    /// Slots heard in the latest audio.
    var speakingNow: [Int] { get }
}

extension SpeakerDiarizer: SpeakerSource {}
