@preconcurrency import AVFoundation
import Foundation

/// One cloud speech service's side of the conversation: how to connect, how audio is framed, and
/// how its replies become events. `CloudProvider` does the rest the same way for every service.
protocol CloudService: Sendable {
    associatedtype Parser: CloudParser
    var engine: SpeechEngine { get }
    /// Final events carry translations.
    var translates: Bool { get }
    func request() -> URLRequest
    /// Sent first on every connection, before any audio.
    var config: JSONValue? { get }
    /// One chunk of audio (16 kHz mono 16-bit PCM).
    func audio(_ audio: Data) throws -> URLSessionWebSocketTask.Message
    /// What to send once the audio has ended, with `remaining` audio not yet sent, so the service
    /// sends its last words.
    func end(_ remaining: Data) throws -> [URLSessionWebSocketTask.Message]
    /// A parser for a new connection whose times start at session time `offset`.
    func parser(offset: Double) -> Parser
}

/// Turns one connection's replies into events.
protocol CloudParser {
    /// Events for one reply, and whether the service is done (no more replies will come).
    /// `fed` is how much audio has been captured; `ended`, whether the audio has ended.
    mutating func parse(_ json: JSONValue, fed: Double, ended: Bool) throws -> (events: [TranscriptEvent], done: Bool)
    /// The connection dropped: what was heard so far, as final events, since the next connection
    /// starts from scratch.
    mutating func interrupted() -> [TranscriptEvent]
}

/// Streams live audio to a cloud service over a WebSocket and reads back events.
///
/// Audio goes out as 16 kHz mono 16-bit PCM in ~100ms chunks. Token times are seconds of audio
/// since the stream began, the session's time base.
///
/// If the connection drops mid-session (seen: "connection reset by peer" 44 minutes in), it
/// reconnects. Audio captured while disconnected is held and sent first on the new connection,
/// and that connection's times are shifted onto the session's time base.
@MainActor
final class CloudProvider<Service: CloudService>: SpeechProvider {
    let service: Service
    let level = LevelMeter()
    var translates: Bool { service.translates }
    private var uplink: Uplink?
    private var feedTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    init(_ service: Service) {
        self.service = service
    }

    func start(audio: AsyncStream<AudioChunk>) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        let socket = try await connect(service)
        let uplink = Uplink()
        _ = uplink.attach(socket)
        self.uplink = uplink
        Trace.shared.event("asr.start", ["engine": service.engine.rawValue, "translates": service.translates])

        let fed = AudioClock()
        let ended = AudioEnded()
        let (level, service) = (level, service)
        feedTask = Task.detached(priority: .userInitiated) {
            await feed(audio, to: uplink, service: service, fed: fed, level: level, ended: ended)
        }
        let (events, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        receiveTask = Task.detached {
            await receive(from: socket, service: service, uplink: uplink, fed: fed, ended: ended, into: continuation)
        }
        return events
    }

    func stop() async {
        await feedTask?.value
        await receiveTask?.value
        uplink = nil
    }

    func cancel() async {
        feedTask?.cancel()
        receiveTask?.cancel()
        uplink?.close()
        uplink = nil
    }
}

enum Cloud {
    static let sampleRate = 16_000.0
    /// Bytes per chunk sent: 100ms of 16-bit samples.
    static let chunkBytes = 3_200
    /// Consecutive failed reconnects before giving up; waits 1, 2, 4, 8, 8s between them.
    static let maxReconnects = 5
}

/// Opens a socket and sends the session config, ready for audio.
private func connect(_ service: some CloudService) async throws -> URLSessionWebSocketTask {
    let socket = URLSession.shared.webSocketTask(with: service.request())
    socket.resume()
    guard let config = service.config else { return socket }
    do {
        try await socket.send(.string(String(decoding: try JSONEncoder().encode(config), as: UTF8.self)))
    } catch {
        socket.cancel(with: .goingAway, reason: nil)
        if let status = (socket.response as? HTTPURLResponse)?.statusCode, status != 101 {
            throw CloudError.http(service.engine, status)
        }
        throw error
    }
    return socket
}

// MARK: - Audio out

private func feed(_ audio: AsyncStream<AudioChunk>, to uplink: Uplink, service: some CloudService,
                  fed: AudioClock, level: LevelMeter, ended: AudioEnded) async {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Cloud.sampleRate, channels: 1, interleaved: true)!
    let converter = BufferConverter(outputFormat: format)
    var pending = Data()
    var pendingStart = 0.0
    for await chunk in audio {
        guard let buffer = converter.convert(chunk.buffer), let samples = buffer.int16ChannelData else { continue }
        level.update(buffer.peakLevel)
        if pending.isEmpty { pendingStart = fed.value }
        pending.append(Data(bytes: samples[0], count: Int(buffer.frameLength) * 2))
        _ = fed.add(Double(buffer.frameLength) / Cloud.sampleRate)
        if pending.count >= Cloud.chunkBytes {
            await send(pending, start: pendingStart, via: uplink, service: service)
            pending = Data()
        }
    }
    Trace.shared.event("audio.end", ["audio": fed.value.rounded(toPlaces: 2)])
    ended.set()
    // Ask for the last words, then give the service a few seconds to send them.
    do {
        if let socket = uplink.current {
            for message in try service.end(pending) { try await socket.send(message) }
        }
        try await Task.sleep(for: .seconds(5))
    } catch {
        if !(error is CancellationError) { Trace.shared.event("asr.error", ["error": "\(error)", "stage": "send"]) }
    }
    uplink.close()
}

