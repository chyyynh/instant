import InstantCore
import SwiftUI

/// Saved listenings: a list by day, and the selected one's captions with its recording.
struct LibraryView: View {
    @Environment(Library.self) private var library
    @State private var selection: SavedListening.ID?
    @State private var search = ""
    @State private var renaming: SavedListening?
    @State private var newTitle = ""
    @State private var deleting: SavedListening?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(days, id: \.day) { group in
                    Section(group.title) {
                        ForEach(group.listenings) { listening in
                            ListeningRow(listening: listening)
                                .tag(listening.id)
                                .contextMenu {
                                    Button("重新命名…", systemImage: "pencil") {
                                        newTitle = listening.title
                                        renaming = listening
                                    }
                                    Button("刪除", systemImage: "trash", role: .destructive) { deleting = listening }
                                }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "搜尋字幕或翻譯")
            .navigationTitle("聆聽紀錄")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            #endif
            .overlay {
                if library.listenings.isEmpty {
                    ContentUnavailableView("還沒有紀錄", systemImage: "clock",
                                           description: Text("停止聆聽後按「儲存」，就會出現在這裡。"))
                } else if days.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        } detail: {
            if let listening = library.listenings.first(where: { $0.id == selection }) {
                ListeningDetail(listening: listening)
                    .id(listening.id)
            } else {
                ContentUnavailableView("選一則紀錄", systemImage: "text.bubble")
            }
        }
        .onAppear {
            if selection == nil { selection = library.listenings.first?.id }
        }
        .alert("重新命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { listening in
            TextField("名稱", text: $newTitle)
            Button("取消", role: .cancel) {}
            Button("好") { library.rename(listening.id, to: newTitle.trimmingCharacters(in: .whitespaces)) }
        }
        .confirmationDialog("刪除「\(deleting?.title ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { listening in
            Button("刪除", role: .destructive) {
                if selection == listening.id { selection = nil }
                library.delete(listening.id)
            }
        } message: { listening in
            Text(listening.hasAudio ? "字幕和錄音都會刪除，無法復原。" : "字幕會刪除，無法復原。")
        }
    }

    /// Matching listenings grouped by day, newest first.
    private var days: [(day: Date, title: String, listenings: [SavedListening])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? library.listenings : library.listenings.filter { listening in
            listening.title.localizedCaseInsensitiveContains(query)
                || listening.captions.contains { $0.source.localizedCaseInsensitiveContains(query) || $0.translation.localizedCaseInsensitiveContains(query) }
        }
        let calendar = Calendar.current
        return Dictionary(grouping: matching) { calendar.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }
            .map { day, listenings in
                let title = calendar.isDateInToday(day) ? "今天"
                    : calendar.isDateInYesterday(day) ? "昨天"
                    : day.formatted(.dateTime.month().day().weekday())
                return (day, title, listenings)
            }
    }
}

private struct ListeningRow: View {
    let listening: SavedListening

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(listening.title)
                .lineLimit(1)
            Text("\(listening.date.formatted(date: .omitted, time: .shortened)) · \(PlaybackBar.format(listening.duration))\(listening.hasAudio ? "" : " · 只有字幕")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// One saved listening: its captions (tap one to play from there) and the conversation with Claude.
private struct ListeningDetail: View {
    @Environment(Library.self) private var library
    @AppStorage(Pref.captionPoints) private var captionPoints = CaptionMetrics.standard
    @AppStorage(Pref.showOriginal) private var showOriginal = true
    let listening: SavedListening
    @State private var player: Player?

    var body: some View {
        let playing = player.flatMap { player in
            player.isPlaying || player.currentTime > 0 ? listening.captions.lastIndex { $0.start <= player.currentTime + 0.05 } : nil
        }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(listening.captions.indices, id: \.self) { index in
                        let caption = listening.captions[index]
                        let newSpeaker = caption.speaker != nil && (index == 0 || listening.captions[index - 1].speaker != caption.speaker)
                        CaptionRow(translation: caption.translation, original: showOriginal ? caption.source : nil, points: captionPoints,
                                   speaker: newSpeaker ? caption.speaker.map { CaptionRow.Speaker(name: $0, color: LiveSession.speakerColors[caption.color ?? 0]) } : nil,
                                   asked: nil)
                            .equatable()
                            .background {
                                if playing == index {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(.tint.opacity(0.15))
                                        .padding(-8)
                                }
                            }
                            .contentShape(.rect)
                            .onTapGesture { player?.play(from: max(caption.start - 0.3, 0)) }
                            .id(index)
                    }
                    if !listening.conversation.isEmpty {
                        ConversationSection(messages: listening.conversation)
                            .padding(.top, 20)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
            .onChange(of: playing) {
                guard let playing, player?.isPlaying == true else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(playing, anchor: .center) }
            }
        }
        .navigationTitle(listening.title)
        #if os(macOS)
        .navigationSubtitle("\(listening.date.formatted(date: .abbreviated, time: .shortened)) · \(listening.input) · \(PlaybackBar.format(listening.duration))\(listening.speakerCount > 0 ? " · \(listening.speakerCount) 位說話者" : "")")
        #endif
        .safeAreaBar(edge: .bottom) {
            if let player {
                PlaybackBar(player: player, segments: PlaybackBar.Segment.runs(listening.captions.map { ($0.start, $0.end, $0.color) }))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    ShareLink(item: listening.transcriptText, subject: Text(listening.title)) {
                        Label("字幕與翻譯", systemImage: "doc.plaintext")
                    }
                    if listening.hasAudio {
                        ShareLink(item: library.audioURL(listening), subject: Text(listening.title)) {
                            Label("錄音", systemImage: "waveform")
                        }
                    }
                } label: {
                    Label("匯出", systemImage: "square.and.arrow.up")
                }
            }
        }
        .onAppear {
            if listening.hasAudio { player = Player(url: library.audioURL(listening)) }
        }
        .onDisappear { player?.stop() }
    }
}

private struct ConversationSection: View {
    let messages: [SavedListening.Message]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("和 Claude 的對話", systemImage: "sparkles")
                .font(.headline)
            ForEach(messages.indices, id: \.self) { index in
                let message = messages[index]
                if message.fromUser {
                    Text(message.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.tint.opacity(0.2), in: .rect(cornerRadius: 14))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text(LocalizedStringKey(message.text))
                        .textSelection(.enabled)
                }
            }
        }
    }
}
