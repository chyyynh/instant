import InstantCore
import SwiftUI

#if os(macOS)
/// ⌘, : the standard Settings window, one grouped form per tab.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("一般", systemImage: "gearshape") {
                Form { GeneralSettings() }.formStyle(.grouped)
            }
            Tab("字幕", systemImage: "captions.bubble") {
                Form { CaptionSettings() }.formStyle(.grouped)
            }
            Tab("說話者", systemImage: "person.2") {
                Form { SpeakerSettings() }.formStyle(.grouped)
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
                CaptionSettings()
                SpeakerSettings()
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
                Text("用聲音分辨最多 4 位說話者，在這台裝置上處理")
            }
            .disabled(session.status.isActive)
        } header: {
            Text("說話者")
        } footer: {
            Text(session.status.isActive
                 ? "停止後才能切換。"
                 : "第一次使用會下載約 \(LiveSession.speakerModelMegabytes) MB 的模型。")
        }
    }
}
