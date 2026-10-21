#if DEBUG
import InstantCore
import SwiftUI
#if os(macOS)
import AppKit
import ScreenCaptureKit
#endif

/// Debug-only hooks for driving the app from the command line, e.g. to capture screenshots:
///
///   open -g -n <Xcode DerivedData>/Build/Products/Debug/Instant.app --env INSTANT_DEMO_AUDIO=$PWD/Samples/ja-meeting.aiff \
///     --env INSTANT_SNAPSHOT=/tmp/instant --env INSTANT_SNAPSHOT_AT=1,10,26
///
/// (`open -g` launches it in the background; on iOS pass the variables as SIMCTL_CHILD_… to
/// `xcrun simctl launch` and take screenshots with `simctl io screenshot`.)
///
/// - INSTANT_DEMO_AUDIO=<file> plays a file instead of listening; INSTANT_DEMO_START=<s> skips into
///   it, INSTANT_DEMO_SPEED=<rate> plays it faster, INSTANT_DEMO_DELAY=<s> waits before starting.
/// - INSTANT_INPUT=system starts listening to Mac audio instead.
/// - INSTANT_DEMO_UI=1 shows a canned listening state (a short meeting) without running the
///   pipeline, e.g. in the Simulator, which has no speech recognition.
/// - Mac: INSTANT_SNAPSHOT=<prefix> with INSTANT_SNAPSHOT_AT=<s,s,…> captures the main window, plus
///   the floating captions (-overlay), Settings (-settings) and the menu bar window (-menubar) when
///   open, and writes the transcript as .txt. INSTANT_INSPECTOR=1 (the Claude panel; INSTANT_ASSISTANT=1 also fills it with a canned chat under INSTANT_DEMO_UI; INSTANT_REVEAL=n then shows caption n as if its time were clicked), INSTANT_OVERLAY=1 and
///   INSTANT_SETTINGS=1 open those first (INSTANT_SETTINGS_TAB=recognition|captions|ai picks the tab); INSTANT_MENUBAR=1 shows the menu bar window's content in a
///   stand-in window. INSTANT_APPEARANCE=dark|light.
/// - INSTANT_DEMO_STOP_AT=<s> stops listening that long after launch; then INSTANT_PLAY_AT=<s> plays
///   the recording from there and INSTANT_SAVE=1 opens the save sheet (=now saves it right away). INSTANT_LIBRARY=1 opens the
///   saved listenings; INSTANT_LIBRARY_DIR=<dir> keeps them somewhere else than Application Support.
enum DevAutomation {
    @MainActor
    static func run(session: LiveSession, ui: AppUI, assistant: Assistant, library: Library, openSettings: @escaping @MainActor () -> Void,
                    openLibrary: @escaping @MainActor () -> Void) async {
        let env = ProcessInfo.processInfo.environment
        #if os(macOS)
        if let appearance = env["INSTANT_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if env["INSTANT_INSPECTOR"] == "1" || env["INSTANT_ASSISTANT"] == "1" { ui.inspectorShown = true }
        if env["INSTANT_OVERLAY"] == "1" { ui.overlayShown = true }
        if env["INSTANT_SETTINGS"] == "1" { openSettings() }
        if env["INSTANT_MENUBAR"] == "1" { openMenuBarPreview(session: session, ui: ui) }
        if let path = env["INSTANT_SNAPSHOT"] {
            let times = (env["INSTANT_SNAPSHOT_AT"] ?? "2").split(separator: ",").compactMap { Double($0) }
            Task {
                let start = ContinuousClock.now
                for time in times.sorted() {
                    try? await Task.sleep(until: start + .seconds(time))
                    let name = time == time.rounded() ? "\(Int(time))s" : String(format: "%.2fs", time)
                    await snapshot(window: WindowID.main, to: "\(path)-\(name).png")
                    await snapshot(window: WindowID.overlay, to: "\(path)-\(name)-overlay.png")
                    await snapshot(window: "com_apple_SwiftUI_Settings", to: "\(path)-\(name)-settings.png")
                    await snapshot(window: "menubar-preview", to: "\(path)-\(name)-menubar.png")
                    await snapshot(window: WindowID.library, to: "\(path)-\(name)-library.png")
                    dumpTranscript(session, to: "\(path)-\(name).txt")
                }
            }
        }
        #endif
        if env["INSTANT_DEMO_UI"] == "1" {
            // A canned meeting, for checking the listening UI without speech recognition.
            session.showDemoState(captions: [
                ("佐藤さん、昨日の件なんですけど、結局先方には連絡したんですか。", "佐藤，關於昨天的事，你最後有聯絡對方嗎？"),
                ("いや、まだです。ちょっとバタバタしてて。", "不，還沒。最近有點手忙腳亂的。"),
                ("じゃあ今日中にお願いできますか。", "那今天之內可以拜託你嗎？"),
                ("ちなみにあれって来週のリリースに間に合いそうですか。", "順帶一提，那個趕得上下週的發布嗎？"),
                ("正直厳しいですね。テストはまだ半分くらいです。", "老實說有點難，測試大概只做完一半。"),
            ], pending: "じゃあ来週の月曜にもう一回確認しましょう", draft: nil, elapsed: 134)
            if env["INSTANT_ASSISTANT"] == "1" {
                assistant.showDemo([
                    ("整理目前的重點", "- **聯絡對方**：佐藤還沒聯絡，被要求**今天之內**處理。\n- **下週發布**：測試只做完一半，趕不趕得上還沒定。", 4),
                    ("我可以怎麼回應？", "可以先確認範圍：「テストの残りはどのくらいかかりそうですか？」（剩下的測試大概要多久？）\n再看要不要延後發布。", 5),
                ])
            }
            if let reveal = env["INSTANT_REVEAL"].flatMap(Int.init) {
                try? await Task.sleep(for: .seconds(1))
                ui.revealedCaption = reveal
            }
            return
        }
        if env["INSTANT_LIBRARY"] == "1" { openLibrary() }
        if let stopAt = env["INSTANT_DEMO_STOP_AT"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(stopAt))
                await session.stop()
                while session.status.isActive || ui.player == nil { try? await Task.sleep(for: .milliseconds(100)) }
                if let playAt = env["INSTANT_PLAY_AT"].flatMap(Double.init) { ui.player?.play(from: playAt) }
                if env["INSTANT_SAVE"] == "1" { ui.savingShown = true }
                if env["INSTANT_SAVE"] == "now", let saved = try? library.save(session, title: "測試紀錄", audio: true, conversation: assistant.messages) {
                    ui.savedListening = saved.id
                    openLibrary()
                }
            }
        }
        if let delay = env["INSTANT_DEMO_DELAY"].flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(delay))
        }
        if let audio = env["INSTANT_DEMO_AUDIO"] {
            let start = env["INSTANT_DEMO_START"].flatMap(TimeInterval.init) ?? 0
            let speed = env["INSTANT_DEMO_SPEED"].flatMap(Double.init) ?? 1
            await session.start(audioSource: FileAudioSource(url: URL(fileURLWithPath: audio), startTime: start, speed: speed))
        } else if env["INSTANT_INPUT"] == "system" {
            session.input = .systemAudio
            await session.start()
        }
    }

    #if os(macOS)
    @MainActor
    private static func dumpTranscript(_ session: LiveSession, to path: String) {
        let transcript = session.transcript
        // Also into the trace, so `instant-lab report` has the on-screen lines even if the app is killed.
        Trace.shared.event("ui.snapshot", [
            "lines": transcript.lines.map { ["id": $0.id, "source": $0.source, "translation": $0.translation ?? "", "final": $0.isFinal] as [String: any Sendable] },
            "tail": transcript.volatile,
        ])
        // What's on screen: captions, then the pending (not yet translated) text.
        var text = session.captions.map { "\($0.translation ?? "")\n  \($0.source)" }.joined(separator: "\n")
        if !transcript.pendingText.isEmpty {
            text += "\n…  \(transcript.pendingText)"
        }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Shows the menu bar window's content in a menu-material window, for screenshots: SwiftUI's
    /// MenuBarExtra can't be opened programmatically (its status button has no action and ignores
    /// synthesized clicks).
    @MainActor
    private static func openMenuBarPreview(session: LiveSession, ui: AppUI) {
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        let hosting = NSHostingView(rootView: MenuBarContent().environment(session).environment(ui))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("menubar-preview")
        window.contentView = effect
        window.isOpaque = false
        window.backgroundColor = .clear
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        window.center()
        window.orderFrontRegardless()
    }

    @MainActor
    private static func snapshot(window id: String, to path: String) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix(id) == true })
        else { return }
        // The window server's image of the window, glass and materials included (drawing the view
        // hierarchy misses them). Needs the screen-recording permission Mac audio already uses;
        // falls back to drawing the views.
        if let content = try? await SCShareableContent.current,
           let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
            let configuration = SCStreamConfiguration()
            configuration.width = Int(scWindow.frame.width * window.backingScaleFactor)
            configuration.height = Int(scWindow.frame.height * window.backingScaleFactor)
            configuration.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                                                                      configuration: configuration) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                return
            }
        }
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}

#endif
