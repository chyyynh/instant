@preconcurrency import AVFoundation
import Foundation

/// Streams live audio to a cloud recognizer (Soniox or ElevenLabs) over a WebSocket and turns its
/// replies into the same volatile / final events as `LiveTranscriber`, so the rest of the pipeline
/// (segmentation, translation, captions) doesn't change.
///
/// Audio goes out as 16 kHz mono 16-bit PCM in ~100ms chunks. Token times are seconds of audio
/// since the stream began, the session's time base.
@MainActor
public final class CloudTranscriber: SpeechRecognizer {
    public let engine: SpeechEngine
    public let level = LevelMeter()
    /// Speakers as the service labeled them (Soniox with speakers on); nil otherwise.
    public let speakers: TokenSpeakers?
    private let apiKey: String
    private let language: String
    private var socket: URLSessionWebSocketTask?
    private var feedTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    nonisolated static let sampleRate = 16_000.0
    /// Bytes per chunk sent: 100ms of 16-bit samples.
    nonisolated static let chunkBytes = 3_200

    public init(engine: SpeechEngine, apiKey: String, locale: Locale, diarize: Bool) {
        self.engine = engine
        self.apiKey = apiKey
        language = locale.language.languageCode?.identifier ?? "ja"
        speakers = engine.diarizes && diarize ? TokenSpeakers() : nil
    }

    public func start(audio: AsyncStream<AudioChunk>) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        let socket = URLSession.shared.webSocketTask(with: try request())
        self.socket = socket
        socket.resume()
        if engine == .soniox {
            var config: JSONValue = [
                "model": "stt-rt-v5",
                "audio_format": "pcm_s16le",
                "sample_rate": .number(Self.sampleRate),
                "num_channels": 1,
                "language_hints": [.string(language)],
                // Marks pauses with an "<end>" token, where a final event is cut.
                "enable_endpoint_detection": true,
            ]
            if speakers != nil { config["enable_speaker_diarization"] = true }
            try await socket.send(.string(String(decoding: try JSONEncoder().encode(config), as: UTF8.self)))
        }
        Trace.shared.event("asr.start", ["engine": engine.rawValue, "language": language, "speakers": speakers != nil])

        let fed = AudioClock()
        let ended = AudioEnded()
        let (level, engine, speakers) = (level, engine, speakers)
        feedTask = Task.detached(priority: .userInitiated) {
            await Self.feed(audio, to: socket, engine: engine, fed: fed, level: level, ended: ended)
        }
        let (events, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        receiveTask = Task.detached {
            await Self.receive(from: socket, engine: engine, fed: fed, speakers: speakers, ended: ended, into: continuation)
        }
        return events
    }

    public func stop() async {
        await feedTask?.value
        await receiveTask?.value
        socket = nil
    }

