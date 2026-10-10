import InstantCore
import SwiftUI

/// The speakers heard so far: color, name, how much each has said, who's speaking now.
struct SpeakerInspector: View {
    @Environment(LiveSession.self) private var session
    @Environment(AppUI.self) private var ui

    var body: some View {
        let speakers = session.speakers
        let counts = session.lineCounts
        // Who's speaking changes every 80ms and isn't observed; poll it while listening.
        TimelineView(.periodic(from: .now, by: 0.3)) { _ in
            let speaking = Set(session.speakingNow)
            List {
                Section {
                    if speakers.isEmpty {
                        Text(session.speakerDiarizationEnabled ? "有人說話後會列在這裡。" : "「區分說話者」已關閉。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(speakers) { speaker in
                        row(speaker,
                            count: speaker.slots.reduce(0) { $0 + counts[$1, default: 0] },
                            speaking: !speaking.isDisjoint(with: speaker.slots))
                    }
                    // A row rather than a footer: list footers don't wrap on the Mac.
                    Text("最多分辨 4 個人，依出場順序叫 A、B、C。取同一個名字會合併成一人。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("說話者")
                }

                Section {
                    Toggle("區分說話者", isOn: session.speakersEnabledBinding)
                        .toggleStyle(.switch)
                        .disabled(session.status.isActive)
                } footer: {
                    Text(session.status.isActive
                         ? "停止後才能切換。"
                         : "第一次使用會下載約 \(LiveSession.speakerModelMegabytes) MB 的模型。")
                }
            }
        }
    }

    private func row(_ speaker: Speaker, count: Int, speaking: Bool) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(speaker.name)
                    Text("\(count) 句")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(speaker.color)
                    .imageScale(.small)
            }
            Spacer()
            if speaking {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative)
                    .foregroundStyle(.green)
                    .accessibilityLabel("正在說話")
            }
            Button("重新命名", systemImage: "pencil") { ui.rename(speaker.id, in: session) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .contextMenu {
            Button("重新命名「\(speaker.name)」…", systemImage: "pencil") { ui.rename(speaker.id, in: session) }
        }
    }
}
