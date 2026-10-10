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
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        Trace.shared.event("audio.start", ["source": "system", "display": Int(display.displayID)])
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

    private final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let continuation: AsyncStream<AudioChunk>.Continuation
        let queue = DispatchQueue(label: "instant.system-audio")

        init(continuation: AsyncStream<AudioChunk>.Continuation) {
            self.continuation = continuation
        }

        // Counters for the once-a-second `audio.source` trace event (only touched on `queue`).
        private var received = 0
        private var failed = 0
        private var lastFailure = ""
        private var lastReport = Date.distantPast
        private var reportedFormat = false

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio else { return }
            received += 1
            switch Self.pcmBuffer(from: sampleBuffer) {
            case .success(let buffer):
                if !reportedFormat {
                    reportedFormat = true
                    Trace.shared.event("audio.source", ["format": "\(buffer.format)", "frames": Int(buffer.frameLength)])
                }
                continuation.yield(AudioChunk(buffer))
            case .failure(let reason):
                failed += 1
                lastFailure = reason.description
            }
            if Date().timeIntervalSince(lastReport) >= 1 {
                lastReport = Date()
                Trace.shared.event("audio.capture", ["received": received, "failed": failed, "lastFailure": lastFailure])
            }
        }

        func stream(_ stream: SCStream, didStopWithError error: any Error) {
            Trace.shared.event("audio.error", ["error": "\(error)"])
        }

        /// Copies the sample buffer's audio into a buffer we own. `CMSampleBufferCopyPCMDataIntoAudioBufferList`
        /// rejects ScreenCaptureKit's buffers (OSStatus -12731), so read the audio buffer list directly.
        private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> Result<AVAudioPCMBuffer, Failure> {
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0 else { return .failure(Failure("empty sample buffer")) }
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return .failure(Failure("no format description")) }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                return .failure(Failure("cannot allocate buffer for \(format)"))
            }
            // Set the length first: a fresh buffer's mDataByteSize reflects frameLength (0), not capacity.
            copy.frameLength = AVAudioFrameCount(frames)
            do {
                try sampleBuffer.withAudioBufferList { source, _ in
                    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                    for (from, to) in zip(source, destination) {
                        guard let fromData = from.mData, let toData = to.mData else { continue }
                        memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
                    }
                }
            } catch {
                return .failure(Failure("read audio buffer list failed: \(error), \(format)"))
            }
            return .success(copy)
        }

        struct Failure: Error, ExpressibleByStringLiteral, CustomStringConvertible {
            let description: String
            init(stringLiteral value: String) { description = value }
            init(_ value: String) { description = value }
        }
    }
}
#endif
