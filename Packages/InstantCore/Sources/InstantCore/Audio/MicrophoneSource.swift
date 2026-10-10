@preconcurrency import AVFoundation

/// Captures the default input device (Mac microphone, iPhone microphone, AirPods, USB mic…).
@MainActor
public final class MicrophoneSource: AudioSource {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    public init() {}

    public func start() async throws -> AsyncStream<AudioChunk> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw AudioSourceError.permissionDenied("麥克風")
        }
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .default)
        try audioSession.setActive(true)
        #endif

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioSourceError.unavailable("找不到麥克風。Mac mini 沒有內建麥克風，請接上外接麥克風、AirPods，或在「系統設定 › 聲音 › 輸入」選 iPhone。")
        }

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.continuation = continuation
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            continuation.yield(AudioChunk(buffer))
        }
        engine.prepare()
        try engine.start()
        return stream
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
