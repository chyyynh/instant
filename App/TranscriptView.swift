import InstantCore
import SwiftUI

/// Live captions, filling from the top like subtitles: new lines are added below and the view
/// follows them once it's full, unless the reader has scrolled back.
struct TranscriptView: View {
    @Environment(LiveSession.self) private var session
    @Environment(AppUI.self) private var ui
    @Environment(Assistant.self) private var assistant
    /// Translation size in points (already scaled for Dynamic Type on iOS).
    let points: Double
    let showOriginal: Bool
    @AppStorage(Pref.furigana) private var furiganaEnabled = true
    @AppStorage(Pref.originalFirst) private var originalFirst = false

    @State private var position = ScrollPosition(edge: .top)
    /// Whether to keep the newest line in view. Turned off only by the reader scrolling away from
    /// the bottom, back on when they return to it (or tap "最新").
    @State private var following = true
    @State private var readerScrolling = false
    /// Caption shown from the Claude panel, highlighted for a moment.
    @State private var highlighted: Int?

    /// Captions further back than this are dimmed, so the eye lands on the newest ones.
    private static let recentCount = 3

    var body: some View {
        let captions = session.captions
        let asked = askedAt
        let playing = playingIndex
        let openAssistant: @MainActor () -> Void = { [ui] in
            #if os(macOS)
            ui.inspectorShown = true
            #else
            ui.assistantShown = true
            #endif
        }
        let furigana = furiganaEnabled && Furigana.isAvailable
            && Furigana.applies(toLanguageCode: session.sourceLocale.language.languageCode?.identifier)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                // Captions never change once shown, so equal rows skip re-rendering. Caption ids
                // are their indices (append-only).
                ForEach(captions.indices, id: \.self) { index in
                    let line = captions[index]
                    CaptionRow(translation: line.translation ?? "", original: showOriginal ? line.source : nil, points: points,
                               asked: asked[index], furigana: furigana, originalFirst: originalFirst,
                               dimmed: index < captions.count - Self.recentCount && highlighted != index && playing != index && ui.player == nil,
                               openAssistant: openAssistant)
                        .equatable()
                        .background {
                            if highlighted == index || playing == index {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(.tint.opacity(0.15))
                                    .padding(-8)
                            }
                        }
                        .onTapGesture {
                            if let player = ui.player, !session.status.isActive { player.play(from: max(line.start - 0.3, 0)) }
                        }
                        .contextMenu {
                            if let player = ui.player, !session.status.isActive {
                                Button("從這裡播放", systemImage: "play") { player.play(from: max(line.start - 0.3, 0)) }
                            }
                            Button("拷貝", systemImage: "doc.on.doc") {
                                copy("\(line.translation ?? "")\n\(line.source)")
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .textSelection(.enabled)
            .scrollTargetLayout()
        }
        // Start at the top while there's room; once full, keep the newest line in view.
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollPosition($position)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onScrollPhaseChange { _, phase in
            readerScrolling = phase == .interacting || phase == .decelerating
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 32
        } action: { _, atBottom in
            // Content growing also moves the bottom away; only the reader's own scrolling unfollows.
            guard readerScrolling || atBottom, following != atBottom else { return }
            following = atBottom
            Trace.shared.event("ui.follow", ["following": atBottom])
        }
        // Glide when a caption is added.
        .onChange(of: captions.count) {
            guard following else { return }
            withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(edge: .bottom) }
        }
        // Keep the caption being played in view.
        .onChange(of: playing) {
            guard let playing, ui.player?.isPlaying == true else { return }
            following = false
            withAnimation(.easeOut(duration: 0.3)) { position.scrollTo(id: playing, anchor: .center) }
        }
        .onChange(of: points) {
            if following { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: ui.revealedCaption) {
            guard let index = ui.revealedCaption, captions.indices.contains(index) else { return }
            ui.revealedCaption = nil
            following = false
            withAnimation(.easeOut(duration: 0.3)) { position.scrollTo(id: index, anchor: .center) }
            highlighted = index
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { if highlighted == index { highlighted = nil } }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !following {
                Button("最新", systemImage: "arrow.down") { scrollToNewest() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .padding(16)
                    .transition(.opacity)
            }
        }
    }

    /// The caption at the playback position, once playback has begun.
    private var playingIndex: Int? {
        guard let player = ui.player, !session.status.isActive, player.isPlaying || player.currentTime > 0 else { return nil }
        return session.captions.lastIndex { $0.start <= player.currentTime + 0.05 }
    }

    /// The questions asked to Claude, by the last caption it had seen then.
    private var askedAt: [Int: String] {
        var asked: [Int: String] = [:]
        for message in assistant.messages where message.role == .user && message.captionCount > 0 {
            asked[message.captionCount - 1, default: ""] += asked[message.captionCount - 1] == nil ? message.text : "、\(message.text)"
        }
        return asked
    }

    private func scrollToNewest() {
        following = true
        withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(edge: .bottom) }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// A shown caption: translation and original, in the order the reader chose.
struct CaptionRow: View, Equatable {
    let translation: String
    let original: String?
    let points: Double
    /// Questions asked to Claude right after this caption.
    let asked: String?
    /// Set the original in Furifont, with readings over its kanji.
    var furigana = false
    /// The original large on top and the translation small below, for studying the language:
    /// the top line is where the eye goes first.
    var originalFirst = false
    /// An older caption: its top line fades so the eye lands on the newest. The line below is
    /// already secondary and stays as it is, so readings over kanji remain legible.
    var dimmed = false
    /// Opens the conversation with Claude, from the mark beside a caption that was asked about.
    var openAssistant: (@MainActor () -> Void)?

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.translation == b.translation && a.original == b.original && a.points == b.points && a.asked == b.asked
            && a.furigana == b.furigana && a.originalFirst == b.originalFirst && a.dimmed == b.dimmed
            && (a.openAssistant == nil) == (b.openAssistant == nil)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            text
            if let asked {
                Button {
                    openAssistant?()
                } label: {
                    Image(systemName: "sparkles")
                        .font(.callout)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .help("在這裡問了 Claude：\(asked)")
                .accessibilityLabel("在這裡問了 Claude：\(asked)")
                .disabled(openAssistant == nil)
            }
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let original, originalFirst {
                originalLine(original, primary: true)
                translationLine(primary: false)
            } else {
                translationLine(primary: true)
                if let original { originalLine(original, primary: false) }
            }
        }
        // Long lines are hard to follow back to the next one; keep them to a readable measure.
        .frame(maxWidth: CaptionMetrics.measure(points), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func translationLine(primary: Bool) -> some View {
        Text(translation)
            .font(primary ? CaptionMetrics.translationFont(points) : CaptionMetrics.originalFont(points))
            .foregroundStyle(primary ? HierarchicalShapeStyle.primary : .secondary)
            .opacity(primary && dimmed ? 0.55 : 1)
    }

    private func originalLine(_ original: String, primary: Bool) -> some View {
        let font = switch (furigana, primary) {
        case (true, true): CaptionMetrics.furiganaFont(points, weight: .medium)
        case (true, false): CaptionMetrics.furiganaFont((points * 0.75).rounded())
        case (false, true): CaptionMetrics.originalPrimaryFont(points)
        case (false, false): CaptionMetrics.originalFont(points)
        }
        return Text(original)
            .font(font)
            .foregroundStyle(primary ? HierarchicalShapeStyle.primary : .secondary)
            .opacity(primary && dimmed ? 0.55 : 1)
    }
}

/// Speech not yet captioned, in a glass card pinned under the captions: a level-driven waveform,
/// and the recognized Japanese as it changes.
struct LiveCard: View {
    @Environment(LiveSession.self) private var session
    let points: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TimelineView(.animation(minimumInterval: 0.1, paused: session.status != .running)) { _ in
                Image(systemName: "waveform", variableValue: Self.meterValue(session.audioLevel))
                    .symbolEffect(.variableColor.iterative, isActive: session.status == .running && session.pendingText.isEmpty)
                    .foregroundStyle(.green)
                    .accessibilityLabel("音量")
            }
            VStack(alignment: .leading, spacing: 2) {
                if session.pendingText.isEmpty {
                    Text("聆聽中…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(session.pendingText)
                }
            }
            .font(CaptionMetrics.originalFont(points))
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// Maps peak level (dBFS -60…0) to 0…1 so quiet speech still registers.
    static func meterValue(_ level: Float) -> Double {
        let dB = 20 * log10(max(Double(level), 1e-4))
        return min(max((dB + 60) / 60, 0), 1)
    }
}
