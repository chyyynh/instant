#if os(macOS)
import InstantCore
import SwiftUI

/// Every action in the windows, in the menu bar with its shortcut: a 字幕 menu, and caption
/// display commands in the View menu.
struct InstantCommands: Commands {
    let session: LiveSession
    let ui: AppUI
    @AppStorage(Pref.captionPoints) private var captionPoints = CaptionMetrics.standard
    @AppStorage(Pref.showOriginal) private var showOriginal = true

    var body: some Commands {
        CommandMenu("字幕") {
            Button(transportTitle) {
                switch session.status {
                case .running: Task { await session.stop() }
                case .preparing: session.cancelStart()
                case .idle, .failed: Task { await session.start() }
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(ui.renamingSpeaker != nil) // Space belongs to the name field then
            Divider()
            Toggle("麥克風", isOn: input(.microphone))
                .keyboardShortcut("1")
                .disabled(session.status.isActive)
            Toggle("Mac 聲音", isOn: input(.systemAudio))
                .keyboardShortcut("2")
                .disabled(session.status.isActive)
            Divider()
            Toggle("區分說話者", isOn: session.speakersEnabledBinding)
                .disabled(session.status.isActive)
            Divider()
            Button("清除字幕") { session.clear() }
                .keyboardShortcut("k")
                .disabled(session.status.isActive || session.captions.isEmpty)
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
            Toggle("說話者檢閱器", isOn: Binding(get: { ui.inspectorShown }, set: { ui.inspectorShown = $0 }))
                .keyboardShortcut("i", modifiers: [.command, .option])
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
