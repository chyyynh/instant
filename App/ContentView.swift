import InstantCore
import SwiftUI
@preconcurrency import Translation

struct ContentView: View {
    @Environment(LiveSession.self) private var session
    @Environment(AppUI.self) private var ui
    @Environment(Assistant.self) private var assistant
    @AppStorage(Pref.captionPoints) private var captionPoints = CaptionMetrics.standard
    @AppStorage(Pref.showOriginal) private var showOriginal = true
    /// Ticks every second while listening, so the elapsed time in the subtitle advances (the
    /// window subtitle is plain text, so a timer-style Text wouldn't update by itself).
    @State private var now = Date.now
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #else
    @ScaledMetric(relativeTo: .title2) private var typeScale = 1.0
    @State private var settingsShown = false
    #endif

    /// Caption size on screen: the chosen size, scaled with Dynamic Type on iOS.
    private var points: Double {
        #if os(iOS)
        captionPoints * typeScale
        #else
        captionPoints
        #endif
    }

    var body: some View {
        @Bindable var ui = ui
        NavigationStack {
            content
                .navigationTitle(session.languageTitle)
                .toolbarTitleMenu { LanguagePickers(session: session) }
                .navigationSubtitle(subtitle)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar }
                .safeAreaBar(edge: .bottom) { bottomBar }
                #if os(macOS)
                // Room for captions when the inspector opens: the window widens instead.
                .frame(minWidth: 420, minHeight: 360)
                #endif
                #if os(iOS)
                .safeAreaBar(edge: .top) { speakerChips }
                #endif
        }
        #if os(macOS)
        .inspector(isPresented: $ui.inspectorShown) {
            AssistantView()
                .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
                .toolbar {
                    ToolbarItem {
                        Button("新對話", systemImage: "square.and.pencil") { assistant.reset() }
                            .help("清掉這段討論，重新開始")
                            .disabled(assistant.messages.isEmpty)
                    }
                }
        }
        #else
        .sheet(isPresented: $settingsShown) { SettingsSheet() }
        .sheet(isPresented: $ui.assistantShown) { AssistantSheet() }
        #endif
        .renameSpeakerAlert()
        .animation(.smooth(duration: 0.3), value: session.status.isActive)
        .task(id: session.status == .running) {
            while session.status == .running, !Task.isCancelled {
                now = .now
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // The system's download consent sheet must be presented from a view.
        .translationTask(session.translationDownload) { translation in
            try? await translation.prepareTranslation()
            session.translationDownloadFinished()
        }
        #if DEBUG
        .task {
            #if os(macOS)
            await DevAutomation.run(session: session, ui: ui, assistant: assistant, openSettings: { openSettings() })
            #else
            await DevAutomation.run(session: session, ui: ui, assistant: assistant, openSettings: { settingsShown = true })
            #endif
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let fraction = session.speakerModelDownload {
            SpeakerDownloadView(fraction: fraction)
        } else if !session.captions.isEmpty || !session.pendingText.isEmpty {
            TranscriptView(points: points, showOriginal: showOriginal)
        } else {
            switch session.status {
            case .idle, .failed:
                IdleView()
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            case .preparing:
                ContentUnavailableView {
                    Label("準備中…", systemImage: "hourglass")
                } description: {
                    Text("第一次使用時，可能要下載語言包或模型。")
                }
            case .running:
                ContentUnavailableView {
                    Label("聆聽中…", systemImage: "waveform")
                        .symbolEffect(.variableColor.iterative)
                } description: {
                    Text("有人說話時，字幕會從這裡開始出現。")
                }
            }
        }
    }

    /// "聆聽中 · Mac 聲音 · 04:12 · 3 位說話者", the step while preparing, or the input when idle.
    private var subtitle: Text {
        switch session.status {
        case .preparing(let message):
            return Text(message)
        case .running:
            let elapsed = session.startedAt.map { Duration.seconds(max(0, now.timeIntervalSince($0)).rounded(.down)).formatted(.time(pattern: .minuteSecond)) } ?? ""
            let count = session.speakers.count
            return count > 0
                ? Text("聆聽中 · \(session.sourceDescription) · \(elapsed) · \(count) 位說話者")
                : Text("聆聽中 · \(session.sourceDescription) · \(elapsed)")
        case .idle, .failed:
            return Text("\(session.inputName) · 裝置上處理")
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 0) {
            if case .failed(let message) = session.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .capsule)
                    .padding()
            }
            if session.status == .running, !session.captions.isEmpty || !session.pendingText.isEmpty {
                LiveCard(points: points)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup {
            Button("說話者", systemImage: session.speakerDiarizationEnabled ? "person.2" : "person.2.slash") {
                ui.speakersShown.toggle()
            }
            .help("說話者清單，以及是否用聲音區分說話者")
            .popover(isPresented: Bindable(ui).speakersShown, arrowEdge: .bottom) {
                SpeakerInspector()
                    .frame(width: 300, height: 380)
            }
            if LiveSession.Input.available.count > 1 {
                InputMenu()
            }
            Toggle("浮動字幕", systemImage: "pip", isOn: Bindable(ui).overlayShown)
                .toggleStyle(.button)
                .help("在所有視窗上方顯示字幕")
        }
        ToolbarItem {
            Toggle("和 Claude 討論", systemImage: "sparkles", isOn: Bindable(ui).inspectorShown)
                .toggleStyle(.button)
                .help("邊聽邊問 Claude 關於這段對話")
        }
        if let transport = TransportButton.Kind(session: session, idleShowsButton: !session.captions.isEmpty) {
            ToolbarItem(placement: .primaryAction) { TransportButton(kind: transport) }
        }
        #else
        ToolbarItem(placement: .topBarTrailing) {
            Button("和 Claude 討論", systemImage: "sparkles") { ui.assistantShown = true }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("設定", systemImage: "gearshape") { settingsShown = true }
        }
        if let transport = TransportButton.Kind(session: session, idleShowsButton: !session.captions.isEmpty) {
            ToolbarItem(placement: .bottomBar) { CaptionSizeMenu() }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { TransportButton(kind: transport) }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                ShareLink(item: session.transcriptText) { Label("分享逐字稿", systemImage: "square.and.arrow.up") }
                    .disabled(session.captions.isEmpty)
            }
        }
        #endif
    }

    #if os(iOS)
    /// Everyone heard so far; tap to rename.
    @ViewBuilder
    private var speakerChips: some View {
        let speakers = session.speakers
        if !speakers.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(speakers) { speaker in
                        Button { ui.rename(speaker.id, in: session) } label: {
                            SpeakerLabel(name: speaker.name, color: speaker.color)
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
    }
    #endif
}

/// Before anything has been heard: one big start button.
private struct IdleView: View {
    @Environment(LiveSession.self) private var session

    var body: some View {
        ContentUnavailableView {
            Label("開始即時翻譯", systemImage: "waveform")
        } description: {
            Text(description)
        } actions: {
            VStack(spacing: 10) {
                Button {
                    Task { await session.start() }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 38, weight: .medium))
                        .frame(width: 80, height: 80)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
                .tint(.red)
                .accessibilityLabel("開始聆聽")
                #if os(macOS)
                Text("Space")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
            .padding(.top, 20)
        }
    }

    private var description: String {
        let spoken = Locale.current.localizedString(forLanguageCode: session.sourceLocale.language.languageCode?.identifier ?? "") ?? "外語"
        let target = Locale.current.localizedString(forLanguageCode: session.targetLanguage.languageCode?.identifier ?? "") ?? "中文"
        #if os(macOS)
        let heard = session.input == .microphone ? "聽身邊的人說的\(spoken)" : "聽 Mac 播出的\(spoken)"
        return "\(heard)，翻成\(target)字幕。全部在這台 Mac 上處理。"
        #else
        return "把手機放在說話的人附近，\(spoken)會即時翻成\(target)字幕。"
        #endif
    }
}

/// First use with speakers on: the speaker model is downloading.
private struct SpeakerDownloadView: View {
    @Environment(LiveSession.self) private var session
    let fraction: Double

    var body: some View {
        ContentUnavailableView {
            Label("下載說話者辨識模型", systemImage: "person.2")
        } description: {
            Text("只有第一次需要，約 \(LiveSession.speakerModelMegabytes) MB。下載後在這台裝置上分辨最多 4 位說話者，聲音不會上傳。")
        } actions: {
            VStack(spacing: 16) {
                ProgressView(value: fraction) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int(fraction * Double(LiveSession.speakerModelMegabytes))) MB / \(LiveSession.speakerModelMegabytes) MB")
                        .monospacedDigit()
                }
                .frame(maxWidth: 300)
                Button("這次先不分辨說話者，直接開始") { session.skipSpeakerDiarization() }
                    #if os(macOS)
                    .buttonStyle(.link)
                    #else
                    .buttonStyle(.borderless)
                    #endif
            }
        }
    }
}

/// Start, stop, or cancel a start that's still preparing.
struct TransportButton: View {
    enum Kind {
        case start, stop, cancel

