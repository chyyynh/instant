import InstantCore
import SwiftUI

struct TranscriptView: View {
    let transcript: Transcript
    let isListening: Bool

    var body: some View {
        if transcript.lines.isEmpty, transcript.volatile.isEmpty {
            ContentUnavailableView {
                Label(isListening ? "聆聽中…" : "按「開始」", systemImage: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: isListening)
            } description: {
                Text(isListening ? "有人說話時，原文和翻譯會出現在這裡。" : "Instant 會即時辨識你聽到的話並翻譯。")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(transcript.lines) { line in
                        LineView(translation: line.translation, source: line.source, isProvisional: !line.isFinal)
                    }
                    if !transcript.volatile.isEmpty {
                        LiveLineView(draft: transcript.draftTranslation, source: transcript.volatile)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
        }
    }
}

private struct LineView: View {
    let translation: String?
    let source: String
    let isProvisional: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(translation ?? "翻譯中…")
                .font(.title3)
                .foregroundStyle(translation == nil ? .tertiary : .primary)
            Text(source)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .opacity(isProvisional ? 0.85 : 1)
        .animation(.default, value: translation)
    }
}

/// The sentence still being spoken: recognized text so far plus a rough translation.
private struct LiveLineView: View {
    let draft: String?
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let draft {
                Text(draft)
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative)
                    .foregroundStyle(.tint)
                Text(source)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
