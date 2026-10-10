import InstantCore
import SwiftUI
@preconcurrency import Translation

struct ContentView: View {
    @State private var session = LiveSession()

    var body: some View {
        NavigationStack {
            TranscriptView(transcript: session.transcript, isListening: session.status == .running)
                .navigationTitle(LanguagePickers.title(for: session))
                .toolbarTitleMenu { LanguagePickers(session: session) }
                #if os(macOS)
                .navigationSubtitle(statusText)
                #endif
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom) { failureBanner }
        }
        // The system's download consent sheet must be presented from a view.
        .translationTask(session.translationDownload) { translation in
            try? await translation.prepareTranslation()
            session.translationDownloadFinished()
        }
        #if DEBUG && os(macOS)
        .task { await DevAutomation.run(session: session) }
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if LiveSession.Input.available.count > 1 {
            ToolbarItem {
                Picker("音訊來源", selection: $session.input) {
                    Label("麥克風", systemImage: "mic").tag(LiveSession.Input.microphone)
                    Label("Mac 聲音", systemImage: "speaker.wave.2").tag(LiveSession.Input.systemAudio)
                }
                .pickerStyle(.segmented)
                .disabled(session.status.isActive)
            }
        }
        ToolbarItem {
            Button("清除", systemImage: "trash") { session.clear() }
                .disabled(session.status.isActive || session.transcript.lines.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            if session.status.isActive {
                Button("停止", systemImage: "stop.fill") {
                    Task { await session.stop() }
                }
            } else {
                Button("開始", systemImage: "play.fill") {
                    Task { await session.start() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var statusText: String {
        switch session.status {
        case .idle, .failed: ""
        case .preparing(let message): message
        case .running: "聆聽中"
        }
    }

    @ViewBuilder
    private var failureBanner: some View {
        if case .failed(let message) = session.status {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .capsule)
                .padding()
        }
    }
}
