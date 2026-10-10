@preconcurrency import AVFoundation
import CoreML
@preconcurrency import FluidAudio

/// Who spoke when, via FluidAudio's streaming Sortformer: up to 4 speakers, stable identities,
/// ~1s latency. Runs on its own copy of the audio, in parallel with recognition, on the same
/// time base (seconds of audio since the session began).
///
/// Keeps Sortformer's per-frame speaker probabilities (80ms frames) rather than its segments, so a
/// line can be attributed by summing probability over exactly the span it was spoken, which also
/// works for one-word replies too short to form a segment.
public final class SpeakerDiarizer: @unchecked Sendable {
    public struct Attribution: Sendable {
        /// Slot 0…3, or nil if nobody was detected speaking.
        public let speaker: Int?
        /// The winning speaker's share of speech probability in the span (0…1).
        public let share: Double
    }

    private let diarizer: SortformerDiarizer
    private let numSpeakers: Int
    private let frameDuration: Double
    private let lock = NSLock()
    // Guarded by `lock`. Flattened [frame][speaker] probabilities.
    private var finalized: [Float] = []
    private var tentative: [Float] = []

    private init(diarizer: SortformerDiarizer, config: SortformerConfig) {
        self.diarizer = diarizer
        numSpeakers = config.numSpeakers
        frameDuration = Double(config.frameDurationSeconds)
    }

    /// Loads the model, downloading it (~240 MB) from HuggingFace the first time.
    /// `INSTANT_SPK_CONFIG` (fast | balanced) picks the Sortformer variant, for e2e comparisons.
    public static func load(downloadProgress: (@Sendable (Double) -> Void)? = nil) async throws -> SpeakerDiarizer {
        let variant = ProcessInfo.processInfo.environment["INSTANT_SPK_CONFIG"] ?? "fast"
        let config: SortformerConfig = variant == "balanced" ? .balancedV2_1 : .default
        let started = ContinuousClock.now
        // CPU+GPU: the Neural Engine path recompiles the model on every app launch (~21s before
        // any speaker is known); CPU+GPU loads in ~0.4s.
        let units: MLComputeUnits = ProcessInfo.processInfo.environment["INSTANT_SPK_UNITS"] == "all" ? .all : .cpuAndGPU
        let models = try await SortformerModels.loadFromHuggingFace(config: config, computeUnits: units) { progress in
            downloadProgress?(progress.fractionCompleted)
        }
        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models)
        Trace.shared.event("spk.start", [
            "model": "sortformer-\(variant)",
            "units": units == .all ? "all" : "cpuAndGPU",
            "speakers": config.numSpeakers,
            "frame_s": Double(config.frameDurationSeconds),
            "load_ms": Int(Trace.seconds(ContinuousClock.now - started) * 1000),
        ])
        return SpeakerDiarizer(diarizer: diarizer, config: config)
    }

    /// Diarizes `audio` until it ends.
    public func run(_ audio: AsyncStream<AudioChunk>) async {
        var nextReport = 2.0
        var fed = 0.0
        for await chunk in audio {
            guard let samples = Self.monoSamples(chunk.buffer) else { continue }
            fed += Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
            do {
                if let update = try diarizer.process(samples: samples, sourceSampleRate: chunk.buffer.format.sampleRate) {
                    ingest(update.chunkResult)
                }
            } catch {
                Trace.shared.event("spk.error", ["error": "\(error)"])
            }
            if coveredUntil >= nextReport {
                nextReport = coveredUntil.rounded(.down) + 2
                Trace.shared.event("spk.update", [
                    "covered": coveredUntil.rounded(toPlaces: 2),
                    // How far diarization trails the audio it has been given.
                    "lag": (fed - coveredUntil).rounded(toPlaces: 2),
                    "active": activeSpeakers,
                ])
            }
        }
        if let update = try? diarizer.finalizeSession() { ingest(update.chunkResult) }
    }

    /// Seconds of audio diarized so far, including tentative frames.
    public var coveredUntil: Double {
        lock.withLock { Double((finalized.count + tentative.count) / numSpeakers) * frameDuration }
    }

    /// Who spoke most between `start` and `end` (seconds).
    public func attribute(start: Double, end: Double) -> Attribution {
        lock.withLock {
            let frames = (finalized.count + tentative.count) / numSpeakers
            let first = max(0, Int(start / frameDuration))
            let last = min(frames, Int((end / frameDuration).rounded(.up)))
            guard first < last else { return Attribution(speaker: nil, share: 0) }
            var totals = [Double](repeating: 0, count: numSpeakers)
            for frame in first..<last {
                for speaker in 0..<numSpeakers {
                    totals[speaker] += Double(probability(frame: frame, speaker: speaker))
                }
            }
            let sum = totals.reduce(0, +)
            guard let best = totals.indices.max(by: { totals[$0] < totals[$1] }),
                  totals[best] > 0.2 * Double(last - first) // someone was speaking for a fifth of the span
            else { return Attribution(speaker: nil, share: 0) }
            return Attribution(speaker: best, share: sum > 0 ? totals[best] / sum : 0)
        }
    }

    // MARK: - Internals

    private func ingest(_ chunk: DiarizerChunkResult) {
        lock.withLock {
            let have = finalized.count / numSpeakers
            if chunk.startFrame > have {
                finalized.append(contentsOf: repeatElement(0, count: (chunk.startFrame - have) * numSpeakers))
            }
            finalized.append(contentsOf: chunk.finalizedPredictions)
            tentative = chunk.tentativePredictions
        }
    }

    /// Must hold `lock`.
    private func probability(frame: Int, speaker: Int) -> Float {
        let finalizedFrames = finalized.count / numSpeakers
        if frame < finalizedFrames { return finalized[frame * numSpeakers + speaker] }
        return tentative[(frame - finalizedFrames) * numSpeakers + speaker]
    }

    /// Speakers with probability over 0.5 in the most recent frame.
    public var speakingNow: [Int] { activeSpeakers }

    /// Speakers with probability over 0.5 in the most recent frame, for tracing.
    private var activeSpeakers: [Int] {
        lock.withLock {
            let source = tentative.isEmpty ? finalized : tentative
            guard source.count >= numSpeakers else { return [] }
            let lastFrame = source.suffix(numSpeakers)
            return lastFrame.indices.filter { lastFrame[$0] > 0.5 }.map { $0 - lastFrame.startIndex }
        }
    }

    private static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let count = Int(buffer.frameLength)
        if let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: count))
        }
        if let channel = buffer.int16ChannelData?[0] {
            return UnsafeBufferPointer(start: channel, count: count).map { Float($0) / Float(Int16.max) }
        }
        return nil
    }
}
