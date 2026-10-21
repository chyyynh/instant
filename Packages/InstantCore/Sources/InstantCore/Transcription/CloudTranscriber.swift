@preconcurrency import AVFoundation
import Foundation

/// Streams live audio to a cloud recognizer (Soniox or ElevenLabs) over a WebSocket and turns its
/// replies into the same volatile / final events as `LiveTranscriber`, so the rest of the pipeline
/// (segmentation, translation, captions) doesn't change.
///
/// Audio goes out as 16 kHz mono 16-bit PCM in ~100ms chunks. Token times are seconds of audio
/// since the stream began, the session's time base.
///
/// If the connection drops mid-session (seen: "connection reset by peer" 44 minutes in), it
/// reconnects. Audio captured while disconnected is held and sent first on the new connection,
/// and that connection's times are shifted onto the session's time base.
@MainActor
public final class CloudTranscriber: SpeechRecognizer {
    public let engine: SpeechEngine
    public let level = LevelMeter()
    /// Speakers as the service labeled them (Soniox with speakers on); nil otherwise.
    public let speakers: TokenSpeakers?
    private let endpoint: CloudEndpoint
    private var uplink: Uplink?
    private var feedTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    nonisolated static let sampleRate = 16_000.0
    /// Bytes per chunk sent: 100ms of 16-bit samples.
    nonisolated static let chunkBytes = 3_200
    /// Consecutive failed reconnects before giving up; waits 1, 2, 4, 8, 8s between them.
    nonisolated static let maxReconnects = 5

    public init(engine: SpeechEngine, apiKey: String, locale: Locale, diarize: Bool) {
        self.engine = engine
        speakers = engine.diarizes && diarize ? TokenSpeakers() : nil
        endpoint = CloudEndpoint(engine: engine, apiKey: apiKey, language: locale.language.languageCode?.identifier ?? "ja",
                                 diarize: speakers != nil)
    }

    public func start(audio: AsyncStream<AudioChunk>) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        let socket = try await endpoint.connect()
        let uplink = Uplink()
        _ = uplink.attach(socket)
        self.uplink = uplink
        Trace.shared.event("asr.start", ["engine": engine.rawValue, "language": endpoint.language, "speakers": speakers != nil])

        let fed = AudioClock()
        let ended = AudioEnded()
        let (level, engine, speakers, endpoint) = (level, engine, speakers, endpoint)
        feedTask = Task.detached(priority: .userInitiated) {
            await Self.feed(audio, to: uplink, engine: engine, fed: fed, level: level, ended: ended)
        }
        let (events, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        receiveTask = Task.detached {
            await Self.receive(from: socket, endpoint: endpoint, uplink: uplink, fed: fed, speakers: speakers,
                               ended: ended, into: continuation)
        }
        return events
    }

    public func stop() async {
        await feedTask?.value
        await receiveTask?.value
        uplink = nil
    }

    public func cancel() async {
        feedTask?.cancel()
        receiveTask?.cancel()
        uplink?.close()
        uplink = nil
    }

    // MARK: - Audio out

    private nonisolated static func feed(_ audio: AsyncStream<AudioChunk>, to uplink: Uplink, engine: SpeechEngine,
                                         fed: AudioClock, level: LevelMeter, ended: AudioEnded) async {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        let converter = BufferConverter(outputFormat: format)
        var pending = Data()
        var pendingStart = 0.0
        for await chunk in audio {
            guard let buffer = converter.convert(chunk.buffer), let samples = buffer.int16ChannelData else { continue }
            level.update(buffer.peakLevel)
            if pending.isEmpty { pendingStart = fed.value }
            pending.append(Data(bytes: samples[0], count: Int(buffer.frameLength) * 2))
            _ = fed.add(Double(buffer.frameLength) / sampleRate)
            if pending.count >= chunkBytes {
                await send(pending, start: pendingStart, via: uplink, engine: engine)
                pending = Data()
            }
        }
        Trace.shared.event("audio.end", ["audio": fed.value.rounded(toPlaces: 2)])
        ended.set()
        // Ask for the last words, then give the service a few seconds to send them.
        do {
            if let socket = uplink.current {
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
            }
            try await Task.sleep(for: .seconds(5))
        } catch {
            if !(error is CancellationError) { Trace.shared.event("asr.error", ["error": "\(error)", "stage": "send"]) }
        }
        uplink.close()
    }

