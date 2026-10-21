@preconcurrency import AVFoundation

/// Writes a session's audio to an AAC file, on the session's time base (second 0 is the start of
/// the session's audio), so a caption's `start` is where it is in the file.
///
/// Mono 24 kHz at 48 kbps: speech stays clear at about 21 MB an hour.
final class AudioRecorder: Sendable {
    let url: URL

    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    init(url: URL) {
        self.url = url
    }

    /// Records `audio` until it ends, then closes the file. Returns the seconds written.
    func run(_ audio: AsyncStream<AudioChunk>) async -> Double {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        let file: AVAudioFile
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            Trace.shared.event("rec.error", ["error": "\(error)", "stage": "open"])
            for await _ in audio {}
            return 0
        }
        let converter = BufferConverter(outputFormat: Self.format)
        var seconds = 0.0
        var failed = false
        for await chunk in audio {
            guard !failed, let buffer = converter.convert(chunk.buffer) else { continue }
            do {
                try file.write(from: buffer)
                seconds += Double(buffer.frameLength) / Self.format.sampleRate
            } catch {
                // Keep draining so recognition isn't held up, but stop writing.
                failed = true
                Trace.shared.event("rec.error", ["error": "\(error)", "stage": "write"])
            }
        }
        file.close()
        Trace.shared.event("rec.end", ["seconds": seconds.rounded(toPlaces: 2), "file": url.lastPathComponent])
        return seconds
    }
}
