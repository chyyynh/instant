@preconcurrency import AVFoundation

/// Plays an audio file into the pipeline at real-time speed, as if it were live.
/// Used by `instant-lab` and tests to measure latency without a microphone.
@MainActor
public final class FileAudioSource: AudioSource {
    private let url: URL
    private let startTime: TimeInterval
    private let chunkDuration: Duration
    private let speed: Double
    private var task: Task<Void, Never>?

    /// - Parameter startTime: Seconds into the file to start from (e.g. to skip a podcast intro).
    public var name: String { url.lastPathComponent }

    /// - Parameter speed: Playback rate; >1 compresses long-session tests (e.g. 20 min at 4×).
    public init(url: URL, startTime: TimeInterval = 0, speed: Double = 1, chunkDuration: Duration = .milliseconds(100)) {
        self.url = url
        self.startTime = startTime
        self.speed = speed
        self.chunkDuration = chunkDuration
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        file.framePosition = min(AVAudioFramePosition(startTime * format.sampleRate), file.length)
        let seconds = Double(chunkDuration.components.attoseconds) / 1e18 + Double(chunkDuration.components.seconds)
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let pause = chunkDuration / speed
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let unsafeFile = file
        task = Task.detached {
            while unsafeFile.framePosition < unsafeFile.length, !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                      (try? unsafeFile.read(into: buffer, frameCount: frames)) != nil
                else { break }
                continuation.yield(AudioChunk(buffer))
                try? await Task.sleep(for: pause)
            }
            continuation.finish()
        }
        return stream
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
