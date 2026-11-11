#if os(macOS)
import AppKit
import InstantCore
import SwiftUI

/// Floating captions over every app, the main window's other way of showing the session (only
/// one of them is on screen). A non-activating panel (SwiftUI's Window scene can't be one), so
/// clicking it never takes focus from the app you're watching; it floats on every Space and over
/// full-screen apps.
@MainActor
final class OverlayPanel {
    private var panel: NSPanel?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    func show(session: LiveSession, ui: AppUI) {
        if panel == nil { panel = makePanel(session: session, ui: ui) }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Moves the panel with the mouse. The SwiftUI content covers the whole panel, so AppKit's
    /// move-by-background never sees the drag.
    func drag(ended: Bool) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if ended {
            dragStart = nil
            return
        }
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    /// Sets the height, keeping the bottom edge where it is (captions grow upward, like subtitles).
    func setHeight(_ height: CGFloat) {
        guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
    }

    private func makePanel(session: LiveSession, ui: AppUI) -> NSPanel {
        let hosting = NSHostingView(rootView: OverlayView(panel: self).environment(session).environment(ui))
        hosting.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 200),
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.minSize = NSSize(width: 360, height: 80)
        // Bottom center, clear of the Dock, like subtitles; then wherever the user leaves it.
        if !panel.setFrameUsingName("overlay"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.midX - 340, y: screen.minY + 60, width: 680, height: 200), display: false)
        }
        panel.setFrameAutosaveName("overlay")
        return panel
    }
}

private struct OverlayView: View {
    let panel: OverlayPanel
    @Environment(LiveSession.self) private var session
    @Environment(AppUI.self) private var ui
    @AppStorage(Pref.captionPoints) private var captionPoints = CaptionMetrics.standard
    @AppStorage(Pref.showOriginal) private var showOriginal = true
    @AppStorage(Pref.overlayLines) private var overlayLines = 2
    @AppStorage(Pref.overlayTranslationOnly) private var translationOnly = false

    private var original: Bool { showOriginal && !translationOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            captions
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Rounded like the system's Live Captions panel; the panel itself is clear.
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
        .contentShape(.rect(cornerRadius: 18))
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { _ in panel.drag(ended: false) }
            .onEnded { _ in panel.drag(ended: true) })
        // The panel keeps a fixed height for the chosen number of lines, so it doesn't jump as
        // lines come and go; the card sits at its bottom.
        .frame(maxHeight: .infinity, alignment: .bottom)
        .onChange(of: panelHeight, initial: true) { _, height in panel.setHeight(height) }
    }

    /// Room for `overlayLines` captions (translation up to two lines, original one) and the speech in progress.
    private var panelHeight: CGFloat {
        let translation = captionPoints * 1.25 * 2
        let source = original ? (captionPoints * 0.67).rounded() * 1.25 + 2 : 0
        let pair = translation + source + 8
        return 10 + 18 + 6 + CGFloat(overlayLines) * pair + captionPoints * 1.25 + 14
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(session.languageTitle)
            if session.status == .running {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button {
                if session.status.isActive { Task { await session.stop() } } else { ui.start(session) }
            } label: {
                Label(session.status.isActive ? "停止" : "開始", systemImage: session.status.isActive ? "stop.fill" : "play.fill")
            }
            .help(session.status.isActive ? "停止聆聽" : "開始聆聽")
            InputMenu()
                .menuIndicator(.hidden)
            Button { ui.overlayShown = false } label: {
                Label("回到視窗", systemImage: "macwindow")
            }
            .help("回到主視窗")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var captions: some View {
        let recent = session.captions.suffix(overlayLines)
        if recent.isEmpty && session.pendingText.isEmpty {
            Text(session.status.isActive ? "聆聽中…" : "按 ▶︎ 開始即時翻譯")
                .font(CaptionMetrics.originalFont(captionPoints))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // Each caption is its translation with its original right under it; older ones dimmed.
                ForEach(recent) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.translation ?? "")
                            .font(CaptionMetrics.translationFont(captionPoints))
                            .lineLimit(2)
                        if original {
                            Text(line.source)
                                .font(CaptionMetrics.originalFont(captionPoints))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .opacity(line.id == recent.last?.id ? 1 : 0.6)
                }
                // Speech not translated yet, on its own until its translation arrives.
                if original, !session.pendingText.isEmpty {
                    Text(session.pendingText)
                        .font(CaptionMetrics.originalFont(captionPoints))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#endif
