#if os(macOS)
import AppKit
import InstantCore
import SwiftUI

/// Floating captions over every app: the previous line dimmed, then the current one. A
/// non-activating panel (SwiftUI's Window scene can't be one), so clicking it never takes focus
/// from the app you're watching; it floats on every Space and over full-screen apps.
@MainActor
final class OverlayPanel {
    private var panel: NSPanel?

    func show(session: LiveSession, ui: AppUI) {
        if panel == nil { panel = makePanel(session: session, ui: ui) }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(session: LiveSession, ui: AppUI) -> NSPanel {
        let hosting = NSHostingView(rootView: OverlayView().environment(session).environment(ui))
        hosting.sizingOptions = [.minSize]
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 150),
                            styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier(WindowID.overlay)
        panel.title = "浮動字幕"
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Bottom center, clear of the Dock, like subtitles; then wherever the user leaves it.
        if !panel.setFrameUsingName("overlay"), let screen = NSScreen.main?.visibleFrame {
            let size = NSSize(width: 640, height: max(hosting.fittingSize.height, 120))
            panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + 60, width: size.width, height: size.height), display: false)
        }
        panel.setFrameAutosaveName("overlay")
        return panel
    }
}

private struct OverlayView: View {
    @Environment(LiveSession.self) private var session
    @Environment(AppUI.self) private var ui
    @AppStorage(Pref.captionPoints) private var captionPoints = CaptionMetrics.standard
    @AppStorage(Pref.showOriginal) private var showOriginal = true
    @AppStorage(Pref.overlayLines) private var overlayLines = 2
    @AppStorage(Pref.overlayTranslationOnly) private var translationOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            captions
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)
        // Rounded like the system's Live Captions panel; the panel itself is clear.
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(session.languageTitle)
            Spacer()
            Button {
                if session.status.isActive { Task { await session.stop() } } else { ui.start(session) }
            } label: {
                Label(session.status.isActive ? "停止" : "開始", systemImage: session.status.isActive ? "pause.fill" : "play.fill")
            }
            .help(session.status.isActive ? "停止聆聽" : "開始聆聽")
            InputMenu()
                .menuIndicator(.hidden)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var captions: some View {
        let points = captionPoints
        let original = showOriginal && !translationOnly
        let captions = session.captions
        if session.pendingText.isEmpty, let current = captions.last {
            // Nothing in progress: the last caption is the current line.
            if overlayLines > 1, captions.count > 1 {
                previous(captions[captions.count - 2])
            }
            Text(current.translation ?? "")
                .font(CaptionMetrics.translationFont(points))
            if original {
                Text(current.source)
                    .font(CaptionMetrics.originalFont(points))
                    .foregroundStyle(.secondary)
            }
        } else if !session.pendingText.isEmpty {
            // Someone is speaking: the last caption above, the draft (dimmed) and the Japanese.
            if overlayLines > 1, let last = captions.last {
                previous(last)
            }
            if let draft = session.draftTranslation {
                Text(draft)
                    .font(.system(size: points, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if original {
                Text(session.pendingText)
                    .font(CaptionMetrics.originalFont(points))
            }
        } else {
            Text(session.status.isActive ? "聆聽中…" : "按 ▶︎ 開始即時翻譯")
                .font(CaptionMetrics.originalFont(points))
                .foregroundStyle(.secondary)
        }
    }

    private func previous(_ line: Line) -> some View {
        Text(line.translation ?? "")
            .font(.system(size: (captionPoints * 0.72).rounded()))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

#endif
