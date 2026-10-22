import Foundation

/// ElevenLabs real-time recognition (scribe_v2_realtime). Recognition only: lines are translated
/// on device.
struct ElevenLabs: CloudService {
    let engine = SpeechEngine.elevenLabs
    let translates = false
    let apiKey: String
    let language: String

    init(_ options: ProviderOptions) {
        apiKey = options.apiKey
        language = options.sourceCode
    }

    func request() -> URLRequest {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        components.queryItems = [
            .init(name: "model_id", value: "scribe_v2_realtime"),
            .init(name: "language_code", value: language),
            .init(name: "audio_format", value: "pcm_16000"),
            // Commits at pauses, like a recognizer's final results.
            .init(name: "commit_strategy", value: "vad"),
            .init(name: "include_timestamps", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    /// Configured by the URL.
    var config: JSONValue? { nil }

    func audio(_ audio: Data) throws -> URLSessionWebSocketTask.Message {
        try message(audio, commit: false)
    }

    func end(_ remaining: Data) throws -> [URLSessionWebSocketTask.Message] {
        // The commit has to ride on an audio chunk; 100ms of silence if nothing's left.
        [try message(remaining.isEmpty ? Data(count: Cloud.chunkBytes) : remaining, commit: true)]
    }

    private func message(_ audio: Data, commit: Bool) throws -> URLSessionWebSocketTask.Message {
        let json: JSONValue = [
            "message_type": "input_audio_chunk",
            "audio_base_64": .string(audio.base64EncodedString()),
            "commit": .bool(commit),
            "sample_rate": .number(Cloud.sampleRate),
        ]
        return .string(String(decoding: try JSONEncoder().encode(json), as: UTF8.self))
    }

    func parser(offset: Double) -> ElevenLabsParser {
        ElevenLabsParser(offset: offset)
    }
}

/// ElevenLabs sends the words since the last commit as plain text (estimated times), and each
/// commit with word timestamps.
struct ElevenLabsParser: CloudParser {
    private var estimator = VolatileTimeEstimator()
    /// Session time where this connection's audio starts; ElevenLabs times count from there.
    private let offset: Double
    private var committedEnd: Double
    private var partial: [Token] = []

    init(offset: Double) {
        self.offset = offset
        committedEnd = offset
    }

    /// Done at the commit after the audio has ended.
    mutating func parse(_ json: JSONValue, fed: Double, ended: Bool) throws -> (events: [TranscriptEvent], done: Bool) {
        switch json["message_type"]?.string {
        case "partial_transcript":
            guard let text = json["text"]?.string, !text.isEmpty else { return ([], false) }
            partial = estimator.tokens(for: text, start: committedEnd, end: max(fed, committedEnd))
            return ([.volatile(partial)], false)
        case "committed_transcript_with_timestamps":
            var tokens = (json["words"]?.array ?? []).compactMap { word -> Token? in
                guard word["type"]?.string != "spacing", let text = word["text"]?.string, !text.isEmpty else { return nil }
                return Token(text, start: word["start"]?.double.map { offset + $0 } ?? committedEnd,
                             end: word["end"]?.double.map { offset + $0 } ?? committedEnd)
            }
            if tokens.isEmpty, let text = json["text"]?.string, !text.isEmpty {
                tokens = estimator.tokens(for: text, start: committedEnd, end: max(fed, committedEnd))
            }
            committedEnd = tokens.last?.end ?? committedEnd
            estimator.reset()
            partial = []
            return (tokens.isEmpty ? [] : [.final(tokens)], ended)
        case let type? where json["error"] != nil:
            throw CloudError.service(.elevenLabs, code: type, message: json["error"]?.string ?? "")
        default:
            // session_started, committed_transcript (sent alongside the timestamped one), warnings.
            return ([], false)
        }
    }

    /// The connection dropped: the uncommitted words, as a final event.
    mutating func interrupted() -> [TranscriptEvent] {
        defer { partial = [] }
        return partial.isEmpty ? [] : [.final(partial)]
    }
}