/// Sends audio (plus whatever was held while disconnected) in chunk-sized messages. While
/// disconnected, or if the send fails, the audio is held for the next connection.
private func send(_ audio: Data, start: Double, via uplink: Uplink, service: some CloudService) async {
    guard let (socket, data, dataStart) = uplink.route(audio, start: start) else { return }
    var offset = 0
    while offset < data.count {
        let piece = data.subdata(in: offset..<min(offset + Cloud.chunkBytes, data.count))
        do {
            try await socket.send(service.audio(piece))
        } catch {
            uplink.lost(socket, unsent: data.subdata(in: offset..<data.count),
                        start: dataStart + Double(offset) / 2 / Cloud.sampleRate)
            return
        }
        offset += piece.count
    }
}

// MARK: - Results in

private func receive<Service: CloudService>(from first: URLSessionWebSocketTask, service: Service, uplink: Uplink,
                                            fed: AudioClock, ended: AudioEnded,
                                            into continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation) async {
    var socket = first
    var parser = service.parser(offset: 0)
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
                let (events, done) = try parser.parse(json, fed: fed.value, ended: ended.value)
                for event in events { yield(event, fed: fed, into: continuation) }
                if done { break }
            }
            socket.cancel(with: .normalClosure, reason: nil)
            continuation.finish()
            return
        } catch {
            // The socket closing after the audio ended (and the wait for last words ran out) is
            // the normal end, not a failure.
            if ended.value || Task.isCancelled {
                for event in parser.interrupted() { yield(event, fed: fed, into: continuation) }
                continuation.finish()
                return
            }
            let status = (socket.response as? HTTPURLResponse)?.statusCode
            Trace.shared.event("asr.error", ["error": "\(error)", "status": status ?? -1])
            // Keep what was heard before the drop: the new connection starts from scratch.
            for event in parser.interrupted() { yield(event, fed: fed, into: continuation) }
            uplink.detach(socket)
            socket.cancel(with: .goingAway, reason: nil)
            guard isTransient(error, status: status), failures < Cloud.maxReconnects else {
                continuation.finish(throwing: failure(error, status: status, engine: service.engine))
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
                socket = try await connect(service)
                let offset = uplink.attach(socket)
                parser = service.parser(offset: offset)
                Trace.shared.event("asr.reconnected", ["attempt": failures, "offset": offset.rounded(toPlaces: 2),
                                                       "backlog": (fed.value - offset).rounded(toPlaces: 2)])
                break
            } catch {
                Trace.shared.event("asr.error", ["error": "\(error)", "stage": "reconnect"])
                guard isTransient(error, status: nil), failures < Cloud.maxReconnects else {
                    continuation.finish(throwing: error)
                    return
                }
            }
        }
    }
}

private func yield(_ event: TranscriptEvent, fed: AudioClock,
                   into continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation) {
    var fields: [String: any Sendable]
    let tokens: [Token]
    switch event {
    case .volatile(let t):
        tokens = t
        fields = ["kind": "volatile"]
    case .final(let t, let translation):
        tokens = t
        fields = ["kind": "final"]
        if let translation { fields["translation"] = translation }
    }
    fields["text"] = tokens.map(\.text).joined()
    fields["runs"] = tokens.count
    fields["start"] = (tokens.first?.start ?? 0).rounded(toPlaces: 2)
    fields["end"] = (tokens.last?.end ?? 0).rounded(toPlaces: 2)
    fields["lag"] = (fed.value - (tokens.last?.end ?? fed.value)).rounded(toPlaces: 2)
    Trace.shared.event("asr.result", fields)
    continuation.yield(event)
}

/// Network drops and server-side hiccups are worth reconnecting for; a bad key or used-up
/// quota isn't.
func isTransient(_ error: Error, status: Int?) -> Bool {
    if let status, status != 101 { return status == 408 || status >= 500 }
    if case CloudError.http(_, let status) = error { return status == 408 || status >= 500 }
    if case CloudError.service(_, let code, _) = error {
        return ["408", "500", "502", "503", "504"].contains(code)
    }
    return true
}

private func failure(_ error: Error, status: Int?, engine: SpeechEngine) -> Error {
    if let status, status != 101 { return CloudError.http(engine, status) }
    return error
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
            routedEnd = start + Double(audio.count) / 2 / Cloud.sampleRate
            if backlog.isEmpty { backlogStart = start }
            backlog.append(audio)
            if backlog.count > Self.maxBacklog {
                let excess = backlog.count - Self.maxBacklog
                backlog.removeFirst(excess)
                backlogStart += Double(excess) / 2 / Cloud.sampleRate
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

/// Set once the audio stream has ended; read by the receive side to tell a normal close from a failure.
final class AudioEnded: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false

    var value: Bool { lock.withLock { ended } }

    func set() { lock.withLock { ended = true } }
}

public enum CloudError: LocalizedError {
    case http(SpeechEngine, Int)
    case service(SpeechEngine, code: String, message: String)

    public var errorDescription: String? {
        switch self {
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
