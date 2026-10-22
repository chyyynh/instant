@preconcurrency import AVFoundation
import Foundation

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

/// Estimates when each character of in-progress results was spoken. Volatile results carry one
/// time range for all text since the last final, but each update extends it: characters that
/// weren't in the previous hypothesis were spoken between the previous result's end and this
/// one's. That places them within about a second, enough to tell who said a line. The estimates
/// are marked untimed so they never count as pauses for segmentation.
struct VolatileTimeEstimator {
    private var characters: [Character] = []
    private var times: [(start: TimeInterval, end: TimeInterval)] = []

    mutating func reset() {
        characters = []
        times = []
    }

    mutating func tokens(for text: String, start: TimeInterval, end: TimeInterval) -> [Token] {
        let new = Array(text)
        let kept = zip(new, characters).prefix { $0 == $1 }.count
        var updated = Array(times.prefix(kept))
        // Revised or appended characters fill the span after the last unchanged one.
        let spanStart = max(updated.last?.end ?? start, start)
        let step = max(end - spanStart, 0) / Double(max(new.count - kept, 1))
        for offset in 0..<(new.count - kept) {
            let characterStart = spanStart + step * Double(offset)
            updated.append((characterStart, characterStart + step))
        }
        characters = new
        times = updated
        return zip(new, updated).map { Token(String($0), start: $1.start, end: $1.end, isTimed: false) }
    }
}
