import InstantCore
import SwiftUI

/// Caption size from the Aa menu (and ⌘+ / ⌘− on the Mac). On iOS it's applied as a Dynamic Type
/// size, so captions also respect the system text size; macOS text styles don't scale with
/// Dynamic Type, so there it picks point sizes, like Mail and Messages do.
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

    #if os(macOS)
    var translationFont: Font { .system(size: [.small: 17, .medium: 21, .large: 26, .extraLarge: 32][self]!, weight: .semibold) }
    var originalFont: Font { .system(size: [.small: 12, .medium: 14, .large: 17, .extraLarge: 20][self]!) }
    #else
    var translationFont: Font { .title2.weight(.semibold) }
    var originalFont: Font { .callout }
    #endif

    var larger: CaptionSize? { Self.allCases.firstIndex(of: self).flatMap { Self.allCases.indices.contains($0 + 1) ? Self.allCases[$0 + 1] : nil } }
    var smaller: CaptionSize? { Self.allCases.firstIndex(of: self).flatMap { $0 > 0 ? Self.allCases[$0 - 1] : nil } }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: .medium
        case .medium: .xLarge
        case .large: .xxxLarge
        case .extraLarge: .accessibility2
        }
    }
}

/// Live captions, filling from the top like subtitles: new lines are added below and the view
/// follows them once it's full, unless the reader has scrolled back.
struct TranscriptView: View {
    let captions: [Line]
    let pendingText: String
    let draftTranslation: String?
    let isListening: Bool
    let size: CaptionSize

    @State private var position = ScrollPosition(edge: .top)
    /// Whether to keep the newest line in view. Turned off only by the reader scrolling away from
    /// the bottom, back on when they return to it (or tap "最新").
    @State private var following = true
    @State private var readerScrolling = false

    var body: some View {
        if captions.isEmpty, pendingText.isEmpty {
            ContentUnavailableView {
                Label(isListening ? "聆聽中…" : "按「開始」", systemImage: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: isListening)
            } description: {
                Text(isListening ? "有人說話時，字幕會從這裡開始出現。" : "Instant 會即時辨識聽到的話並翻譯成字幕。")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // Captions never change once shown, so equal rows skip re-rendering.
                    ForEach(captions) { line in
                        CaptionRow(translation: line.translation ?? "", original: line.source, size: size)
                            .equatable()
                    }
                    if !pendingText.isEmpty {
                        LiveRow(original: pendingText, draft: draftTranslation, size: size)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .textSelection(.enabled)
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
            // Glide when a caption is added; snap while the live text grows, so nothing wobbles.
            .onChange(of: captions.count) {
                guard following else { return }
                withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(edge: .bottom) }
            }
            .onChange(of: pendingText) {
                guard following else { return }
                position.scrollTo(edge: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if !following {
                    Button("最新", systemImage: "arrow.down") {
                        following = true
                        withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(edge: .bottom) }
                    }
                    .buttonStyle(.glass)
                    .padding(16)
                    .transition(.opacity)
                }
            }
        }
    }
}

/// A shown caption: translation, with the original underneath.
private struct CaptionRow: View, Equatable {
    let translation: String
    let original: String
    let size: CaptionSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(translation)
                .font(size.translationFont)
            Text(original)
                .font(size.originalFont)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Speech not yet captioned: the recognized Japanese, still changing.
private struct LiveRow: View {
    let original: String
    let draft: String?
    let size: CaptionSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let draft {
                Text(draft)
                    .font(size.translationFont)
                    .foregroundStyle(.secondary)
            }
            Label {
                Text(original)
            } icon: {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative)
                    .foregroundStyle(.green)
            }
            .font(size.originalFont)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Gauge(value: session.status == .running ? Self.meterValue(session.audioLevel) : 0) {
                    Text("音量")
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(.green)
                .frame(width: 72)
                .labelsHidden()
            }
            Spacer()
            Label("裝置上處理", systemImage: "lock")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Maps peak level (dBFS -60…0) to 0…1 so quiet speech still registers.
    private static func meterValue(_ level: Float) -> Double {
        let dB = 20 * log10(max(Double(level), 1e-4))
        return min(max((dB + 60) / 60, 0), 1)
    }
}
