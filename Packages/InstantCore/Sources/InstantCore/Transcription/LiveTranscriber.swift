@preconcurrency import AVFoundation
import Speech

public enum TranscriptEvent: Sendable, Equatable {
    /// In-progress speech since the last final. Each volatile replaces the previous one.
    case volatile([Token])
    /// Speech the recognizer has committed to. Subsequent volatiles start after it.
    case final([Token])
}

/// Streams on-device speech recognition through `SpeechAnalyzer`.
@MainActor
public final class LiveTranscriber {
    public let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var feedTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    /// Recent input level, for a UI meter.
    public let level = LevelMeter()

    public init(locale: Locale) {
        self.locale = locale
    }

    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// Starts recognition on `audio`. Downloads the speech model first if needed.
    public func start(audio: AsyncStream<AudioChunk>) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.unsupportedLocale(locale)
        }
        // fastResults: without it, volatiles stall until a pause in speech
        // (measured: first Japanese text after ~12s of continuous speech vs ~1s with it).
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            // Per-token time ranges let the segmenter find pauses when punctuation is missing.
            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError.noAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)

        let fed = AudioClock()
        let level = level
        Trace.shared.event("asr.start", ["locale": supported.identifier(.bcp47), "format": "\(analyzerFormat.sampleRate)Hz/\(analyzerFormat.channelCount)ch"])
        feedTask = Task.detached(priority: .userInitiated) {
            let converter = BufferConverter(outputFormat: analyzerFormat)
            var nextReport = 1.0
            var peak: Float = 0
            for await chunk in audio {
                if let buffer = converter.convert(chunk.buffer) {
                    inputContinuation.yield(AnalyzerInput(buffer: buffer))
                    let bufferPeak = buffer.peakLevel
                    peak = max(peak, bufferPeak)
                    level.update(bufferPeak)
                    let total = fed.add(Double(buffer.frameLength) / analyzerFormat.sampleRate)
                    if total >= nextReport {
                        // Peak level over the last second in dBFS: near -100 means silence.
                        let dB = 20 * log10(max(Double(peak), 1e-5))
                        Trace.shared.event("audio.fed", ["audio": total.rounded(toPlaces: 2), "peak_db": dB.rounded(toPlaces: 1)])
                        nextReport = total.rounded(.down) + 1
                        peak = 0
                    }
                } else {
                    Trace.shared.event("audio.drop", ["frames": Int(chunk.buffer.frameLength), "format": "\(chunk.buffer.format)"])
                }
            }
            Trace.shared.event("audio.end", ["audio": fed.value.rounded(toPlaces: 2)])
            // Audio ended (stopped or file finished): flush the last words as a final result,
            // which also ends `transcriber.results`.
            inputContinuation.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        let (events, eventContinuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        resultsTask = Task.detached {
            do {
                for try await result in transcriber.results {
                    let tokens = result.text.runs.map { run in
                        let range = run.audioTimeRange
                        return Token(String(result.text[run.range].characters),
                                     start: range?.start.seconds ?? 0, end: range?.end.seconds ?? 0)
                    }
                    let end = result.range.end.seconds
                    Trace.shared.event("asr.result", [
                        "kind": result.isFinal ? "final" : "volatile",
                        "text": String(result.text.characters),
                        "runs": tokens.count,
                        "start": result.range.start.seconds.rounded(toPlaces: 2),
                        "end": end.rounded(toPlaces: 2),
                        // How far recognition trails the audio already fed in.
                        "lag": (fed.value - end).rounded(toPlaces: 2),
                    ])
                    eventContinuation.yield(result.isFinal ? .final(tokens) : .volatile(tokens))
                }
                eventContinuation.finish()
            } catch {
                Trace.shared.event("asr.error", ["error": "\(error)"])
                eventContinuation.finish(throwing: error)
            }
        }
        return events
    }

    /// Waits for already-captured audio to be recognized. Call after the audio stream has ended.
    public func stop() async {
        await feedTask?.value
        await resultsTask?.value
        analyzer = nil
    }

    public func cancel() async {
        feedTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        analyzer = nil
    }
}

public enum TranscriberError: LocalizedError {
    case unsupportedLocale(Locale)
    case noAudioFormat

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let locale):
            "這台裝置不支援 \(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) 的語音辨識。"
        case .noAudioFormat:
            "語音辨識無法使用這個音訊格式。"
        }
    }
}

/// Converts capture buffers (any rate/channel layout) to the analyzer's format.
/// Recreates the underlying converter if the input format changes mid-stream (e.g. device switch).
final class BufferConverter: @unchecked Sendable {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.format == outputFormat { return input }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Seconds of audio handed to the analyzer so far; shared by the feed and results tasks.
final class AudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0

    var value: Double { lock.withLock { seconds } }

    func add(_ delta: Double) -> Double {
        lock.withLock {
            seconds += delta
            return seconds
        }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}

extension AVAudioPCMBuffer {
    /// Largest absolute sample value (0…1) for float or int16 PCM.
    var peakLevel: Float {
        let frames = Int(frameLength)
        var peak: Float = 0
        if let channels = floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for i in 0..<frames { peak = max(peak, abs(channels[channel][i])) }
            }
        } else if let channels = int16ChannelData {
            for channel in 0..<Int(format.channelCount) {
                for i in 0..<frames { peak = max(peak, abs(Float(channels[channel][i]) / Float(Int16.max))) }
            }
        }
        return peak
    }
}

/// Latest input peak (0…1) with a short decay, safe to read from any thread.
public final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var updated = Date.distantPast

    public init() {}

    func update(_ value: Float) {
        lock.withLock {
            peak = max(value, peak * 0.6)
            updated = .now
        }
    }

    /// Peak level, falling to 0 if no audio has arrived for half a second.
    public var value: Float {
        lock.withLock { Date.now.timeIntervalSince(updated) < 0.5 ? peak : 0 }
    }
}
