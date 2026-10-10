#if DEBUG && os(macOS)
import AppKit
import InstantCore

/// Debug-only hooks for driving the app from the command line, e.g. to capture screenshots
/// without Screen Recording permission (an app may always draw its own window):
///
///   INSTANT_DEMO_AUDIO=Samples/ja-meeting.aiff INSTANT_SNAPSHOT=/tmp/instant INSTANT_SNAPSHOT_AT=1,10,26 \
///     build/DerivedData/Build/Products/Debug/Instant.app/Contents/MacOS/Instant
///
/// INSTANT_DEMO_START=<seconds> skips into the demo audio. INSTANT_INPUT=system starts listening to Mac audio instead. Each snapshot also writes the
/// transcript next to the PNG as .txt.
enum DevAutomation {
    @MainActor
    static func run(session: LiveSession) async {
        let env = ProcessInfo.processInfo.environment
        if let path = env["INSTANT_SNAPSHOT"] {
            let times = (env["INSTANT_SNAPSHOT_AT"] ?? "2").split(separator: ",").compactMap { Double($0) }
            Task {
                let start = ContinuousClock.now
                for time in times.sorted() {
                    try? await Task.sleep(until: start + .seconds(time))
                    snapshot(to: "\(path)-\(Int(time))s.png")
                    dumpTranscript(session.transcript, to: "\(path)-\(Int(time))s.txt")
                }
            }
        }
        if let audio = env["INSTANT_DEMO_AUDIO"] {
            let start = env["INSTANT_DEMO_START"].flatMap(TimeInterval.init) ?? 0
            await session.start(audioSource: FileAudioSource(url: URL(fileURLWithPath: audio), startTime: start))
        } else if env["INSTANT_INPUT"] == "system" {
            session.input = .systemAudio
            await session.start()
        }
    }

    private static func dumpTranscript(_ transcript: Transcript, to path: String) {
        // Also into the trace, so `instant-lab report` has the on-screen lines even if the app is killed.
        Trace.shared.event("ui.snapshot", [
            "lines": transcript.lines.map { ["id": $0.id, "source": $0.source, "translation": $0.translation ?? "", "final": $0.isFinal] as [String: any Sendable] },
            "tail": transcript.volatile,
        ])
        var text = transcript.lines.map { "\($0.translation ?? "（翻譯中）")\n  \($0.source)" }.joined(separator: "\n")
        if !transcript.volatile.isEmpty {
            text += "\n≈ \(transcript.draftTranslation ?? "")\n  … \(transcript.volatile)"
        }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @MainActor
    private static func snapshot(to path: String) {
        // The theme frame (contentView's superview) includes the title bar and toolbar.
        guard let window = NSApp.windows.first(where: \.isVisible),
              let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