        /// nil when there's nothing to show (idle with the big start button on screen).
        @MainActor init?(session: LiveSession, idleShowsButton: Bool) {
            switch session.status {
            case .preparing: self = .cancel
            case .running: self = .stop
            case .idle, .failed:
                guard idleShowsButton else { return nil }
                self = .start
            }
        }
    }

    @Environment(LiveSession.self) private var session
    let kind: Kind

    var body: some View {
        switch kind {
        case .start:
            Button { Task { await session.start() } } label: {
                Label("開始", systemImage: "mic.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
        case .stop:
            Button { Task { await session.stop() } } label: {
                #if os(iOS)
                // Spelled out: a bottom-bar Label would show its icon only.
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative)
                    Text("停止")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                #else
                Label("停止", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
                #endif
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
        case .cancel:
            Button("取消") { session.cancelStart() }
        }
    }
}

/// Microphone or Mac audio, as a toolbar menu (fixed while listening).
struct InputMenu: View {
    @Environment(LiveSession.self) private var session

    var body: some View {
        @Bindable var session = session
        Menu {
            Picker("音源", selection: $session.input) {
                Label("麥克風", systemImage: "mic").tag(LiveSession.Input.microphone)
                Label("Mac 聲音", systemImage: "speaker.wave.2").tag(LiveSession.Input.systemAudio)
            }
            .pickerStyle(.inline)
        } label: {
            Label("音源：\(session.inputName)", systemImage: session.inputSymbol)
        }
        .help(session.status.isActive ? "停止後才能切換音源" : "音源")
        .disabled(session.status.isActive)
    }
}

#if os(iOS)
/// Aa: caption size steps and the original-text toggle.
private struct CaptionSizeMenu: View {
    @AppStorage(Pref.captionPoints) private var captionPoints = CaptionMetrics.standard
    @AppStorage(Pref.showOriginal) private var showOriginal = true

    var body: some View {
        Menu {
            Button("放大字幕", systemImage: "plus.magnifyingglass") {
                captionPoints = min(captionPoints + CaptionMetrics.step, CaptionMetrics.range.upperBound)
            }
            Button("縮小字幕", systemImage: "minus.magnifyingglass") {
                captionPoints = max(captionPoints - CaptionMetrics.step, CaptionMetrics.range.lowerBound)
            }
            Button("標準大小", systemImage: "textformat.size") { captionPoints = CaptionMetrics.standard }
            Divider()
            Toggle("顯示原文", systemImage: "character.ja", isOn: $showOriginal)
        } label: {
            Label("字級", systemImage: "textformat.size")
        }
    }
}
#endif

enum WindowID {
    static let main = "main"
    static let overlay = "overlay"
}

extension LiveSession {
    /// The speaker toggle, remembered across launches.
    var speakersEnabledBinding: Binding<Bool> {
        Binding(get: { self.speakerDiarizationEnabled },
                set: {
                    self.speakerDiarizationEnabled = $0
                    UserDefaults.standard.set($0, forKey: Pref.speakersEnabled)
                })
    }
}