    /// Sends audio (plus whatever was held while disconnected) in chunk-sized messages. While
    /// disconnected, or if the send fails, the audio is held for the next connection.
    private nonisolated static func send(_ audio: Data, start: Double, via uplink: Uplink, engine: SpeechEngine) async {
        guard let (socket, data, dataStart) = uplink.route(audio, start: start) else { return }
        var offset = 0
        while offset < data.count {
            let piece = data.subdata(in: offset..<min(offset + chunkBytes, data.count))
            do {
                try await socket.send(message(piece, engine: engine, commit: false))
            } catch {
                uplink.lost(socket, unsent: data.subdata(in: offset..<data.count),
                            start: dataStart + Double(offset) / 2 / sampleRate)
                return
            }
            offset += piece.count
        }
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

    private nonisolated static func receive(from first: URLSessionWebSocketTask, endpoint: CloudEndpoint, uplink: Uplink,
                                            fed: AudioClock, speakers: TokenSpeakers?, ended: AudioEnded,
                                            into continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation) async {
        let engine = endpoint.engine
        var socket = first
        var soniox = SonioxParser(speakers: speakers, offset: 0)
        var elevenLabs = ElevenLabsParser(offset: 0)
        var failures = 0
        while true {
            do {
                while !Task.isCancelled {
                    let data: Data
                    switch try await socket.receive() {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    failures = 0
                    let json = try JSONDecoder().decode(JSONValue.self, from: data)
                    let reply: (events: [TranscriptEvent], done: Bool)
                    switch engine {
                    case .soniox: reply = try soniox.parse(json)
                    case .elevenLabs:
                        let (events, committed) = try elevenLabs.parse(json, fed: fed.value)
                        reply = (events, committed && ended.value)
                    case .apple: reply = ([], true)
                    }
                    for event in reply.events { yield(event, fed: fed, into: continuation) }
                    if reply.done { break }
                }
                socket.cancel(with: .normalClosure, reason: nil)
                continuation.finish()
                return
            } catch {
                // The socket closing after the audio ended (and the wait for last words ran out) is
                // the normal end, not a failure.
                if ended.value || Task.isCancelled {
                    continuation.finish()
                    return
                }
                let status = (socket.response as? HTTPURLResponse)?.statusCode
                Trace.shared.event("asr.error", ["error": "\(error)", "status": status ?? -1])
                // Keep what was heard before the drop: the new connection starts from scratch.
                let interrupted = engine == .soniox ? soniox.interrupted() : elevenLabs.interrupted()
                for event in interrupted { yield(event, fed: fed, into: continuation) }
                uplink.detach(socket)
                socket.cancel(with: .goingAway, reason: nil)
                guard isTransient(error, status: status), failures < maxReconnects else {
                    continuation.finish(throwing: failure(error, status: status, engine: engine))
                    return
                }
            }
            // Reconnect, retrying with backoff while the connection can't be re-established.
            while true {
                failures += 1
                let wait = min(1 << (failures - 1), 8)
                Trace.shared.event("asr.reconnect", ["attempt": failures, "wait": wait, "audio": fed.value.rounded(toPlaces: 2)])
                try? await Task.sleep(for: .seconds(wait))
                if ended.value || Task.isCancelled {
                    continuation.finish()
                    return
                }
                do {
                    socket = try await endpoint.connect()
                    let offset = uplink.attach(socket)
                    soniox = SonioxParser(speakers: speakers, offset: offset)
                    elevenLabs = ElevenLabsParser(offset: offset)
                    Trace.shared.event("asr.reconnected", ["attempt": failures, "offset": offset.rounded(toPlaces: 2),
                                                           "backlog": (fed.value - offset).rounded(toPlaces: 2)])
                    break
                } catch {
                    Trace.shared.event("asr.error", ["error": "\(error)", "stage": "reconnect"])
                    guard isTransient(error, status: nil), failures < maxReconnects else {
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
        }
    }

    private nonisolated static func yield(_ event: TranscriptEvent, fed: AudioClock,
                                          into continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation) {
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

    /// Network drops and server-side hiccups are worth reconnecting for; a bad key or used-up
    /// quota isn't.
    nonisolated static func isTransient(_ error: Error, status: Int?) -> Bool {
        if let status, status != 101 { return status == 408 || status >= 500 }
        if case CloudTranscriberError.http(_, let status) = error { return status == 408 || status >= 500 }
        if case CloudTranscriberError.service(_, let code, _) = error {
            return ["408", "500", "502", "503", "504"].contains(code)
        }
        return true
    }

    private nonisolated static func failure(_ error: Error, status: Int?, engine: SpeechEngine) -> Error {
        if let status, status != 101 { return CloudTranscriberError.http(engine, status) }
        return error
    }
}

/// Where and how to open a recognition WebSocket.
struct CloudEndpoint: Sendable {
    let engine: SpeechEngine
    let apiKey: String
    let language: String
    let diarize: Bool

    /// Opens a socket and sends the session config, ready for audio.
    func connect() async throws -> URLSessionWebSocketTask {
        let socket = URLSession.shared.webSocketTask(with: try request())
        socket.resume()
        if engine == .soniox {
            var config: JSONValue = [
                "model": "stt-rt-v5",
                "audio_format": "pcm_s16le",
                "sample_rate": .number(CloudTranscriber.sampleRate),
                "num_channels": 1,
                "language_hints": [.string(language)],
                // Marks pauses with an "<end>" token, where a final event is cut.
                "enable_endpoint_detection": true,
            ]
            if diarize { config["enable_speaker_diarization"] = true }
            do {
                try await socket.send(.string(String(decoding: try JSONEncoder().encode(config), as: UTF8.self)))
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
                if let status = (socket.response as? HTTPURLResponse)?.statusCode, status != 101 {
                    throw CloudTranscriberError.http(engine, status)
                }
                throw error
            }
        }
        return socket
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
}

/// The socket audio currently goes to. While there is none (between a drop and the reconnect),
/// audio is held — up to `maxBacklog` of the most recent — and sent first on the next socket.
final class Uplink: @unchecked Sendable {
    private let lock = NSLock()
    // Guarded by `lock`.
    private var socket: URLSessionWebSocketTask?
    private var backlog = Data()
    /// Session time where `backlog` starts.
    private var backlogStart = 0.0
    /// Session time where the audio routed so far ends.
    private var routedEnd = 0.0

    /// 60s of 16 kHz 16-bit audio.
    static let maxBacklog = 60 * 32_000

    var current: URLSessionWebSocketTask? { lock.withLock { socket } }

    /// The socket to send on and what to send (held audio first), or nil if the audio was held.
    func route(_ audio: Data, start: Double) -> (URLSessionWebSocketTask, Data, Double)? {
        lock.withLock {
            routedEnd = start + Double(audio.count) / 2 / CloudTranscriber.sampleRate
            if backlog.isEmpty { backlogStart = start }
            backlog.append(audio)
            if backlog.count > Self.maxBacklog {
                let excess = backlog.count - Self.maxBacklog
                backlog.removeFirst(excess)
                backlogStart += Double(excess) / 2 / CloudTranscriber.sampleRate
            }
            guard let socket else { return nil }
            defer { backlog = Data() }
            return (socket, backlog, backlogStart)
        }
    }

    /// A send on `socket` failed: hold the unsent audio and stop using that socket.
    func lost(_ socket: URLSessionWebSocketTask, unsent: Data, start: Double) {
        lock.withLock {
            guard self.socket === socket else { return }
            self.socket = nil
            backlog = unsent + backlog
            backlogStart = start
        }
    }

    /// The connection on `socket` dropped; hold audio until the next one.
    func detach(_ socket: URLSessionWebSocketTask) {
        lock.withLock {
            guard self.socket === socket else { return }
            self.socket = nil
        }
    }

    /// Starts sending on `socket`. Returns the session time its first audio starts at, which is
    /// where that connection's times begin.
    func attach(_ socket: URLSessionWebSocketTask) -> Double {
        lock.withLock {
            self.socket = socket
            return backlog.isEmpty ? routedEnd : backlogStart
        }
    }

    func close() {
        lock.withLock {
            socket?.cancel(with: .normalClosure, reason: nil)
            socket = nil
        }
    }
}

/// Soniox replies carry new final tokens and the current non-final ones. Finals are held until a
/// pause ("<end>") or the end of a sentence, then sent as one final event, like Apple's results.
struct SonioxParser {
    let speakers: TokenSpeakers?
    /// Session time where this connection's audio starts; Soniox times count from there.
    let offset: Double
    private var finals: [Token] = []
    private var partial: [Token] = []

    init(speakers: TokenSpeakers?, offset: Double) {
        self.speakers = speakers
        self.offset = offset
    }

    mutating func parse(_ json: JSONValue) throws -> (events: [TranscriptEvent], done: Bool) {
        if let code = json["error_code"]?.int {
            throw CloudTranscriberError.service(.soniox, code: "\(code)", message: json["error_message"]?.string ?? "")
        }
        var events: [TranscriptEvent] = []
        partial = []
        for item in json["tokens"]?.array ?? [] {
            // Translations (not requested) have no times; only the spoken words matter here.
            guard item["translation_status"]?.string != "translation", let text = item["text"]?.string else { continue }
            let token = Token(text, start: offset + (item["start_ms"]?.double ?? 0) / 1000,
                              end: offset + (item["end_ms"]?.double ?? 0) / 1000)
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
        if let processed = json["final_audio_proc_ms"]?.double { speakers?.cover(until: offset + processed / 1000) }
        let done = json["finished"] == .bool(true)
        if done { flush(into: &events) }
        if !finals.isEmpty || !partial.isEmpty { events.append(.volatile(finals + partial)) }
        return (events, done)
    }

    /// The connection dropped: everything heard so far, including words not yet final, as a final event.
    mutating func interrupted() -> [TranscriptEvent] {
        finals += partial
        partial = []
        var events: [TranscriptEvent] = []
        flush(into: &events)
        return events
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
    /// Session time where this connection's audio starts; ElevenLabs times count from there.
    private let offset: Double
    private var committedEnd: Double
    private var partial: [Token] = []

    init(offset: Double) {
        self.offset = offset
        committedEnd = offset
    }

    /// Events for the message, and whether it was a commit.
    mutating func parse(_ json: JSONValue, fed: Double) throws -> (events: [TranscriptEvent], committed: Bool) {
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
            return (tokens.isEmpty ? [] : [.final(tokens)], true)
        case let type? where json["error"] != nil:
            throw CloudTranscriberError.service(.elevenLabs, code: type, message: json["error"]?.string ?? "")
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
