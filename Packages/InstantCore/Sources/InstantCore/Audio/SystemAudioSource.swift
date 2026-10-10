#if os(macOS)
@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit

/// Captures everything the Mac is playing (videos, calls…) via ScreenCaptureKit.
/// Useful for testing with recordings and for online meetings.
@MainActor
public final class SystemAudioSource: NSObject, AudioSource {
    private var stream: SCStream?
    private var output: Output?

    public override init() {}

    public func start() async throws -> AsyncStream<AudioChunk> {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw AudioSourceError.permissionDenied("螢幕與系統錄音")
        }
        guard let display = content.displays.first else {
            throw AudioSourceError.unavailable("找不到可擷取聲音的螢幕。")
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        // Video is required by SCStream; keep it as small and slow as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let (chunks, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let output = Output(continuation: continuation)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
        return chunks
    }

    public func stop() {
        let stream = stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        output?.continuation.finish()
        output = nil
    }

    private final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
        let continuation: AsyncStream<AudioChunk>.Continuation
        let queue = DispatchQueue(label: "instant.system-audio")

        init(continuation: AsyncStream<AudioChunk>.Continuation) {
            self.continuation = continuation
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
            continuation.yield(AudioChunk(buffer))
        }

        private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0,
                  let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: AVAudioFormat(cmAudioFormatDescription: description),
                      frameCapacity: AVAudioFrameCount(frames))
            else { return nil }
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            guard status == noErr else { return nil }
            buffer.frameLength = AVAudioFrameCount(frames)
            return buffer
        }
    }
}
#endif
