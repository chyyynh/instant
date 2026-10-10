import InstantCore
import SwiftUI

/// Caption size, chosen from the toolbar's Aa menu.
enum CaptionSize: String, CaseIterable, Identifiable {
    case small, medium, large, extraLarge

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .small: "小"
        case .medium: "中"
        case .large: "大"
        case .extraLarge: "特大"
        }
    }

    /// Point sizes for the translation and the original underneath it.
    var translation: CGFloat { [.small: 17, .medium: 21, .large: 26, .extraLarge: 32][self]! }
    var original: CGFloat { [.small: 12, .medium: 14, .large: 16, .extraLarge: 19][self]! }
}

/// Live captions, filling from the top like subtitles: new lines are added below and the view
/// follows them once it's full, unless the reader has scrolled back.
struct TranscriptView: View {
    let transcript: Transcript
    let isListening: Bool
    let size: CaptionSize

    var body: some View {
        if transcript.lines.isEmpty, transcript.volatile.isEmpty {
            ContentUnavailableView {
                Label(isListening ? "聆聽中…" : "按「開始」", systemImage: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: isListening)
            } description: {
                Text(isListening ? "有人說話時，字幕會從這裡開始出現。" : "Instant 會即時辨識聽到的話並翻譯成字幕。")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: size.translation * 0.9) {
                    ForEach(transcript.lines) { line in
                        CaptionView(translation: line.translation ?? line.interimTranslation, original: line.source,
                                    state: line.translation == nil ? .interim : line.isFinal ? .final : .provisional,
                                    size: size)
                    }
                    if !transcript.volatile.isEmpty {
                        CaptionView(translation: transcript.draftTranslation, original: transcript.volatile,
                                    state: .live, size: size)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .textSelection(.enabled)
            }
            // Start at the top while there's room; once full, stay pinned to the newest line.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }
}

private struct CaptionView: View {
    enum State {
        case final, provisional
        /// Finished speaking; showing its draft until the line's own translation arrives.
        case interim
        case live
    }

    let translation: String?
    let original: String
    let state: State
    let size: CaptionSize

    var body: some View {
        VStack(alignment: .leading, spacing: size.original * 0.35) {
            translationText
                .font(.system(size: size.translation, weight: .semibold))
                .lineSpacing(size.translation * 0.15)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if state == .live {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative)
                        .foregroundStyle(.green)
                }
                Text(original)
                    .foregroundStyle(state == .live ? .primary : .secondary)
            }
            .font(.system(size: size.original))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var translationText: some View {
        switch state {
        case .final:
            Text(translation ?? "…").foregroundStyle(translation == nil ? .tertiary : .primary)
        case .provisional:
            Text(translation ?? "…").foregroundStyle(.primary.opacity(0.85))
        case .interim:
            Text(translation ?? "…").foregroundStyle(.secondary)
        case .live:
            // Speech still in progress: no translation yet (unless drafts are enabled).
            if let translation {
                Text(translation).foregroundStyle(.secondary)
            }
        }
    }
}

/// Bottom bar: where audio comes from and whether any is arriving.
struct StatusBar: View {
    let session: LiveSession

    var body: some View {
        HStack(spacing: 12) {
            Label(session.status.isActive ? session.sourceDescription : (session.input == .microphone ? "麥克風" : "Mac 聲音"),
                  systemImage: session.input == .microphone ? "mic" : "speaker.wave.2")
            TimelineView(.animation(minimumInterval: 0.08, paused: session.status != .running)) { _ in
                LevelMeterView(level: session.status == .running ? session.audioLevel : 0)
            }
            Spacer()
            Label("裝置上處理", systemImage: "lock")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct LevelMeterView: View {
    let level: Float

    var body: some View {
        // Map dBFS (-60…0) to the bar width so quiet speech still registers.
        let dB = 20 * log10(max(Double(level), 1e-4))
        let fill = min(max((dB + 60) / 60, 0), 1)
        Capsule()
            .fill(.quaternary)
            .frame(width: 72, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(.green).frame(width: 72 * fill, height: 4)
            }
            .animation(.linear(duration: 0.08), value: fill)
            .accessibilityLabel("音量")
    }
}
