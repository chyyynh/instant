import AVFoundation
import InstantCore
import SwiftUI

/// A listening the user saved: captions with their times and speakers, the conversation with
/// Claude, and (optionally) the audio, which the captions' times point into.
struct SavedListening: Codable, Identifiable, Hashable {
    struct Caption: Codable, Hashable {
        var start: TimeInterval
        var end: TimeInterval
        var source: String
        var translation: String
        /// Speaker name as shown when saved ("田中", "說話者 A").
        var speaker: String?
        /// Index into the speaker colors.
        var color: Int?
    }

    struct Message: Codable, Hashable {
        var fromUser: Bool
        var text: String
    }

    let id: UUID
    var title: String
    let date: Date
    let duration: TimeInterval
    /// "Mac 聲音", "麥克風", a file name.
    let input: String
    /// "日本語 → 中文".
    let languages: String
    var captions: [Caption]
    var conversation: [Message]
    var hasAudio: Bool

    var speakerCount: Int { Set(captions.compactMap(\.speaker)).count }

    /// The transcript as plain text, with speaker names, like the live one.
    var transcriptText: String {
        var previous: String?
        return captions.map { caption in
            defer { previous = caption.speaker }
            let header = caption.speaker.flatMap { $0 == previous ? nil : "\($0)：\n" } ?? ""
            return "\(header)\(caption.translation)\n\(caption.source)"
        }.joined(separator: "\n\n")
    }
}

/// Saved listenings, one folder each (listening.json, audio.m4a) in Application Support.
@MainActor
@Observable
final class Library {
    /// Newest first.
    private(set) var listenings: [SavedListening] = []
    private let folder: URL

    init() {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["INSTANT_LIBRARY_DIR"] {
            folder = URL(fileURLWithPath: override, isDirectory: true)
            load()
            return
        }
        #endif
        folder = URL.applicationSupportDirectory.appending(path: "Instant/Listenings", directoryHint: .isDirectory)
        load()
    }

    func audioURL(_ listening: SavedListening) -> URL {
        folder.appending(path: listening.id.uuidString).appending(path: "audio.m4a")
    }

    /// Saves the session's last listening. The recording is copied, so it keeps playing here.
    func save(_ session: LiveSession, title: String, audio: Bool, conversation: [Assistant.Message]) throws -> SavedListening {
        let recording = session.recording
        let listening = SavedListening(
            id: UUID(),
            title: title,
            date: recording?.started ?? .now,
            duration: recording?.duration ?? session.captions.last?.end ?? 0,
            input: session.sourceDescription,
            languages: session.languageTitle,
            captions: session.captions.map { line in
                SavedListening.Caption(start: line.start, end: line.end, source: line.source, translation: line.translation ?? "",
                                       speaker: line.speaker.map { session.displayName(of: $0) },
                                       color: line.speaker.map { session.speakerColorIndex($0) })
            },
            conversation: conversation.map { .init(fromUser: $0.role == .user, text: $0.text) },
            hasAudio: audio && recording != nil)
        let directory = folder.appending(path: listening.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if listening.hasAudio, let recording {
            try FileManager.default.copyItem(at: recording.url, to: audioURL(listening))
        }
        try write(listening)
        listenings.insert(listening, at: 0)
        return listening
    }

    func rename(_ id: SavedListening.ID, to title: String) {
        guard let index = listenings.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        listenings[index].title = title
        try? write(listenings[index])
    }

    func delete(_ id: SavedListening.ID) {
        try? FileManager.default.removeItem(at: folder.appending(path: id.uuidString))
        listenings.removeAll { $0.id == id }
    }

    private func write(_ listening: SavedListening) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(listening).write(to: folder.appending(path: listening.id.uuidString).appending(path: "listening.json"))
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        listenings = folders.compactMap { directory in
            (try? Data(contentsOf: directory.appending(path: "listening.json"))).flatMap { try? decoder.decode(SavedListening.self, from: $0) }
        }
        .sorted { $0.date > $1.date }
    }
}

/// Plays a recording, publishing its position for the captions and the scrubber.
@MainActor
@Observable
final class Player {
    let url: URL
    let duration: TimeInterval
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    var rate: Float = 1 {
        didSet { audio?.rate = rate }
    }
    @ObservationIgnored private let audio: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    init(url: URL) {
        self.url = url
        audio = try? AVAudioPlayer(contentsOf: url)
        audio?.enableRate = true
        audio?.prepareToPlay()
        duration = audio?.duration ?? 0
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let audio else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        if audio.currentTime >= duration - 0.05 { audio.currentTime = 0 }
        audio.rate = rate
        audio.play()
        isPlaying = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled, let self, let audio = self.audio {
                currentTime = audio.currentTime
                if !audio.isPlaying {
                    isPlaying = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func pause() {
        audio?.pause()
        ticker?.cancel()
        isPlaying = false
    }

    /// Jumps to `time` and plays from there.
    func play(from time: TimeInterval) {
        seek(to: time)
        if !isPlaying { play() }
    }

    func seek(to time: TimeInterval) {
        let time = min(max(time, 0), duration)
        audio?.currentTime = time
        currentTime = time
    }

    func stop() {
        pause()
    }
}
