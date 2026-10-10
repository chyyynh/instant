@preconcurrency import AVFoundation

/// A buffer of captured audio. `AVAudioPCMBuffer` isn't `Sendable`, but each chunk is
/// produced once and handed off, never mutated after yielding.
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    public init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

@MainActor
public protocol AudioSource: AnyObject {
    /// Starts capture and returns the stream of audio chunks. The stream finishes after `stop()`.
    func start() async throws -> AsyncStream<AudioChunk>
    func stop()
}

public enum AudioSourceError: LocalizedError {
    case permissionDenied(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let what): "沒有\(what)權限，請到「系統設定 › 隱私權與安全性」允許。"
        case .unavailable(let reason): reason
        }
    }
}
