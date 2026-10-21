import InstantCore
import SwiftUI

#if os(macOS)
/// ⌘, : the standard Settings window, one grouped form per tab.
struct SettingsView: View {
    #if DEBUG
    @State private var tab = ProcessInfo.processInfo.environment["INSTANT_SETTINGS_TAB"] ?? "general"
    #else
    @State private var tab = "general"
    #endif

    var body: some View {
        TabView(selection: $tab) {
            Tab("一般", systemImage: "gearshape", value: "general") {
                Form { GeneralSettings() }.formStyle(.grouped)
            }
            Tab("辨識", systemImage: "waveform", value: "recognition") {
                Form { RecognitionSettings() }.formStyle(.grouped)
            }
            Tab("字幕", systemImage: "captions.bubble", value: "captions") {
                Form { CaptionSettings() }.formStyle(.grouped)
            }
            Tab("說話者", systemImage: "person.2", value: "speakers") {
                Form { SpeakerSettings() }.formStyle(.grouped)
            }
            Tab("AI", systemImage: "sparkles", value: "ai") {
                Form { AssistantSettings() }.formStyle(.grouped)
            }
        }
        .scenePadding()
        .frame(width: 500, height: 420)
    }
}

private struct GeneralSettings: View {
    @Environment(LiveSession.self) private var session
    @AppStorage(Pref.showMenuBarExtra) private var showMenuBarExtra = true

    var body: some View {
        @Bindable var session = session
        Section {
            Picker("音源", selection: $session.input) {
                Label("麥克風", systemImage: "mic").tag(LiveSession.Input.microphone)
                Label("Mac 聲音", systemImage: "speaker.wave.2").tag(LiveSession.Input.systemAudio)
            }
            .disabled(session.status.isActive)
        } footer: {
            Text("「Mac 聲音」會聽這台 Mac 播出的所有聲音，例如影片或線上會議。")
        }
        Section {
            LanguagePickers(session: session)
        }
        Section {
            RecordingToggle()
        }
        Section {
            Toggle("在選單列顯示 Instant", isOn: $showMenuBarExtra)
        }
    }
}
#else
/// iOS settings, from the gear in the navigation bar.
struct SettingsSheet: View {
    @Environment(LiveSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("語言") { LanguagePickers(session: session) }
                Section { RecordingToggle() }
                RecognitionSettings()
                CaptionSettings()
                SpeakerSettings()
                AssistantSettings()
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}
#endif

private struct RecordingToggle: View {
    @Environment(LiveSession.self) private var session

    var body: some View {
        Toggle(isOn: session.recordingEnabledBinding) {
            Text("錄音")
            Text("停止後可以邊聽錄音邊看字幕；按「儲存」才會留在紀錄裡，存在這台裝置上")
        }
        .disabled(session.status.isActive)
    }
}

/// Who recognizes speech: on-device, or a cloud service with the user's key.
private struct RecognitionSettings: View {
    @Environment(LiveSession.self) private var session
    @Environment(AppUI.self) private var ui
    @State private var key = ""

    var body: some View {
        let engine = session.engine
        Section {
            Picker("辨識引擎", selection: session.engineBinding) {
                Text("Apple（裝置上）").tag(SpeechEngine.apple)
                Text("Soniox（雲端）").tag(SpeechEngine.soniox)
                Text("ElevenLabs（雲端）").tag(SpeechEngine.elevenLabs)
            }
            .disabled(session.status.isActive)
        } header: {
            Text("語音辨識")
        } footer: {
            switch engine {
            case .apple: Text("在這台裝置上辨識，不需要網路，聲音不會離開裝置。")
            case .soniox: Text("聲音會即時上傳到 Soniox 辨識，說話者也由 Soniox 分辨。約 US$0.18／小時。")
            case .elevenLabs: Text("聲音會即時上傳到 ElevenLabs（Scribe v2 Realtime）辨識；說話者仍在這台裝置上分辨。約 US$0.39／小時。")
            }
        }
        if engine.isCloud {
            Section {
                if ui.speechKeySet[engine] == true {
                    LabeledContent("API key", value: "已設定")
                    Button("移除 API key", role: .destructive) { ui.setSpeechKey(nil, for: engine) }
                } else {
                    HStack {
                        SecureField("API key", text: $key, prompt: Text("貼上 API key"))
                            .onSubmit(save)
                        Button("儲存", action: save)
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Link("取得 API key", destination: engine == .soniox
                         ? URL(string: "https://console.soniox.com")!
                         : URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
                }
            } header: {
                Text(engine.name)
            } footer: {
                Text("API key 存在這台裝置的鑰匙圈裡。")
            }
            .onChange(of: engine) { key = "" }
        }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ui.setSpeechKey(trimmed, for: session.engine)
        key = ""
    }
}

/// Caption size, original text, and the floating captions (Mac).
private struct CaptionSettings: View {
    @AppStorage(Pref.captionPoints) private var captionPoints = CaptionMetrics.standard
    @AppStorage(Pref.showOriginal) private var showOriginal = true
    @AppStorage(Pref.overlayLines) private var overlayLines = 2
    @AppStorage(Pref.overlayTranslationOnly) private var overlayTranslationOnly = false

    var body: some View {
        Section {
            Slider(value: $captionPoints, in: CaptionMetrics.range, step: 1) {
                Text("字級")
            } minimumValueLabel: {
                Image(systemName: "textformat.size.smaller")
            } maximumValueLabel: {
                Image(systemName: "textformat.size.larger")
            }
            Toggle(isOn: $showOriginal) {
                Text("顯示原文")
                Text("在翻譯下方以小字顯示原文")
            }
        } header: {
            Text("字幕")
        } footer: {
            #if os(macOS)
            Text("也可以用 ⌘+、⌘− 調整，⌘0 回到標準大小。")
            #else
            Text("字幕也會跟著系統的文字大小縮放。")
            #endif
        }
        #if os(macOS)
        Section("浮動字幕") {
            Picker("行數", selection: $overlayLines) {
                Text("1 行").tag(1)
                Text("2 行").tag(2)
            }
            Toggle("只顯示翻譯", isOn: $overlayTranslationOnly)
        }
        #endif
    }
}

private struct SpeakerSettings: View {
    @Environment(LiveSession.self) private var session

    var body: some View {
        Section {
            Toggle(isOn: session.speakersEnabledBinding) {
                Text("區分說話者")
                Text(session.engine.diarizes ? "分辨最多 4 位說話者" : "用聲音分辨最多 4 位說話者，在這台裝置上處理")
            }
            .disabled(session.status.isActive)
        } header: {
            Text("說話者")
        } footer: {
            Text(session.status.isActive
                 ? "停止後才能切換。"
                 : session.engine.diarizes
                 ? "使用 Soniox 時由 Soniox 分辨說話者。"
                 : "第一次使用會下載約 \(LiveSession.speakerModelMegabytes) MB 的模型。")
        }
    }
}
