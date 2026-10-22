@preconcurrency import AVFoundation
import Speech

/// On-device speech recognition through `SpeechAnalyzer`. Recognition only: lines are
/// translated on device by `AppleTranslator`.
@MainActor
public final class AppleProvider: SpeechProvider {
    public let locale: Locale
    public let translates = false
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
            var estimator = VolatileTimeEstimator()
            do {
                for try await result in transcriber.results {
                    let tokens: [Token]
                    if result.isFinal {
                        tokens = result.text.runs.map { run in
                            let range = run.audioTimeRange
                            return Token(String(result.text[run.range].characters),
                                         start: range?.start.seconds ?? 0, end: range?.end.seconds ?? 0)
                        }
                        estimator.reset()
                    } else {
                        tokens = estimator.tokens(for: String(result.text.characters),
                                                  start: result.range.start.seconds, end: result.range.end.seconds)
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
