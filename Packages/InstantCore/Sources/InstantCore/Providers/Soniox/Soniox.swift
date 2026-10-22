import Foundation

/// Soniox real-time recognition (stt-rt-v5), translating as it recognizes.
///
/// Soniox decides where a translated segment ends: after the original words of a segment are
/// final, their translation arrives, all in one reply (measured: 79 of 79 segments, ~0.7s after
/// the speech). Each such segment becomes one final event with its translation.
struct Soniox: CloudService {
    let engine = SpeechEngine.soniox
    let translates = true
    let apiKey: String
    let language: String
    let target: String
    /// Soniox translates to Chinese in Simplified characters; convert for a Traditional target.
    let toTraditional: Bool

    init(_ options: ProviderOptions) {
        apiKey = options.apiKey
        language = options.sourceCode
        target = options.target.languageCode?.identifier ?? "zh"
        toTraditional = target == "zh" && options.target.maximalIdentifier.contains("Hant")
    }

    func request() -> URLRequest {
        var request = URLRequest(url: URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    var config: JSONValue? {
        [
            "model": "stt-rt-v5",
            "audio_format": "pcm_s16le",
            "sample_rate": .number(Cloud.sampleRate),
            "num_channels": 1,
            "language_hints": [.string(language)],
            // Marks pauses with an "<end>" token.
            "enable_endpoint_detection": true,
            "translation": ["type": "one_way", "target_language": .string(target)],
        ]
    }

    func audio(_ audio: Data) -> URLSessionWebSocketTask.Message { .data(audio) }

    func end(_ remaining: Data) -> [URLSessionWebSocketTask.Message] {
        // An empty message ends the audio.
        (remaining.isEmpty ? [] : [.data(remaining)]) + [.string("")]
    }

    func parser(offset: Double) -> SonioxParser {
        SonioxParser(offset: offset, toTraditional: toTraditional)
    }
}

/// Soniox replies carry new final tokens and the current non-final ones. Final original words are
/// held (shown as in-progress text) until their translation arrives.
struct SonioxParser: CloudParser {
    /// Session time where this connection's audio starts; Soniox times count from there.
    let offset: Double
    let toTraditional: Bool
    private var finals: [Token] = []
    private var partial: [Token] = []

    init(offset: Double, toTraditional: Bool) {
        self.offset = offset
        self.toTraditional = toTraditional
    }

    mutating func parse(_ json: JSONValue, fed: Double, ended: Bool) throws -> (events: [TranscriptEvent], done: Bool) {
        if let code = json["error_code"]?.int {
            throw CloudError.service(.soniox, code: "\(code)", message: json["error_message"]?.string ?? "")
        }
        var events: [TranscriptEvent] = []
        var translation = ""
        partial = []
        for item in json["tokens"]?.array ?? [] {
            guard let text = item["text"]?.string, text != "<end>" else { continue }
            // Translated text has no times; it belongs to the original words held so far.
            if item["translation_status"]?.string == "translation" {
                translation += text
                continue
            }
            let token = Token(text, start: offset + (item["start_ms"]?.double ?? 0) / 1000,
                              end: offset + (item["end_ms"]?.double ?? 0) / 1000)
            if item["is_final"] == .bool(true) {
                finals.append(token)
            } else {
                partial.append(token)
            }
        }
        if !translation.isEmpty { flush(translation: translation, into: &events) }
        let done = json["finished"] == .bool(true)
        if !finals.isEmpty || !partial.isEmpty { events.append(.volatile(finals + partial)) }
        return (events, done)
    }

    /// Words heard but not translated (the connection dropped, or the service ended without
    /// translating them): shown untranslated.
    mutating func interrupted() -> [TranscriptEvent] {
        finals += partial
        partial = []
        var events: [TranscriptEvent] = []
        flush(translation: "", into: &events)
        return events
    }

    private mutating func flush(translation: String, into events: inout [TranscriptEvent]) {
        guard !finals.isEmpty else { return }
        var text = translation.trimmingCharacters(in: .whitespaces)
        if toTraditional { text = text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text }
        events.append(.final(finals, translation: text))
        finals = []
    }
}