    public func cancel() async {
        feedTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func request() throws -> URLRequest {
        switch engine {
        case .soniox:
            var request = URLRequest(url: URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            return request
        case .elevenLabs:
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
        case .apple:
            throw CloudTranscriberError.notCloud
        }
    }

    // MARK: - Audio out

    private nonisolated static func feed(_ audio: AsyncStream<AudioChunk>, to socket: URLSessionWebSocketTask, engine: SpeechEngine,
                                         fed: AudioClock, level: LevelMeter, ended: AudioEnded) async {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        let converter = BufferConverter(outputFormat: format)
        var pending = Data()
        do {
            for await chunk in audio {
                guard let buffer = converter.convert(chunk.buffer), let samples = buffer.int16ChannelData else { continue }
                level.update(buffer.peakLevel)
                pending.append(Data(bytes: samples[0], count: Int(buffer.frameLength) * 2))
                _ = fed.add(Double(buffer.frameLength) / sampleRate)
                if pending.count >= chunkBytes {
                    try await socket.send(message(pending, engine: engine, commit: false))
                    pending = Data()
                }
            }
            Trace.shared.event("audio.end", ["audio": fed.value.rounded(toPlaces: 2)])
            ended.set()
            // Ask for the last words, then give the service a few seconds to send them.
            switch engine {
            case .soniox:
                if !pending.isEmpty { try await socket.send(.data(pending)) }
                try await socket.send(.string("")) // end of audio
            case .elevenLabs:
                // The commit has to ride on an audio chunk; 100ms of silence if nothing's left.
                try await socket.send(message(pending.isEmpty ? Data(count: chunkBytes) : pending, engine: engine, commit: true))
            case .apple:
                break
            }
            try await Task.sleep(for: .seconds(5))
        } catch {
            if !(error is CancellationError) { Trace.shared.event("asr.error", ["error": "\(error)", "stage": "send"]) }
        }
        ended.set()
        socket.cancel(with: .normalClosure, reason: nil)
    }

    private nonisolated static func message(_ audio: Data, engine: SpeechEngine, commit: Bool) throws -> URLSessionWebSocketTask.Message {
        guard engine == .elevenLabs else { return .data(audio) }
        let json: JSONValue = [
            "message_type": "input_audio_chunk",
            "audio_base_64": .string(audio.base64EncodedString()),
            "commit": .bool(commit),
            "sample_rate": .number(sampleRate),
        ]
        return .string(String(decoding: try JSONEncoder().encode(json), as: UTF8.self))
    }

    // MARK: - Results in

    private nonisolated static func receive(from socket: URLSessionWebSocketTask, engine: SpeechEngine, fed: AudioClock,
                                            speakers: TokenSpeakers?, ended: AudioEnded,
                                            into continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation) async {
        var soniox = SonioxParser(speakers: speakers)
        var elevenLabs = ElevenLabsParser()
        do {
            while !Task.isCancelled {
                let data: Data
                switch try await socket.receive() {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                let json = try JSONDecoder().decode(JSONValue.self, from: data)
                let reply: (events: [TranscriptEvent], done: Bool)
                switch engine {
                case .soniox: reply = try soniox.parse(json)
                case .elevenLabs:
                    let (events, committed) = try elevenLabs.parse(json, fed: fed.value)
                    reply = (events, committed && ended.value)
                case .apple: reply = ([], true)
                }
                for event in reply.events {
                    let tokens: [Token]
                    let kind: String
                    switch event {
                    case .volatile(let t): (tokens, kind) = (t, "volatile")
                    case .final(let t): (tokens, kind) = (t, "final")
                    }
                    Trace.shared.event("asr.result", [
                        "kind": kind,
                        "text": tokens.map(\.text).joined(),
                        "runs": tokens.count,
                        "start": (tokens.first?.start ?? 0).rounded(toPlaces: 2),
                        "end": (tokens.last?.end ?? 0).rounded(toPlaces: 2),
                        "lag": (fed.value - (tokens.last?.end ?? fed.value)).rounded(toPlaces: 2),
                    ])
                    continuation.yield(event)
                }
                if reply.done { break }
            }
            socket.cancel(with: .normalClosure, reason: nil)
            continuation.finish()
        } catch {
            // The socket closing after the audio ended (and the wait for last words ran out) is
            // the normal end, not a failure.
            if ended.value || Task.isCancelled {
                continuation.finish()
                return
            }
            let status = (socket.response as? HTTPURLResponse)?.statusCode
            Trace.shared.event("asr.error", ["error": "\(error)", "status": status ?? -1])
            if let status, status != 101 {
                continuation.finish(throwing: CloudTranscriberError.http(engine, status))
            } else {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Soniox replies carry new final tokens and the current non-final ones. Finals are held until a
/// pause ("<end>") or the end of a sentence, then sent as one final event, like Apple's results.
struct SonioxParser {
    let speakers: TokenSpeakers?
    private var finals: [Token] = []

    init(speakers: TokenSpeakers?) {
        self.speakers = speakers
    }

    mutating func parse(_ json: JSONValue) throws -> (events: [TranscriptEvent], done: Bool) {
        if let code = json["error_code"]?.int {
            throw CloudTranscriberError.service(.soniox, code: "\(code)", message: json["error_message"]?.string ?? "")
        }
        var events: [TranscriptEvent] = []
        var partial: [Token] = []
        for item in json["tokens"]?.array ?? [] {
            // Translations (not requested) have no times; only the spoken words matter here.
            guard item["translation_status"]?.string != "translation", let text = item["text"]?.string else { continue }
            let token = Token(text, start: (item["start_ms"]?.double ?? 0) / 1000, end: (item["end_ms"]?.double ?? 0) / 1000)
            guard item["is_final"] == .bool(true) else {
                if text != "<end>" { partial.append(token) }
                continue
            }
            if text == "<end>" {
                flush(into: &events)
                continue
            }
            finals.append(token)
            if let label = item["speaker"]?.string, let number = Int(label) {
                speakers?.add(start: token.start, end: token.end, speaker: number - 1)
            }
            if let last = text.last, "。？！?!".contains(last) { flush(into: &events) }
        }
        if let processed = json["final_audio_proc_ms"]?.double { speakers?.cover(until: processed / 1000) }
        let done = json["finished"] == .bool(true)
        if done { flush(into: &events) }
        if !finals.isEmpty || !partial.isEmpty { events.append(.volatile(finals + partial)) }
        return (events, done)
    }

    private mutating func flush(into events: inout [TranscriptEvent]) {
        guard !finals.isEmpty else { return }
        events.append(.final(finals))
        finals = []
    }
}

/// ElevenLabs sends the words since the last commit as plain text (estimated times), and each
/// commit with word timestamps.
struct ElevenLabsParser {
    private var estimator = VolatileTimeEstimator()
    private var committedEnd = 0.0

    /// Events for the message, and whether it was a commit.
    mutating func parse(_ json: JSONValue, fed: Double) throws -> (events: [TranscriptEvent], committed: Bool) {
        switch json["message_type"]?.string {
        case "partial_transcript":
            guard let text = json["text"]?.string, !text.isEmpty else { return ([], false) }
            return ([.volatile(estimator.tokens(for: text, start: committedEnd, end: max(fed, committedEnd)))], false)
        case "committed_transcript_with_timestamps":
            var tokens = (json["words"]?.array ?? []).compactMap { word -> Token? in
                guard word["type"]?.string != "spacing", let text = word["text"]?.string, !text.isEmpty else { return nil }
                return Token(text, start: word["start"]?.double ?? committedEnd, end: word["end"]?.double ?? committedEnd)
            }
            if tokens.isEmpty, let text = json["text"]?.string, !text.isEmpty {
                tokens = estimator.tokens(for: text, start: committedEnd, end: max(fed, committedEnd))
            }
            committedEnd = tokens.last?.end ?? committedEnd
            estimator.reset()
            return (tokens.isEmpty ? [] : [.final(tokens)], true)
        case let type? where json["error"] != nil:
            throw CloudTranscriberError.service(.elevenLabs, code: type, message: json["error"]?.string ?? "")
        default:
            // session_started, committed_transcript (sent alongside the timestamped one), warnings.
            return ([], false)
        }
    }
}

/// Speaker labels a cloud recognizer put on its words, kept by time so captions are attributed
/// the same way as with the on-device diarizer.
public final class TokenSpeakers: SpeakerSource, @unchecked Sendable {
    private let lock = NSLock()
    // Guarded by `lock`, in time order.
    private var spans: [(start: Double, end: Double, speaker: Int)] = []
    private var covered = 0.0

    func add(start: Double, end: Double, speaker: Int) {
        lock.withLock {
            spans.append((start, end, speaker))
            covered = max(covered, end)
        }
    }

    func cover(until seconds: Double) {
        lock.withLock { covered = max(covered, seconds) }
    }

    public var coveredUntil: Double { lock.withLock { covered } }

    public var speakingNow: [Int] { [] }

    public func attribute(start: Double, end: Double) -> SpeakerDiarizer.Attribution {
        lock.withLock {
            var totals: [Int: Double] = [:]
            for span in spans.reversed() {
                if span.end < start - 5 { break }
                let overlap = min(span.end, end) - max(span.start, start)
                // Zero-length words inside the line still count.
                if overlap >= 0 { totals[span.speaker, default: 0] += max(overlap, 0.01) }
            }
            guard let best = totals.max(by: { $0.value < $1.value }) else { return .init(speaker: nil, share: 0) }
            return .init(speaker: best.key, share: best.value / totals.values.reduce(0, +))
        }
    }
}

/// Set once the audio stream has ended; read by the receive side to tell a normal close from a failure.
final class AudioEnded: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false

    var value: Bool { lock.withLock { ended } }

    func set() { lock.withLock { ended = true } }
}

public enum CloudTranscriberError: LocalizedError {
    case notCloud
    case http(SpeechEngine, Int)
    case service(SpeechEngine, code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .notCloud:
            "這不是雲端辨識引擎。"
        case .http(let engine, 401), .http(let engine, 403):
            "\(engine.name) 的 API key 無效，請到設定重新輸入。"
        case .http(let engine, 402):
            "\(engine.name) 的額度用完了。"
        case .http(let engine, 429):
            "\(engine.name) 的請求太頻繁或超過用量上限，稍後再試。"
        case .http(let engine, let status):
            "無法連線到 \(engine.name)（\(status)）。"
        case .service(let engine, let code, let message):
            switch code {
            case "401", "auth_error": "\(engine.name) 的 API key 無效，請到設定重新輸入。"
            case "402", "quota_exceeded": "\(engine.name) 的額度用完了。"
            default: "\(engine.name) 辨識錯誤：\(message.isEmpty ? code : message)"
            }
        }
    }
}
