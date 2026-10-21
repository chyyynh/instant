#if os(macOS)
import InstantCore
import SwiftUI

/// Every action in the windows, in the menu bar with its shortcut: a 字幕 menu, and caption
/// display commands in the View menu.
struct InstantCommands: Commands {
    let session: LiveSession
    let ui: AppUI
    let assistant: Assistant
    @AppStorage(Pref.captionPoints) private var captionPoints = CaptionMetrics.standard
    @AppStorage(Pref.showOriginal) private var showOriginal = true
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("字幕") {
            Button(transportTitle) {
                switch session.status {
                case .running: Task { await session.stop() }
                case .preparing: session.cancelStart()
                case .idle, .failed: ui.start(session)
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(ui.composerFocused) // Space belongs to the text field then
            Divider()
            Toggle("麥克風", isOn: input(.microphone))
                .keyboardShortcut("1")
                .disabled(session.status.isActive)
            Toggle("Mac 聲音", isOn: input(.systemAudio))
                .keyboardShortcut("2")
                .disabled(session.status.isActive)
            Divider()
            Button("清除字幕") { ui.clear(session) }
                .keyboardShortcut("k")
                .disabled(session.status.isActive || session.captions.isEmpty)
            Divider()
            Button("儲存這次聆聽…") { ui.savingShown = true }
                .keyboardShortcut("s")
                .disabled(session.status.isActive || session.captions.isEmpty || ui.savedListening != nil)
            Button("聆聽紀錄") { openWindow(id: WindowID.library) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Button("放大字幕") { captionPoints = min(captionPoints + CaptionMetrics.step, CaptionMetrics.range.upperBound) }
                .keyboardShortcut("+")
                .disabled(captionPoints >= CaptionMetrics.range.upperBound)
            Button("縮小字幕") { captionPoints = max(captionPoints - CaptionMetrics.step, CaptionMetrics.range.lowerBound) }
                .keyboardShortcut("-")
                .disabled(captionPoints <= CaptionMetrics.range.lowerBound)
            Button("實際大小") { captionPoints = CaptionMetrics.standard }
                .keyboardShortcut("0")
                .disabled(captionPoints == CaptionMetrics.standard)
            Divider()
            Toggle("顯示原文", isOn: $showOriginal)
                .keyboardShortcut("o", modifiers: [.command, .option])
            Toggle("浮動字幕", isOn: Binding(get: { ui.overlayShown }, set: { ui.overlayShown = $0 }))
                .keyboardShortcut("f", modifiers: [.command, .option])
            Toggle("和 Claude 討論", isOn: Binding(get: { ui.inspectorShown }, set: { ui.inspectorShown = $0 }))
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("新的 Claude 對話") { assistant.reset() }
                .disabled(assistant.messages.isEmpty)
            Divider()
        }
    }

    private var transportTitle: String {
        switch session.status {
        case .running: "停止聆聽"
        case .preparing: "取消開始"
        case .idle, .failed: "開始聆聽"
        }
    }

    private func input(_ input: LiveSession.Input) -> Binding<Bool> {
        Binding(get: { session.input == input }, set: { if $0 { session.input = input } })
    }
}
#endif
