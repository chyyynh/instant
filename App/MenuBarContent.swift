#if os(macOS)
import AppKit
import InstantCore
import SwiftUI

/// The menu bar window: start or stop, where audio comes from, the languages, floating captions.
struct MenuBarContent: View {
    @Environment(LiveSession.self) private var session
    @Environment(AppUI.self) private var ui
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.red, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text("即時翻譯").fontWeight(.semibold)
                    status
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("即時翻譯", isOn: listening)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled({ if case .preparing = session.status { true } else { false } }())
            }

            Picker("音源", selection: $session.input) {
                Text("麥克風").tag(LiveSession.Input.microphone)
                Text("Mac 聲音").tag(LiveSession.Input.systemAudio)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(session.status.isActive)

            Form {
                LanguagePickers(session: session)
                Toggle("浮動字幕", isOn: overlay)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, -20)
            .padding(.vertical, -16)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Button("打開 Instant") {
                    openWindow(id: WindowID.main)
                    NSApp.activate()
                }
                SettingsLink { Text("設定…") }
                Button("結束 Instant") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
        }
        .padding(14)
        .frame(width: 300)
        .onChange(of: session.translationDownload != nil) { _, needed in
            if needed { openWindow(id: WindowID.main) }
        }
    }

    private var status: Text {
        switch session.status {
        case .running:
            session.startedAt.map { Text("聆聽中 · \(Text($0, style: .timer).monospacedDigit())") } ?? Text("聆聽中")
        case .preparing(let message): Text(message)
        case .failed(let message): Text(message)
        case .idle: Text("\(session.inputName) · 裝置上處理")
        }
    }

    private var listening: Binding<Bool> {
        Binding(get: { session.status.isActive },
                set: { on in if on { ui.start(session) } else { Task { await session.stop() } } })
    }

    private var overlay: Binding<Bool> {
        Binding(get: { ui.overlayShown }, set: { ui.overlayShown = $0 })
    }
}

/// The menu bar icon: a waveform that moves while listening.
struct MenuBarLabel: View {
    @Environment(LiveSession.self) private var session

    var body: some View {
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative, isActive: session.status == .running)
            .accessibilityLabel(session.status == .running ? "Instant：聆聽中" : "Instant")
    }
}
#endif
