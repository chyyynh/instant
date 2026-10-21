import InstantCore
import SwiftUI

/// Play / pause, position, and a scrubber showing where there was speech.
struct PlaybackBar: View {
    struct Segment: Equatable {
        let start: TimeInterval
        let end: TimeInterval
    }

    let player: Player
    let segments: [Segment]

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel(player.isPlaying ? "暫停" : "播放")
            Text(Self.format(player.currentTime))
                .monospacedDigit()
            Scrubber(player: player, segments: segments)
            Text(Self.format(player.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Menu {
                Picker("速度", selection: Bindable(player).rate) {
                    ForEach(Player.rates, id: \.self) { rate in
                        Text(Self.format(rate: rate)).tag(rate)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(Self.format(rate: player.rate))
                    .monospacedDigit()
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("播放速度")
        }
        .font(.callout)
    }

    static func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    static func format(rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate.formatted())×"
    }
}

/// The recording's length as a track: where there was speech, and a playhead to drag.
private struct Scrubber: View {
    let player: Player
    let segments: [PlaybackBar.Segment]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(player.duration, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                    .frame(height: 6)
                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    let x = width * segment.start / duration
                    Rectangle()
                        .fill(.tint)
                        .frame(width: max(width * (segment.end - segment.start) / duration - 1, 1), height: 6)
                        .offset(x: x)
                }
                Capsule()
                    .fill(.primary)
                    .frame(width: 3, height: 20)
                    .offset(x: min(max(width * player.currentTime / duration - 1.5, 0), width - 3))
            }
            .frame(maxHeight: .infinity)
            .clipShape(.rect)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                player.seek(to: duration * drag.location.x / max(width, 1))
            })
        }
        .frame(height: 24)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1)) {
                Text("播放位置")
            }
        }
    }
}

extension PlaybackBar.Segment {
    /// Runs of captions less than 3s apart.
    static func runs(_ captions: [(start: TimeInterval, end: TimeInterval)]) -> [Self] {
        var runs: [Self] = []
        for caption in captions where caption.end > caption.start {
            if let last = runs.last, caption.start - last.end < 3 {
                runs[runs.count - 1] = Self(start: last.start, end: max(last.end, caption.end))
            } else {
                runs.append(Self(start: caption.start, end: caption.end))
            }
        }
        return runs
    }
}

/// After stopping, in place of the live card: playback of what was just heard, and saving it.
struct RecordingCard: View {
    @Environment(LiveSession.self) private var session
    @Environment(AppUI.self) private var ui
    @Environment(Library.self) private var library
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    let player: Player
    @State private var discarding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlaybackBar(player: player, segments: PlaybackBar.Segment.runs(session.captions.map { ($0.start, $0.end) }))
            HStack(spacing: 8) {
                if let saved = library.listenings.first(where: { $0.id == ui.savedListening }) {
                    Label("已儲存為「\(saved.title)」", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("打開紀錄") { openLibrary() }
                } else {
                    Text("點字幕可以從那句播放。這段錄音還沒儲存。")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("捨棄", role: .destructive) { discarding = true }
                    Button("儲存…") { ui.savingShown = true }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s")
                }
            }
            .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .confirmationDialog("捨棄這段錄音？", isPresented: $discarding) {
            Button("捨棄錄音", role: .destructive) {
                player.stop()
                session.discardRecording()
            }
        } message: {
            Text("字幕會留在畫面上，但不能再回放。")
        }
    }

    private func openLibrary() {
        #if os(macOS)
        openWindow(id: WindowID.library)
        #else
        ui.libraryShown = true
        #endif
    }
}

/// Names the listening and picks what to keep.
struct SaveListeningSheet: View {
    @Environment(LiveSession.self) private var session
    @Environment(AppUI.self) private var ui
    @Environment(Library.self) private var library
    @Environment(Assistant.self) private var assistant
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var keepAudio = true
    @State private var keepConversation = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名稱", text: $title)
                } footer: {
                    Text(summary)
                }
                Section("要保存") {
                    LabeledContent("字幕與翻譯", value: "含時間")
                    if let recording = session.recording {
                        Toggle(isOn: $keepAudio) {
                            Text("錄音")
                            Text("AAC · 約 \(max(1, Int((recording.duration * 6_000 / 1_000_000).rounded()))) MB")
                        }
                    }
                    Toggle(isOn: Binding(get: { keepConversation && !assistant.messages.isEmpty }, set: { keepConversation = $0 })) {
                        Text("和 Claude 的對話")
                        Text(assistant.messages.isEmpty ? "沒有對話" : "\(assistant.messages.count / 2) 則問答")
                    }
                    .disabled(assistant.messages.isEmpty)
                }
                Section {
                } footer: {
                    Label("存在這台裝置的 Instant 紀錄裡，不會上傳。錄別人說話前，請先取得對方同意。", systemImage: "lock")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("儲存這次聆聽")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        ui.afterSave = nil
                        dismiss()
                    }
                }
                if let action = ui.afterSave {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("不儲存", role: .destructive) {
                            ui.afterSave = nil
                            dismiss()
                            ui.perform(action, session)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 400)
        #endif
        .onAppear {
            if title.isEmpty { title = defaultTitle }
        }
    }

    /// "12 分 48 秒 · 41 句字幕"
    private var summary: String {
        let duration = Duration.seconds((session.recording?.duration ?? session.captions.last?.end ?? 0).rounded(.down))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
        return "\(duration) · \(session.captions.count) 句字幕"
    }

    private var defaultTitle: String {
        let date = session.recording?.started ?? .now
        return "\(date.formatted(.dateTime.month().day().hour().minute())) 的聆聽"
    }

    private func save() {
        do {
            let saved = try library.save(session, title: title.trimmingCharacters(in: .whitespaces),
                                         audio: keepAudio, conversation: keepConversation ? assistant.messages : [])
            ui.savedListening = saved.id
            dismiss()
            if let action = ui.afterSave {
                ui.afterSave = nil
                ui.perform(action, session)
            }
        } catch {
            self.error = "沒辦法儲存：\(error.localizedDescription)"
        }
    }
}

extension View {
    /// Asks before starting over (or clearing) drops a recording that isn't saved.
    func unsavedRecordingDialog() -> some View {
        modifier(UnsavedRecordingDialog())
    }
}

private struct UnsavedRecordingDialog: ViewModifier {
    @Environment(LiveSession.self) private var session
    @Environment(AppUI.self) private var ui

    func body(content: Content) -> some View {
        @Bindable var ui = ui
        content
            .confirmationDialog("要先儲存剛才的聆聽嗎？", isPresented: Binding(get: { ui.unsavedAction != nil }, set: { if !$0 { ui.unsavedAction = nil } }),
                                presenting: ui.unsavedAction) { action in
                Button("儲存…") {
                    ui.afterSave = action
                    ui.savingShown = true
                }
                Button(action == .start ? "不儲存，開始新的聆聽" : "不儲存，清除字幕", role: .destructive) {
                    ui.perform(action, session)
                }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("沒儲存的話，錄音和字幕都不會留下。")
            }
            .sheet(isPresented: $ui.savingShown) { SaveListeningSheet() }
    }
}
